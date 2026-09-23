import Foundation

enum HardwareKind: String, Codable { case cpu, memory, disk, network, gpu }
struct HostProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    var authentication: String = "key"
    var keyPath: String = "~/.ssh/id_ed25519"
    var fingerprint: String?
    var hiddenDevices: Set<String> = []
    var addedDevices: Set<String> = []
    var logicalCPU = false
    var selectedDevice = "cpu"
    var deviceOrder: [String]?
    var platform: String?
    var gpuGraphs: [String: [String]]?
}
struct HardwareDevice: Codable, Identifiable, Equatable {
    let id: String
    let kind: HardwareKind
    let name: String
    let model: String
    let defaultVisible: Bool
    var metadata: [String: String]
}
struct HardwareInventory: Codable {
    var hostname: String
    var devices: [HardwareDevice]
    var platform: String?
}
struct DeviceMetrics: Codable {
    var values: [String: Double?]
    var cores: [[String: Double?]]?
    var sensors: [String: Double]?
    func value(_ key: String) -> Double? { values[key] ?? nil }
}
struct MetricsSnapshot: Codable {
    var timestamp: Double
    var uptime: Double
    var devices: [String: DeviceMetrics]
}
struct CollectorMessage: Codable {
    var inventory: HardwareInventory?
    var snapshot: MetricsSnapshot?
    var samplerPid: Int?
}
struct HistoryPoint {
    let received: Date
    let snapshot: MetricsSnapshot?
}
struct Preferences: Codable {
    var language = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
    var theme = "system"
    var hosts: [HostProfile] = []
}

struct PaneSelection {
    var visible: [UUID] = []
    var focused: UUID?
    static func capacity(width: Double) -> Int { max(1, Int((width + 12) / 872)) }
    mutating func resize(width: Double, hosts: [UUID]) {
        let count = min(hosts.count, Self.capacity(width: width))
        visible = visible.filter { hosts.contains($0) }
        if visible.count > count {
            if let focus = focused, let i = visible.firstIndex(of: focus), i >= count {
                visible.swapAt(0, i)
            }
            visible = Array(visible.prefix(count))
        }
        for id in hosts where visible.count < count && !visible.contains(id) { visible.append(id) }
        if focused == nil || !visible.contains(focused!) { focused = visible.first }
    }
    mutating func select(_ id: UUID) {
        if !visible.contains(id), let index = visible.firstIndex(of: focused ?? UUID()) { visible[index] = id }
        if visible.isEmpty { visible = [id] }
        focused = id
    }
}

enum MonitorError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

@MainActor func tr(_ zh: String, _ en: String) -> String { AppModel.shared.preferences.language == "zh" ? zh : en }
func number(_ value: Double?, _ suffix: String = "", digits: Int = 1) -> String {
    guard let value, value.isFinite else { return "—" }
    return String(format: "%.*f", digits, value) + suffix
}
func bytes(_ value: Double?, perSecond: Bool = false) -> String {
    guard let value else { return "—" }
    let units = perSecond ? ["B/s", "KiB/s", "MiB/s", "GiB/s"] : ["B", "KiB", "MiB", "GiB", "TiB"]
    var v = value; var i = 0
    while abs(v) >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return number(v, " " + units[i])
}
