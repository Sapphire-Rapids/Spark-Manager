"""Read-only DGX Spark sampler. Stream JSON over its owning SSH session."""
import csv
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path


def read(path):
    try:
        return Path(path).read_text().strip()
    except (FileNotFoundError, PermissionError, OSError):
        return None


def numeric(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def command(args):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=3)
    except subprocess.TimeoutExpired:
        return None
    return p.stdout if p.returncode == 0 else None


def cpu_ratio(before, after):
    delta = [b - a for a, b in zip(before[:8], after[:8])]
    total = sum(delta)
    if total <= 0 or any(x < 0 for x in delta):
        return {"usage": None, "user": None, "system": None}
    user = (delta[0] + delta[1]) * 100 / total
    system = (delta[2] + delta[5] + delta[6]) * 100 / total
    return {"usage": user + system, "user": user, "system": system}


def rate(before, after, elapsed, factor=1):
    return (after - before) * factor / elapsed if elapsed > 0 and after >= before else None


def cpu_counters():
    return {x[0]: list(map(int, x[1:])) for l in Path('/proc/stat').read_text().splitlines()
            if (x := l.split())[0] == 'cpu' or re.fullmatch(r'cpu\d+', x[0])}


def disk_counters():
    return {x[2]: list(map(int, x[3:])) for l in Path('/proc/diskstats').read_text().splitlines() if len(x := l.split()) >= 14}


def net_counters():
    result = {}
    for line in Path('/proc/net/dev').read_text().splitlines()[2:]:
        name, fields = line.split(':')
        v = list(map(int, fields.split()))
        result[name.strip()] = v
    return result


def memory():
    return {k: float(v.split()[0]) * 1024 for line in Path('/proc/meminfo').read_text().splitlines() for k, v in [line.split(':', 1)]}


def thermal_zones():
    result = {}
    for zone in Path('/sys/class/thermal').glob('thermal_zone*'):
        name = read(zone / 'device/path')
        if name:
            result[name.split('.')[-1]] = zone / 'temp'
    return result


def disk_sensor(name):
    device = (Path('/sys/class/block') / name / 'device').resolve()
    for hw in Path('/sys/class/hwmon').glob('hwmon*'):
        if read(hw / 'name') == 'nvme' and (hw / 'device').resolve() in [device, *device.parents]:
            for label in hw.glob('temp*_label'):
                if read(label) == 'Composite':
                    return label.with_name(label.name.replace('_label', '_input'))
    return None


def disk_mounts(name):
    device = Path('/sys/class/block') / name
    ids = {read(device / 'dev')}
    ids.update(read(p / 'dev') for p in device.glob(name + '*') if (p / 'partition').exists())
    found = {}
    for line in Path('/proc/self/mountinfo').read_text().splitlines():
        fields = line.split()
        if fields[2] in ids and fields[2] not in found:
            found[fields[2]] = fields[4].replace('\\040', ' ')
    return list(found.values())


def inventory():
    mem = memory()
    cores = sorted(Path('/sys/devices/system/cpu').glob('cpu[0-9]*'))
    cpu_model = 'NVIDIA Grace · GB10'
    devices = [
        dict(id='cpu', kind='cpu', name='CPU', model=cpu_model, defaultVisible=True,
             metadata={'cores': str(len(cores)), 'architecture': os.uname().machine}),
        dict(id='memory', kind='memory', name='Memory', model='LPDDR5X · Unified memory', defaultVisible=True,
             metadata={'total': str(int(mem['MemTotal']))})]
    for disk in sorted(Path('/sys/block').iterdir()):
        if not (disk / 'device').exists() or disk.name.startswith(('loop', 'ram', 'zram')):
            continue
        devices.append(dict(id='disk:' + disk.name, kind='disk', name=disk.name,
                            model=read(disk / 'device/model') or disk.name, defaultVisible=True,
                            metadata={'mounts': json.dumps(disk_mounts(disk.name)), 'device': disk.name,
                                      'capacity': str(int(read(disk / 'size') or 0) * 512)}))
    address_data = json.loads(command(['ip', '-j', 'addr']) or '[]')
    for net in sorted(Path('/sys/class/net').iterdir()):
        if net.name == 'lo':
            continue
        addresses = next((n.get('addr_info', []) for n in address_data if n['ifname'] == net.name), [])
        kind = 'Wi-Fi' if (net / 'wireless').exists() else 'Ethernet'
        physical = (net / 'device').exists()
        meta = {'interface': net.name, 'type': kind if physical else 'Virtual',
                'address': ', '.join(a['local'] for a in addresses if a.get('scope') == 'global')}
        rdma = []
        for hca in Path('/sys/class/infiniband').glob('*'):
            for gid in hca.glob('ports/*/gid_attrs/ndevs/*'):
                if read(gid) == net.name:
                    rdma.append(str(gid.parents[2])); break
        meta['rdma_ports'] = json.dumps(rdma)
        devices.append(dict(id='net:' + net.name, kind='network', name=net.name, model=meta['type'],
                            defaultVisible=physical and read(net / 'operstate') == 'up', metadata=meta))
    raw = command(['nvidia-smi', '--query-gpu=index,uuid,name,driver_version', '--format=csv,noheader,nounits'])
    for row in csv.reader((raw or '').splitlines()):
        index, uid, model, driver = [x.strip() for x in row]
        devices.append(dict(id='gpu:' + uid, kind='gpu', name='GPU ' + index, model=model, defaultVisible=True,
                            metadata={'index': index, 'driver': driver}))
    return {'hostname': os.uname().nodename, 'devices': devices}


