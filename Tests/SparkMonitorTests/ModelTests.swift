import Foundation
import AppKit
import Testing
@testable import SparkMonitor

struct ModelTests {
    @Test @MainActor func windowsPagesUseHardwareCountsAndSeparateGPUMemory() {
        _ = NSApplication.shared
        let host = HostState(HostProfile(name: "Windows", host: "example.test", username: "demo", logicalCPU: true, platform: "windows"))
        host.inventory = HardwareInventory(hostname: "Windows", devices: [
            HardwareDevice(id: "cpu", kind: .cpu, name: "CPU", model: "Example CPU", defaultVisible: true, metadata: ["cores": "16", "logicalProcessors": "32"]),
            HardwareDevice(id: "gpu", kind: .gpu, name: "GPU 0", model: "Example GPU", defaultVisible: true, metadata: ["engine:0": "3D", "engine:1": "Copy", "engine:2": "Compute", "engine:3": "Video Decode"])
        ], platform: "windows")
        host.append(MetricsSnapshot(timestamp: 1, uptime: 1, devices: ["gpu": DeviceMetrics(values: ["dedicatedUsed": 256e6, "dedicatedTotal": 512e6, "sharedUsed": 1e9, "sharedTotal": 16e9])]))
        let pane = PerformancePane(state: host); pane.frame = NSRect(x: 0, y: 0, width: 1012, height: 640); pane.layoutSubtreeIfNeeded()
        #expect(pane.charts.count == 32)
        #expect(pane.charts[7].frame.minY == pane.charts[0].frame.minY)
        host.profile.selectedDevice = "gpu"; pane.refresh(); pane.layoutSubtreeIfNeeded()
        #expect(pane.charts.count == 6)
        #expect(pane.engineMenus.count == 4)
        #expect(pane.charts[4].ceiling == 512e6)
        #expect(pane.charts[5].points.last?.total == 1e9)
    }
    @Test @MainActor func hardwareOrderAndVisibilityPersist() throws {
        let host = HostState(HostProfile(name: "Example", host: "example.test", username: "demo"))
        host.inventory = HardwareInventory(hostname: "Example", devices: [
            HardwareDevice(id: "cpu", kind: .cpu, name: "CPU", model: "GB10", defaultVisible: true, metadata: [:]),
            HardwareDevice(id: "memory", kind: .memory, name: "Memory", model: "LPDDR5X", defaultVisible: true, metadata: [:]),
            HardwareDevice(id: "gpu", kind: .gpu, name: "GPU", model: "GB10", defaultVisible: true, metadata: [:])
        ])
        host.moveDevice("gpu", to: 0)
        host.setVisible(false, device: host.inventory!.devices[1])
        let restored = HostState(try JSONDecoder().decode(HostProfile.self, from: JSONEncoder().encode(host.profile)))
        restored.inventory = host.inventory
        #expect(restored.visibleDevices.map(\.id) == ["gpu", "cpu"])
        #expect(restored.editableDevices.map(\.id) == ["gpu", "cpu", "memory"])
        restored.setVisible(true, device: host.inventory!.devices[1])
        #expect(restored.visibleDevices.count == 3)
    }
    @Test @MainActor func gpuRefreshPreservesScrollAndResizesCharts() {
        _ = NSApplication.shared
        let host = HostState(HostProfile(name: "Example", host: "example.test", username: "demo", selectedDevice: "gpu"))
        host.inventory = HardwareInventory(hostname: "Example", devices: [
            HardwareDevice(id: "gpu", kind: .gpu, name: "GPU", model: "GB10", defaultVisible: true, metadata: [:])
        ])
        let pane = PerformancePane(state: host)
        pane.frame = NSRect(x: 0, y: 0, width: 872, height: 480)
        pane.layoutSubtreeIfNeeded()
        pane.detailScroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
        let before = pane.detailScroll.contentView.bounds.origin.y
        let field = pane.details.first!.0
        let graphHeight = pane.charts[0].frame.height
        #expect(before > 0)
        pane.refresh(); pane.layoutSubtreeIfNeeded()
        #expect(pane.detailScroll.contentView.bounds.origin.y == before)
        #expect(pane.details.first!.0 === field)
        pane.frame.size.height = 1000; pane.layoutSubtreeIfNeeded()
        #expect(pane.charts.count == 5)
        #expect(pane.charts[0].frame.height > graphHeight)
        #expect(pane.details.allSatisfy { $0.0.frame.maxY <= pane.content.bounds.height })
    }
    @Test func adaptiveSelectionPreservesFocus() {
        let ids = (0..<4).map { _ in UUID() }
        var panes = PaneSelection()
        panes.resize(width: 1800, hosts: ids)
        #expect(panes.visible == Array(ids.prefix(2)))
        panes.select(ids[3])
        #expect(panes.visible == [ids[3], ids[1]])
        panes.resize(width: 900, hosts: ids)
        #expect(panes.visible == [ids[3]])
        panes.resize(width: 2800, hosts: ids)
        #expect(panes.visible.count == 3)
        #expect(Set(panes.visible).count == 3)
    }
    @Test func profilePreferencesRoundTrip() throws {
        var profile = HostProfile(name: "Example", host: "192.0.2.1", username: "demo")
        profile.logicalCPU = true; profile.hiddenDevices = ["cpu"]; profile.addedDevices = ["net:test"]
        let decoded = try JSONDecoder().decode(HostProfile.self, from: JSONEncoder().encode(profile))
        #expect(profile == decoded)
    }
    @Test func nullMetricsRemainUnavailable() throws {
        let wire = Data(#"{"snapshot":{"timestamp":1,"uptime":2,"devices":{"cpu":{"values":{"usage":null,"temperature":null},"cores":[]}}}}"#.utf8)
        let m = try JSONDecoder().decode(CollectorMessage.self, from: wire)
        #expect(m.snapshot?.devices["cpu"]?.value("usage") == nil)
        #expect(number(nil) == "—")
    }
    @Test @MainActor func historyRetainsGapAndPrunes() {
        let host = HostState(HostProfile(name: "Example", host: "example.test", username: "demo"))
        host.lastReceived = Date().addingTimeInterval(-10)
        host.history = [HistoryPoint(received: Date().addingTimeInterval(-90), snapshot: nil)]
        host.append(MetricsSnapshot(timestamp: 0, uptime: 0, devices: [:]))
        #expect(host.history.count == 2)
        #expect(host.history[0].snapshot == nil)
        #expect(host.live)
        host.status = "disconnected"
        #expect(host.latest == nil)
    }
}
