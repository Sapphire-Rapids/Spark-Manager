# Metric definitions / 指标口径

All reads are unprivileged. Null means unavailable; it is never converted to zero. Charts have a 60-second timestamp axis anchored to the latest received sample; redraws do not scroll ahead of the data and a retained boundary sample is clipped at the left edge; rates use remote monotonic elapsed time.

The native app uses Windows Task Manager's Performance-page layout and fields for every host. A field without an equivalent source stays unavailable. Network pages show one interface-throughput chart; RDMA has no additional chart or detail rows. CPU/disk temperatures, power, load, IOPS and OS-specific memory breakdowns are not added to these pages.

| Metric | Source and calculation |
|---|---|
| CPU user | Delta(user + nice) / delta(sum of first eight `/proc/stat` fields) |
| CPU system | Delta(system + irq + softirq) / the same denominator |
| CPU total | User + system; idle, iowait and steal are not attributed to either series. Guest fields are already included in user/nice and are not added again. |
| CPU frequency | Mean of available `scaling_cur_freq` readings; a driver-reported frequency, not an independent measurement of effective work. |
| CPU temperature | The sampler reads the maximum of the Spark ACPI CPU zones `TS0E`, `TS0P`, `TS1E`, `TS1P`, found by `device/path`. The native Task Manager-style CPU page does not display temperature. |
| Memory | `/proc/meminfo`: OS-visible total, available, in-use = total − available, cache = Cached + SReclaimable, Swap used = SwapTotal − SwapFree. Cache overlaps reclaimable memory and is not an additional allocation to sum with used/available. |
| Disk active time | Delta(io_ticks) / elapsed milliseconds, displayed at 0–100%; this is device busy time, not percent of SSD capacity or bandwidth. |
| Disk read/write | Sector counter deltas × 512 / elapsed seconds, from `/proc/diskstats`. |
| Disk capacity/free | Physical sectors plus `statvfs` for the disk's mounted filesystems, deduplicated by major:minor. “Free” is filesystem space available to the user. |
| Disk temperature | NVMe `Composite` hwmon sensor whose parent device matches that disk. |
| Network | Per-interface receive/transmit byte deltas and error/drop counters; link speed and state from sysfs. Each logical interface has its own page. |
| RDMA | Collected as separate port counters and rates, but not displayed in the native Task Manager pages. `port_xmit_data` and `port_rcv_data` count four-byte units; deltas use monotonic elapsed time. These whole-port counters are never added to network-interface traffic. |
| GPU | `nvidia-smi` utilization, memory activity, temperature, graphics clock and power. Memory activity is interface activity, **not allocated memory capacity**. Power is the driver reading, not CPU or wall power. |

Spark CPU/GPU share physical memory. The memory page is the common pool; the GPU page does not fabricate a dedicated VRAM allocation. Unsupported Windows-specific fields such as separate 3D/Copy engine percentages are not synthesized.

Counter resets or the initial baseline yield unavailable rates. Broken streams retain old history only as historical samples; current values are cleared. Authentication and host-key failures stop automatic reconnect. Transient network failures are retried after five seconds.

CPU process/thread counts are Linux process and schedulable-task counts; cache sizes are summed over distinct sysfs shared-cache groups. Disk response time is the read/write time delta divided by completed operations. Network graph labels use decimal bits per second. Memory/disk labels follow Task Manager's KB/MB/GB notation with 1,024-based scaling.

GPU pages use four engine charts and dedicated/shared GPU-memory charts. Devices without dedicated memory have only the shared-memory chart. Overall utilization remains a separate statistic; it is not substituted for 3D or Copy activity. Only GPU-specific allocations can populate the memory charts. Whole-system RAM use is shown on the Memory page. Missing engine readings and GPU-memory limits remain unavailable; Windows' half-RAM shared-memory limit is not imposed on other operating systems.

Network metadata comes from NetworkManager (`nmcli device show`) and sysfs. Wi-Fi SSID, signal in dBm, radio frequency and actual Rx/Tx negotiated rates come from `iw dev <interface> link` without scanning or changing connections. The Wi-Fi protocol is derived from the active link's EHT/HE/VHT/MCS report, not the adapter's advertised maximum. SSID, DNS suffix/server and MAC are refreshed with inventory every 30 seconds; signal and negotiated rates update each sample. A DNS suffix and DNS server address are separate fields. IPv6 includes link-local addresses. An unconfigured DNS field remains unavailable.

## Reference sources

