import Foundation
import Testing
@testable import SparkMonitor

struct ModelTests {
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