def gpu_metrics():
    fields = 'uuid,utilization.gpu,utilization.memory,temperature.gpu,power.draw,clocks.current.graphics'
    raw = command(['nvidia-smi', '--query-gpu=' + fields, '--format=csv,noheader,nounits'])
    return {'gpu:' + r[0].strip(): {'values': dict(zip(['usage', 'memoryActivity', 'temperature', 'power', 'frequency'],
                                                     [numeric(x.strip()) for x in r[1:]]))}
            for r in csv.reader((raw or '').splitlines())}


def sample(inv, previous):
    now = time.monotonic()
    cpu, disks, nets = cpu_counters(), disk_counters(), net_counters()
    old_time, old_cpu, old_disks, old_nets = previous
    dt = now - old_time
    mem = memory()
    zones = thermal_zones()
    temperatures = {name: v / 1000 for name, path in zones.items() if (v := numeric(read(path))) is not None}
    cpu_temperatures = {k: v for k, v in temperatures.items() if re.fullmatch(r'TS[01][EP]', k)}
    cpu_values = cpu_ratio(old_cpu.get('cpu', cpu['cpu']), cpu['cpu'])
    frequencies = [v / 1000 for p in Path('/sys/devices/system/cpu').glob('cpu[0-9]*/cpufreq/scaling_cur_freq') if (v := numeric(read(p))) is not None]
    cpu_values.update(temperature=max(cpu_temperatures.values(), default=None),
                      frequency=sum(frequencies) / len(frequencies) if frequencies else None,
                      load=float(Path('/proc/loadavg').read_text().split()[0]))
    metrics = {'cpu': {'values': cpu_values, 'sensors': cpu_temperatures,
                       'cores': [dict(cpu_ratio(old_cpu.get(k, cpu[k]), cpu[k]), index=int(k[3:]))
                                 for k in sorted(cpu, key=lambda k: int(k[3:] or '-1')) if k != 'cpu']},
               'memory': {'values': {'total': mem['MemTotal'], 'available': mem['MemAvailable'],
                          'used': mem['MemTotal'] - mem['MemAvailable'],
                          'usage': (mem['MemTotal'] - mem['MemAvailable']) * 100 / mem['MemTotal'],
                          'cached': mem.get('Cached', 0) + mem.get('SReclaimable', 0),
                          'swapTotal': mem['SwapTotal'], 'swapUsed': mem['SwapTotal'] - mem['SwapFree']}}}
    for dev in inv['devices']:
        meta = dev['metadata']
        if dev['kind'] == 'disk':
            name = meta['device']; cur = disks.get(name); old = old_disks.get(name)
            if cur is None or old is None:
                continue
            used = rate(old[9], cur[9], dt, 0.1)
            sensor = disk_sensor(name); temp = numeric(read(sensor)) if sensor else None
            vals = {'usage': min(100, used) if used is not None else None,
                    'read': rate(old[2], cur[2], dt, 512), 'write': rate(old[6], cur[6], dt, 512),
                    'temperature': temp / 1000 if temp is not None else None, 'capacity': float(meta['capacity'])}
            total = free = 0
            for mount in json.loads(meta['mounts']):
                try:
                    stat = os.statvfs(mount)
                except OSError:
                    continue
                total += stat.f_blocks * stat.f_frsize; free += stat.f_bavail * stat.f_frsize
            vals.update(total=total or None, free=free if total else None)
            metrics[dev['id']] = {'values': vals}
        elif dev['kind'] == 'network':
            name = meta['interface']; cur = nets.get(name); old = old_nets.get(name)
            if cur is None or old is None:
                continue
            speed = numeric(read(Path('/sys/class/net') / name / 'speed'))
            vals = {'receive': rate(old[0], cur[0], dt), 'send': rate(old[8], cur[8], dt),
                    'received': cur[0], 'sent': cur[8], 'errors': cur[2] + cur[10], 'drops': cur[3] + cur[11],
                    'linkSpeed': speed if speed is not None and speed > 0 else None,
                    'up': 1 if read(Path('/sys/class/net') / name / 'operstate') == 'up' else 0}
            ports = json.loads(meta['rdma_ports'])
            if ports:
                for field, source in [('rdmaSent', 'port_xmit_data'), ('rdmaReceived', 'port_rcv_data')]:
                    readings = [numeric(read(Path(p) / 'counters' / source)) for p in ports]
                    vals[field] = sum(v * 4 for v in readings if v is not None) if any(v is not None for v in readings) else None
            metrics[dev['id']] = {'values': vals}
    metrics.update(gpu_metrics())
    return {'timestamp': time.time(), 'uptime': float(Path('/proc/uptime').read_text().split()[0]), 'devices': metrics}, (now, cpu, disks, nets)


def main():
    # The SSH parent owns this process. Also exit promptly on a closed output pipe.
    import ctypes
    ctypes.CDLL(None).prctl(1, signal.SIGHUP)
    inv = inventory()
    print(json.dumps({'inventory': inv}), flush=True)
    previous = (time.monotonic(), cpu_counters(), disk_counters(), net_counters())
    tick = 0
    while True:
        start = time.monotonic()
        time.sleep(max(0, 1 - (start - previous[0])))
        if tick and tick % 30 == 0:
            inv = inventory(); print(json.dumps({'inventory': inv}), flush=True)
        snapshot, previous = sample(inv, previous)
        print(json.dumps({'snapshot': snapshot}, allow_nan=False), flush=True)
        tick += 1


if __name__ == '__main__':
    try:
        main()
    except BrokenPipeError:
        os._exit(0)
