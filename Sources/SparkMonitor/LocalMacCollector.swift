import Foundation
import Darwin
import IOKit
import SystemConfiguration
import CoreWLAN

/// Local, read-only sampling. No helper daemon, shell commands, or elevated privileges.
@MainActor final class LocalMacCollector: MetricsCollecting {
    private var stopped = false
    private let frequency = MacFrequency()
    private var systemDisk: String?
    private var discoveredStorage = false
    private var previousCPU: [[UInt32]] = []
    private var previousCounters: [String: [String: Double]] = [:]
    private var previousTime: TimeInterval?
    private var inventory: HardwareInventory?
    private let hostPort = mach_host_self()
    deinit { mach_port_deallocate(mach_task_self_, hostPort) }

    func start(profile: HostProfile, secret: String?, trust: @escaping @MainActor (String) -> Bool,
               receive: @escaping @MainActor (CollectorMessage) -> Void) async throws {
        while !stopped && !Task.isCancelled {
            let message = try sample()
            receive(message)
            try await Task.sleep(for: .seconds(1))
        }
    }
    func stop() async { stopped = true }

    private func sysNumber(_ name: String) -> Double? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Double(value)
    }
    private func sysString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }
    private func services(_ type: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(type), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service); IOObjectRelease(service)
        }
    }
    private func property(_ service: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    private func rate(_ id: String, _ key: String, _ current: [String: Double], _ elapsed: Double?) -> Double? {
        guard let elapsed, elapsed > 0, elapsed < 4,
              let before = previousCounters[id]?[key], let now = current[key], now >= before else { return nil }
        return (now - before) / elapsed
    }

    private func networkCounters() throws -> [String: if_data64] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
            throw MonitorError.message("Unable to size 64-bit network counters: \(String(cString: strerror(errno)))")
        }
        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { throw MonitorError.message("Unable to read 64-bit network counters: \(String(cString: strerror(errno)))") }
        return try buffer.withUnsafeBytes { raw in
            var counters: [String: if_data64] = [:]
            var offset = 0
            while offset + 4 <= size {
                let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, offset + length <= size else { throw MonitorError.message("Invalid network counter message length") }
                if raw[offset + 3] == UInt8(RTM_IFINFO2), length >= MemoryLayout<if_msghdr2>.size {
                    let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    if if_indextoname(UInt32(header.ifm_index), &name) != nil {
                        counters[String(cString: name)] = header.ifm_data
                    }
                }
                offset += length
            }
            return counters
        }
    }

    func sample() throws -> CollectorMessage {
        if !discoveredStorage {
            discoveredStorage = true
            // diskutil exposes APFS physical-store mapping; run once, never per tick.
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = ["info", "-plist", "/System/Volumes/Data"]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            if process.terminationStatus == 0,
               let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let stores = info["APFSPhysicalStores"] as? [[String: Any]], stores.count == 1,
               let store = stores[0]["APFSPhysicalStore"] as? String,
               let range = store.range(of: "^disk[0-9]+", options: .regularExpression) {
                systemDisk = String(store[range])
            }
        }
        // This clock includes sleep, both for uptime and for rejecting stale rate baselines.
        let now = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
        let elapsed = previousTime.map { now - $0 }
        var devices: [HardwareDevice] = []
        var metrics: [String: DeviceMetrics] = [:]
        var counters: [String: [String: Double]] = [:]
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else {
            throw MonitorError.message("Unable to read local CPU counters")
        }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var cpu: [[UInt32]] = []
        var cores: [[String: Double?]] = []
        var sums = [Double](repeating: 0, count: 4)
        for index in 0..<Int(count) {
            let ticks = (0..<4).map { UInt32(bitPattern: info[index * 4 + $0]) }
            cpu.append(ticks)
            var values: [String: Double?] = ["index": Double(index)]
            if previousCPU.count == Int(count), let elapsed, elapsed < 4 {
                let delta = zip(ticks, previousCPU[index]).map { Double($0 &- $1) }
                let total = delta.reduce(0, +)
                if total > 0 {
                    values["system"] = 100 * delta[Int(CPU_STATE_SYSTEM)] / total
                    values["user"] = 100 * (delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_NICE)]) / total
                    values["usage"] = 100 * (total - delta[Int(CPU_STATE_IDLE)]) / total
                    for i in 0..<4 { sums[i] += delta[i] }
                }
            }
            cores.append(values)
        }
        previousCPU = cpu
        let clocks = frequency.sample(validInterval: elapsed.map { $0 > 0 && $0 < 4 } ?? false)
        var cpuValues: [String: Double?] = ["frequency": clocks.performance, "efficiencyFrequency": clocks.efficiency]
        let totalTicks = sums.reduce(0, +)
        if totalTicks > 0 {
            cpuValues["system"] = 100 * sums[Int(CPU_STATE_SYSTEM)] / totalTicks
            cpuValues["user"] = 100 * (sums[Int(CPU_STATE_USER)] + sums[Int(CPU_STATE_NICE)]) / totalTicks
            cpuValues["usage"] = 100 * (totalTicks - sums[Int(CPU_STATE_IDLE)]) / totalTicks
        }
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { cpuValues["load"] = loads[0] }
        let pidCapacity = proc_listallpids(nil, 0)
        if pidCapacity > 0 {
            var pids = [pid_t](repeating: 0, count: Int(pidCapacity))
            let pidCount = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            if pidCount >= 0 { cpuValues["processes"] = Double(pidCount) }
        }
        var processorSet: processor_set_name_t = 0
        if processor_set_default(hostPort, &processorSet) == KERN_SUCCESS {
            defer { mach_port_deallocate(mach_task_self_, processorSet) }
            var load = processor_set_load_info_data_t()
            var loadCount = mach_msg_type_number_t(MemoryLayout<processor_set_load_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &load) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(loadCount)) {
                    processor_set_statistics(processorSet, PROCESSOR_SET_LOAD_INFO, $0, &loadCount)
                }
            }
            if result == KERN_SUCCESS { cpuValues["threads"] = Double(load.thread_count) }
        }
        var cpuMeta = ["architecture": sysString("hw.machine"), "cores": String(Int(sysNumber("hw.physicalcpu") ?? Double(count))), "logicalProcessors": String(count), "sockets": "1"]
        if let available = sysNumber("kern.hv_support") { cpuMeta["virtualization"] = String(available != 0) }
        for (key, name) in [("performanceCores", "hw.perflevel0.physicalcpu"), ("efficiencyCores", "hw.perflevel1.physicalcpu")] {
            if let n = sysNumber(name) { cpuMeta[key] = String(Int(n)) }
        }
        if let levels = sysNumber("hw.nperflevels"), levels > 0 {
            for level in 1...3 {
                var bytes = 0.0
                var complete = true
                for index in 0..<Int(levels) {
                    let prefix = "hw.perflevel\(index)."
                    guard let cores = sysNumber(prefix + "physicalcpu") else { complete = false; break }
                    if level == 1 {
                        guard let instruction = sysNumber(prefix + "l1icachesize"), let data = sysNumber(prefix + "l1dcachesize") else { complete = false; break }
                        bytes += cores * (instruction + data)
                    } else {
                        guard let capacity = sysNumber(prefix + "l\(level)cachesize"), let sharing = sysNumber(prefix + "cpusperl\(level)"), sharing > 0 else { complete = false; break }
                        bytes += ceil(cores / sharing) * capacity
                    }
                }
                if complete, bytes > 0 { cpuMeta["cacheL\(level)"] = String(Int(bytes)) }
            }
        }
        if let maximum = frequency.maximumMHz { cpuMeta["maxFrequency"] = String(maximum) }
        devices.append(HardwareDevice(id: "cpu", kind: .cpu, name: "CPU", model: sysString("machdep.cpu.brand_string"), defaultVisible: true, metadata: cpuMeta))
        metrics["cpu"] = DeviceMetrics(values: cpuValues, cores: cores)

        var vm = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(hostPort, HOST_VM_INFO64, $0, &vmCount) }
        }
        guard vmResult == KERN_SUCCESS else { throw MonitorError.message("Unable to read local memory counters") }
        let page = Double(vm_kernel_page_size)
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let wired = Double(vm.wire_count) * page
        let compressed = Double(vm.compressor_page_count) * page
        let app = max(0, Double(vm.internal_page_count) - Double(vm.purgeable_count)) * page
        let used = min(total, app + wired + compressed)
        var memory: [String: Double?] = ["total": total, "used": used, "available": total - used, "usage": used / total * 100,
            "app": app, "wired": wired, "compressed": compressed, "cached": Double(vm.external_page_count) * page,
            "purgeable": Double(vm.purgeable_count) * page]
        var swap = xsw_usage(); var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            memory["swapUsed"] = Double(swap.xsu_used); memory["swapTotal"] = Double(swap.xsu_total)
        }
        devices.append(HardwareDevice(id: "memory", kind: .memory, name: "Memory", model: "Unified memory", defaultVisible: true, metadata: ["total": String(Int(total))]))
        metrics["memory"] = DeviceMetrics(values: memory)

        services("IOBlockStorageDriver") { driver in
            guard let raw = property(driver, "Statistics") as? [String: NSNumber] else { return }
            var virtual = false
            var provider: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(driver, kIOServicePlane, &provider) == KERN_SUCCESS {
                defer { IOObjectRelease(provider) }
                let protocolInfo = property(provider, "Protocol Characteristics") as? [String: Any]
                virtual = protocolInfo?["Physical Interconnect"] as? String == "Virtual Interface"
            }
            var child: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &child) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(child) }
            while case let media = IOIteratorNext(child), media != 0 {
                defer { IOObjectRelease(media) }
                guard property(media, "Whole") as? Bool == true, let bsd = property(media, "BSD Name") as? String else { continue }
                let id = "disk:" + bsd
                let current = raw.mapValues(\.doubleValue)
                counters[id] = current
                var name = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(media, &name)
                var values: [String: Double?] = ["capacity": (property(media, "Size") as? NSNumber)?.doubleValue,
                    "read": rate(id, "Bytes (Read)", current, elapsed), "write": rate(id, "Bytes (Write)", current, elapsed)]
                // IOStorage request service times overlap and are not disk busy time.
                if let readOps = rate(id, "Operations (Read)", current, elapsed), let writeOps = rate(id, "Operations (Write)", current, elapsed),
                   let readTime = rate(id, "Total Time (Read)", current, elapsed), let writeTime = rate(id, "Total Time (Write)", current, elapsed) {
                    values["latency"] = readOps + writeOps > 0 ? (readTime + writeTime) / (readOps + writeOps) / 1_000_000 : 0
                }
                if let reads = rate(id, "Operations (Read)", current, elapsed), let writes = rate(id, "Operations (Write)", current, elapsed) {
                    values["operations"] = reads + writes
                }
                let system = bsd == systemDisk
                if system, let space = try? URL(fileURLWithPath: "/System/Volumes/Data").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
                    values["total"] = space.volumeTotalCapacity.map(Double.init)
                    values["free"] = space.volumeAvailableCapacity.map(Double.init)
                }
                devices.append(HardwareDevice(id: id, kind: .disk, name: bsd, model: String(cString: name), defaultVisible: true,
                    metadata: ["type": virtual ? "Disk image" : (system ? "SSD (APFS)" : "Storage"), "system": String(system), "index": String(devices.filter { $0.kind == .disk }.count)]))
                metrics[id] = DeviceMetrics(values: values)
            }
        }
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        var interfaceNames: [String: (String, String)] = [:]
        for interface in interfaces {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String? {
                interfaceNames[bsd] = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? bsd,
                                      SCNetworkInterfaceGetInterfaceType(interface) as String? ?? "")
            }
        }
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { throw MonitorError.message("Unable to read network interfaces") }
        defer { freeifaddrs(addresses) }
        var cursor = addresses
        var networkMetadata: [String: [String: String]] = [:]
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let entry = item.pointee; let bsd = String(cString: entry.ifa_name)
            guard let address = entry.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            if family == AF_INET || family == AF_INET6 {
                var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 {
                    networkMetadata[bsd, default: [:]][family == AF_INET ? "ipv4" : "ipv6"] = String(cString: text)
                }
            }
        }
        let networkStats = try networkCounters()
        cursor = addresses
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let entry = item.pointee
            guard entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let bsd = String(cString: entry.ifa_name), id = "net:" + String(cString: entry.ifa_name)
            let data = networkStats[bsd]
            let current = data.map { ["send": Double($0.ifi_obytes), "receive": Double($0.ifi_ibytes)] } ?? [:]
            counters[id] = current
            let physical = interfaceNames[bsd]
            let wifi = physical?.1 == (kSCNetworkInterfaceTypeIEEE80211 as String)
            var meta = networkMetadata[bsd] ?? [:]
            if let interface = interfaces.first(where: { (SCNetworkInterfaceGetBSDName($0) as String?) == bsd }) {
                meta["mac"] = SCNetworkInterfaceGetHardwareAddressString(interface) as String?
            }
            if let dns = SCDynamicStoreCopyValue(nil, "State:/Network/Global/DNS" as CFString) as? [String: Any] {
                meta["dns"] = (dns["ServerAddresses"] as? [String])?.joined(separator: ", ")
                meta["domain"] = dns["DomainName"] as? String
            }
            meta["type"] = wifi ? "Wi-Fi" : (physical == nil ? "Virtual" : "Ethernet")
            var values: [String: Double?] = ["send": rate(id, "send", current, elapsed), "receive": rate(id, "receive", current, elapsed),
                "errors": data.map { Double($0.ifi_ierrors) + Double($0.ifi_oerrors) }, "drops": data.map { Double($0.ifi_iqdrops) }]
            if let data, data.ifi_baudrate > 0 { values["linkSpeed"] = Double(data.ifi_baudrate) / 1_000_000 }
            if wifi, let wlan = CWWiFiClient.shared().interface(withName: bsd) {
                meta["ssid"] = wlan.ssid()
                switch wlan.activePHYMode() {
                case .mode11ax: meta["protocol"] = "802.11ax"
                case .mode11ac: meta["protocol"] = "802.11ac"
                case .mode11n: meta["protocol"] = "802.11n"
                case .mode11a: meta["protocol"] = "802.11a"
                case .mode11b: meta["protocol"] = "802.11b"
                case .mode11g: meta["protocol"] = "802.11g"
                default: break
                }
                if wlan.rssiValue() != 0 { values["signal"] = Double(wlan.rssiValue()) }
                if wlan.transmitRate() > 0 { values["txSpeed"] = wlan.transmitRate() }
            }
            let link = SCDynamicStoreCopyValue(nil, "State:/Network/Interface/\(bsd)/Link" as CFString) as? [String: Any]
            let active = link?["Active"] as? Bool ?? false
            let hardware = physical?.1 == (kSCNetworkInterfaceTypeEthernet as String) || wifi
            devices.append(HardwareDevice(id: id, kind: .network, name: bsd, model: physical?.0 ?? bsd,
                defaultVisible: hardware && active, metadata: meta))
            metrics[id] = DeviceMetrics(values: values)
        }
        services("IOAccelerator") { gpu in
            guard let stats = property(gpu, "PerformanceStatistics") as? [String: NSNumber] else { return }
            let id = "gpu:local"
            let values: [String: Double?] = ["usage": stats["Device Utilization %"]?.doubleValue,
                "engine:0": stats["Device Utilization %"]?.doubleValue,
                "engine:1": stats["Renderer Utilization %"]?.doubleValue,
                "engine:2": stats["Tiler Utilization %"]?.doubleValue,
                "renderer": stats["Renderer Utilization %"]?.doubleValue, "tiler": stats["Tiler Utilization %"]?.doubleValue,
                "allocated": stats["In use system memory"]?.doubleValue]
            let meta = ["engine:0": "GPU", "engine:1": "Renderer", "engine:2": "Tiler", "driver": property(gpu, "CFBundleIdentifier") as? String ?? "", "cores": (property(gpu, "gpu-core-count") as? NSNumber)?.stringValue ?? ""]
            devices.append(HardwareDevice(id: id, kind: .gpu, name: "GPU", model: property(gpu, "model") as? String ?? "Apple GPU", defaultVisible: true, metadata: meta))
            metrics[id] = DeviceMetrics(values: values)
        }
        let newInventory = HardwareInventory(hostname: Host.current().localizedName ?? "Mac", devices: devices, platform: "macos")
        let changed = inventory?.devices != devices
        inventory = newInventory
        previousCounters = counters; previousTime = now
        return CollectorMessage(inventory: changed ? newInventory : nil, snapshot: MetricsSnapshot(timestamp: Date().timeIntervalSince1970, uptime: now, devices: metrics))
    }
}
