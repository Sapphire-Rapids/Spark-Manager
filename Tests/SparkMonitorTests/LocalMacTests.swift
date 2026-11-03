import Foundation
import AppKit
import Testing
@testable import SparkMonitor

struct LocalMacTests {
    @Test @MainActor func localMacLiveSampling() async throws {
        let collector = LocalMacCollector()
        let initial = try collector.sample()
        let inventory = try #require(initial.inventory)
        #expect(inventory.platform == "macos")
        #expect(initial.snapshot?.devices["cpu"]?.value("usage") == nil)
        try await Task.sleep(for: .seconds(1))
        let sampled = try collector.sample()
        let snapshot = try #require(sampled.snapshot)
        let cpu = try #require(snapshot.devices["cpu"])
        #expect(cpu.cores?.count == ProcessInfo.processInfo.processorCount)
        let pMHz = try #require(cpu.value("frequency"))
        let eMHz = try #require(cpu.value("efficiencyFrequency"))
        #expect(pMHz > 0 && pMHz <= 5000)
        #expect(eMHz > 0 && eMHz <= 5000)
        print("IOReport frequency: P=\(pMHz) MHz, E=\(eMHz) MHz")
        let usage = try #require(cpu.value("usage"))
        #expect((0...100).contains(usage))
        #expect(abs(usage - (cpu.value("user")! + cpu.value("system")!)) < 0.001)
        let memory = try #require(snapshot.devices["memory"])
        #expect(memory.value("total") == Double(ProcessInfo.processInfo.physicalMemory))
        #expect(memory.value("used")! + memory.value("available")! == memory.value("total")!)
        #expect(inventory.devices.contains { $0.kind == .disk })
        #expect(inventory.devices.contains { $0.kind == .network && $0.defaultVisible })
        print("Local sampling: \(cpu.cores!.count) cores, CPU \(usage)%, memory \(memory.value("used")!) / \(memory.value("total")!) bytes")
        for device in inventory.devices where device.kind == .disk || device.kind == .gpu {
            print("\(device.kind): \(device.model), \(snapshot.devices[device.id]?.values ?? [:])")
        }
        _ = NSApplication.shared
        let state = HostState(.local); state.inventory = inventory; state.append(snapshot)
        state.profile.logicalCPU = true
        let pane = PerformancePane(state: state)
        pane.frame = NSRect(x: 0, y: 0, width: 1012, height: 680); pane.layoutSubtreeIfNeeded()
        #expect(pane.charts.count == ProcessInfo.processInfo.processorCount)
        for device in inventory.devices where device.kind == .gpu || device.kind == .disk {
            state.profile.selectedDevice = device.id; pane.refresh(); pane.layoutSubtreeIfNeeded()
            #expect(pane.charts.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
        }
        await collector.stop()
    }
}
