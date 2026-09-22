import Foundation

@MainActor extension AppModel {
    func loadDemo() {
        demo = true
        for i in 1...3 {
            let state = HostState(HostProfile(name: "Spark 0\(i)", host: "spark-0\(i).example", username: "demo"))
            state.inventory = HardwareInventory(hostname: state.profile.name, devices: [
                HardwareDevice(id: "cpu", kind: .cpu, name: "CPU", model: "NVIDIA GB10", defaultVisible: true, metadata: ["cores": "20", "architecture": "aarch64", "sockets": "1", "cacheL1": "3932160", "cacheL2": "20971520", "cacheL3": "25165824"]),
                HardwareDevice(id: "memory", kind: .memory, name: "Memory", model: "LPDDR5X", defaultVisible: true, metadata: [:]),
                HardwareDevice(id: "disk:demo", kind: .disk, name: "0 (NVMe)", model: "4 TB NVMe SSD", defaultVisible: true, metadata: ["index": "0", "system": "true", "type": "SSD (NVMe)"]),
                HardwareDevice(id: "net:demo", kind: .network, name: "ethernet0", model: "MediaTek Wi-Fi 7 MT7925", defaultVisible: true, metadata: ["type": "Wi-Fi", "rdma_ports": "[]", "ipv4": "192.0.2.10"]),
                HardwareDevice(id: "net:rdma", kind: .network, name: "fabric0", model: "Ethernet", defaultVisible: true, metadata: ["rdma_ports": "[demo]", "address": "198.51.100.10"]),
                HardwareDevice(id: "gpu:demo", kind: .gpu, name: "GPU 0", model: "NVIDIA GB10", defaultVisible: true, metadata: ["driver": "580 (demo)"])
            ])
            for age in (0..<60).reversed() {
                let date = Date().addingTimeInterval(-Double(age))
                state.history.append(HistoryPoint(received: date, snapshot: demoSnapshot(time: date.timeIntervalSince1970, offset: i)))
            }
            state.lastReceived = Date(); state.status = "connected"; hosts.append(state)
        }
    }
    func tickDemo() {
        for (i, host) in hosts.enumerated() { host.append(demoSnapshot(time: Date().timeIntervalSince1970, offset: i + 1)) }
    }
    func demoSnapshot(time: Double, offset: Int) -> MetricsSnapshot {
        let t = time.truncatingRemainder(dividingBy: 300)
        let busy = 25 + abs(sin(t * 0.43)) * 24 + abs(cos(t * 0.71)) * 17
        let gib: Double = 1_073_741_824
        let cores: [[String: Double?]] = (0..<20).map { c in
            let usage = min(99, busy + sin(Double(c) + t) * 20)
            return ["index": Double(c), "usage": usage, "system": 7, "user": usage - 7]
        }
        return MetricsSnapshot(timestamp: time, uptime: 106393, devices: [
            "cpu": DeviceMetrics(values: ["usage": busy, "user": busy - 8, "system": 8, "frequency": 3280, "temperature": 68.5, "load": 7.8, "processes": 348, "threads": 2920],
                                 cores: cores,
                                 sensors: ["TS0E": 56.2, "TS0P": 67.1, "TS1E": 57.5, "TS1P": 68.5]),
            "memory": DeviceMetrics(values: ["usage": 58, "used": 70.5 * gib, "total": 121.6 * gib, "available": 51.1 * gib, "cached": 12.4 * gib, "swapUsed": 0, "swapTotal": 16 * gib, "committed": 72 * gib, "commitLimit": 132 * gib]),
            "disk:demo": DeviceMetrics(values: ["usage": busy / 3, "read": busy * 1_000_000, "write": 3_000_000, "temperature": 44, "latency": 1.3, "capacity": 4_000_000_000_000, "total": 3.75e12, "free": 2.5e12]),
            "net:demo": DeviceMetrics(values: ["receive": busy * 100_000, "send": busy * 30_000, "received": 2e9, "sent": 1e9, "linkSpeed": 10_000, "up": 1, "errors": 0, "drops": 0]),
            "net:rdma": DeviceMetrics(values: ["receive": busy * 10_000_000, "send": busy * 8_000_000, "received": 2e11, "sent": 1e11, "linkSpeed": 200_000, "up": 1, "errors": 0, "drops": 0, "rdmaSent": 1e11, "rdmaReceived": 2e11]),
            "gpu:demo": DeviceMetrics(values: ["usage": busy + 18, "temperature": 58, "power": 38.4, "frequency": 2483, "memoryActivity": 12, "encoder": 0, "decoder": 0])
        ])
    }
}