- [NVIDIA SMI](https://docs.nvidia.com/deploy/nvidia-smi/): utilization and encoder/decoder metric definitions.
- [NetworkManager nmcli](https://networkmanager.pages.freedesktop.org/NetworkManager/NetworkManager/nmcli.html): device metadata queries.
- [Microsoft Press: Windows 10 Tools](https://download.microsoft.com/download/7/3/8/7381E0E8-CE72-4366-9849-13B2BAFBBA3C/Microsoft_Press_ebook_Windows_10_Tools_8.5x11.pdf): Task Manager Performance-page layout.
- [WLAN signal quality](https://learn.microsoft.com/en-us/windows/win32/api/wlanapi/ns-wlanapi-wlan_association_attributes): signal bars use Windows' linear mapping from -100...-50 dBm to 0...100 quality.

## Windows native backend

- CPU: one persistent PDH query samples `Processor Information` total and each logical processor's processor/user/privileged time on the same collection tick. Speed uses processor frequency × percent processor performance. Processes, threads and handles use `GetPerformanceInfo`; topology and base clock use CIM. Windows ACPI thermal-zone readings are not treated as reliable CPU temperatures. CPU temperature is not collected or displayed on Windows.
- Memory: OS-visible physical total/available, commit and pools use `GetPerformanceInfo`. In use excludes the modified list from total − available; cached = standby + modified. Composition uses in-use, modified, standby and free/zero-page lists. Installed capacity, timings and slots use SMBIOS via CIM. Hardware reserved = installed − OS-visible total. Compressed-store size is not collected.
- Disk: native physical-disk counters provide idle time (active = 100 − idle, bounded 0–100), read/write bytes/sec and average transfer latency. Storage cmdlets provide drive letters, volume sizes and low-frequency reliability temperature. Volume size/free space and storage temperatures refresh in a separate in-process runspace every 15 seconds. Hardware inventory is discovered on connection; reconnect after changing installed devices.
- Network: .NET network interfaces provide byte-counter deltas over actual elapsed time, addresses, speed, errors and drops. Native WLAN connection queries provide SSID, signal percentage and negotiated rates when connected and permitted by Windows privacy settings. Virtual/disconnected interfaces remain available in Edit.
- GPU: DXGI enumerates adapters and memory capacities; PDH groups per-process engine activity by adapter LUID and physical engine, then uses the busiest engine for overall utilization. Different engines are never summed into a false overall percentage. Adapters without GPU-engine counter instances (including session mirrors) are not presented as additional physical GPUs. Dedicated/shared allocations are WDDM figures and overlap the machine's physical memory; do not add them to system memory usage. Temperature uses `D3DKMTQueryAdapterInfo`, DirectX feature level uses `D3D12CreateDevice` capability testing without device creation, and PCI location uses D3DKMT. The native adapter performance `Power` percentage is **not watts** and is not exposed as power draw.
- GPU identity: a PNP ID is retained only for an unambiguous one-to-one model match. Identical-model or unmatched adapters use their unique DXGI LUID, so their samples remain separate. LUID-based visibility/order preferences can reset after a Windows reboot.
- Commands run without a PTY and emit UTF-8 JSON. The native declarations use only Windows libraries. No third-party monitoring driver or persistent service is installed.

Sources: [PDH English counters](https://learn.microsoft.com/en-us/windows/win32/api/pdh/nf-pdh-pdhaddenglishcounterw), [GPU engine semantics](https://devblogs.microsoft.com/directx/gpus-in-the-task-manager/), [GPU temperature and power units](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmthk/ns-d3dkmthk-_d3dkmt_adapter_perfdata), [storage reliability](https://learn.microsoft.com/en-us/powershell/module/storage/get-storagereliabilitycounter), [DirectX capability query](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-d3d12createdevice).

## Local Mac / 本机

The pinned “This Mac” entry samples directly with Mach, sysctl, IOKit,
getifaddrs, SystemConfiguration and CoreWLAN. It requires no SSH server,
agent, administrator rights or additional software. Remote host profiles
remain unchanged; local hardware visibility/order and CPU chart mode persist.

- CPU: differences of Mach per-processor ticks; system and user + nice sum to
  utilization. The first sample has no utilization/rate baseline. Sleep gaps
  restart the baseline. IOReport reports active-state residency-weighted performance/efficiency core
  frequencies, using firmware DVFS tables (tested on M3). Idle clusters have no
  active frequency and show unavailable rather than an invented minimum.
  IOReport is a private system API and requires no elevated helper.
- CPU process count uses the filled PID enumeration, rather than its buffer-size
  estimate. Cache totals sum all performance/efficiency core groups: L1 includes
  instruction and data caches per core; shared L2/L3 is counted once per group.
  Uptime and sampling intervals use the monotonic raw clock, which includes sleep.
- Memory: estimated app pages = internal − purgeable, bounded at zero;
  memory used = app + wired + physical compressor pages. Available is the
  remainder of physical RAM, not Linux MemAvailable. Swap is reported by sysctl.
- Physical disks: IOBlockStorageDriver read/write byte deltas and mean request
  service time. Busy percentage is deliberately not derived by summing overlapping
  requests. The standard active-time chart stays unavailable; the lower chart shows read/write throughput.
  A one-time built-in diskutil query identifies the system APFS physical store,
  so its capacity and formatted size appear on the corresponding disk page.
- Network: 64-bit `NET_RT_IFLIST2` interface counters and link speed, with byte
  deltas divided by actual sample duration. Physical active
  interfaces appear by default; virtual interfaces are available in Edit.
  macOS may withhold Wi-Fi SSID without location permission; no permission is requested.
- GPU: IOKit Device utilization supplies the overall statistic. Its Renderer/Tiler
  and allocation counters are retained by the sampler but are not relabelled as
  WDDM engine or shared-memory readings. The corresponding chart values remain
  unavailable until equivalent measurements are exposed.

Memory charts retain their last known capacity when disconnected. Historical
samples keep the same scale while current readings remain unavailable.

本机固定显示在机器列表首位。各页沿用 Windows 任务管理器的布局和字段；取不到对应数值时显示 `—`。
统一内存设备使用共享 GPU 内存栏，不拿整机内存用量代替 GPU 用量。
