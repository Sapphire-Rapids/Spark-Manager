import AppKit
import Security

enum CredentialStore {
    static let service = "org.sparkmonitor.native.preview"
    static func load(_ id: UUID) throws -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                               kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MonitorError.message("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
        }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ value: String, id: UUID) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                               kSecAttrAccount as String: id.uuidString]
        let data = Data(value.utf8)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw MonitorError.message("Keychain save failed: \(status)") }
    }
    static func remove(_ id: UUID) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: id.uuidString] as CFDictionary)
    }
}

@MainActor final class HostState {
    var profile: HostProfile
    var inventory: HardwareInventory?
    var history: [HistoryPoint] = []
    var status = "disconnected"
    var error: String?
    var lastReceived: Date?
    var task: Task<Void, Never>?
    var collector: DGXSparkCollector?
    var generation = UUID()
    init(_ profile: HostProfile) { self.profile = profile }
    var live: Bool { status == "connected" && (lastReceived.map { Date().timeIntervalSince($0) < 4 } ?? false) }
    var latest: MetricsSnapshot? { live ? history.last?.snapshot : nil }
    var orderedDevices: [HardwareDevice] {
        let devices = inventory?.devices ?? []
        let order = profile.deviceOrder ?? []
        return order.compactMap { id in devices.first { $0.id == id } } + devices.filter { !order.contains($0.id) }
    }
    func isVisible(_ device: HardwareDevice) -> Bool {
        !profile.hiddenDevices.contains(device.id) && (device.defaultVisible || profile.addedDevices.contains(device.id))
    }
    var visibleDevices: [HardwareDevice] { orderedDevices.filter(isVisible) }
    var editableDevices: [HardwareDevice] { visibleDevices + orderedDevices.filter { !isVisible($0) } }
    func setVisible(_ visible: Bool, device: HardwareDevice) {
        if visible { profile.hiddenDevices.remove(device.id); profile.addedDevices.insert(device.id) }
        else { profile.hiddenDevices.insert(device.id); profile.addedDevices.remove(device.id) }
    }
    func moveDevice(_ id: String, to insertion: Int) {
        var ids = editableDevices.map(\.id)
        guard let source = ids.firstIndex(of: id) else { return }
        ids.remove(at: source)
        ids.insert(id, at: min(ids.count, max(0, insertion - (source < insertion ? 1 : 0))))
        profile.deviceOrder = ids
    }
    func append(_ snapshot: MetricsSnapshot) {
        let now = Date()
        if let lastReceived, now.timeIntervalSince(lastReceived) > 3 { history.append(HistoryPoint(received: lastReceived.addingTimeInterval(1), snapshot: nil)) }
        lastReceived = now
        history.append(HistoryPoint(received: now, snapshot: snapshot))
        // Keep the sample just before the left edge for exact boundary clipping.
        while history.count > 2 && (now.timeIntervalSince(history[1].received) > 60 ||
            (now.timeIntervalSince(history[0].received) > 60 && history[1].received.timeIntervalSince(history[0].received) > 3)) { history.removeFirst() }
        status = "connected"; error = nil
    }
}

@MainActor final class AppModel {
    static let shared = AppModel()
    var preferences = Preferences()
    var hosts: [HostState] = []
    var panes = PaneSelection()
    var onChange: (() -> Void)?
    var demo = false
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SparkMonitorPreview")
    func load() {
        do {
            let file = directory.appendingPathComponent("preferences.json")
            if FileManager.default.fileExists(atPath: file.path) { preferences = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file)) }
            hosts = preferences.hosts.map(HostState.init)
        } catch { showError(error.localizedDescription) }
    }
    func save() {
        guard !demo else { return }
        preferences.hosts = hosts.map(\.profile)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(preferences)
            try data.write(to: directory.appendingPathComponent("preferences.json"), options: .atomic)
        } catch { showError(error.localizedDescription) }
    }
    func applyTheme() {
        NSApp.appearance = preferences.theme == "system" ? nil : NSAppearance(named: preferences.theme == "dark" ? .darkAqua : .aqua)
        onChange?()
    }
    func connect(_ state: HostState) {
        guard !demo else { return }
        disconnect(state)
        let generation = UUID(); state.generation = generation
        state.status = "connecting"; state.error = nil
        onChange?()
        state.task = Task { [weak self, weak state] in
            guard let self, let state else { return }
            do {
                let secret = try CredentialStore.load(state.profile.id)
                let collector = DGXSparkCollector()
                state.collector = collector
                try await collector.start(profile: state.profile, secret: secret, trust: { fingerprint in
                    guard state.generation == generation else { return false }
                    if let known = state.profile.fingerprint {
                        if known != fingerprint { state.error = tr("SSH 主机指纹已改变。请核实后重新编辑连接。", "SSH host key changed. Verify the host before editing the connection.") }
                        return known == fingerprint
                    }
                    let alert = NSAlert()
                    alert.messageText = tr("确认 SSH 主机", "Trust SSH host")
                    alert.informativeText = "\(state.profile.name)\n\(state.profile.host):\(state.profile.port)\n\nSHA256:\(fingerprint)"
                    alert.addButton(withTitle: tr("信任并连接", "Trust and connect"))
                    alert.addButton(withTitle: tr("取消", "Cancel"))
                    let accepted = alert.runModal() == .alertFirstButtonReturn
                    if accepted {
                        state.profile.fingerprint = fingerprint; self.save()
                        // Citadel 0.12 has a 10-second authentication deadline.
                        // Interactive approval must start a fresh handshake.
                        Task { @MainActor in self.connect(state) }
                    }
                    return false
                }, receive: { message in
                    guard state.generation == generation else { return }
                    if let inventory = message.inventory { state.inventory = inventory }
                    if let snapshot = message.snapshot { state.append(snapshot) }
                    self.onChange?()
                })
                if !Task.isCancelled { throw MonitorError.message("SSH stream closed") }
            } catch {
                guard state.generation == generation, !Task.isCancelled else { return }
                state.status = "disconnected"
                state.error = state.error ?? error.localizedDescription
                self.onChange?()
                if DGXSparkCollector.isNetworkError(error) {
                    try? await Task.sleep(for: .seconds(5))
                    guard state.generation == generation, !Task.isCancelled else { return }
                    self.connect(state)
                }
            }
        }
    }
    func disconnect(_ state: HostState) {
        state.generation = UUID()
        state.task?.cancel(); state.task = nil
        if let collector = state.collector { Task { await collector.stop() } }
        state.collector = nil; state.status = "disconnected"
    }
    func shutdown() async {
        let collectors = hosts.compactMap(\.collector)
        for state in hosts { state.generation = UUID(); state.task?.cancel() }
        for c in collectors { await c.stop() }
    }
    func showError(_ text: String) {
        let alert = NSAlert(); alert.messageText = tr("无法完成操作", "Unable to complete action")
        alert.informativeText = text; alert.runModal()
    }
}
