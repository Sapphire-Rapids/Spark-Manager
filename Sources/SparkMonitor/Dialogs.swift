import AppKit

@MainActor extension DashboardView {
    func editHost(_ state: HostState?) {
        let original = state?.profile
        let alert = NSAlert()
        alert.messageText = original == nil ? tr("添加机器", "Add machine") : tr("连接设置", "Connection settings")
        alert.informativeText = state?.error ?? tr("使用 SSH 密钥或密码连接。私钥只在本机读取。", "Connect using an SSH key or password. Private keys stay on this Mac.")
        alert.addButton(withTitle: tr("保存并连接", "Save and connect"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        if original != nil { alert.addButton(withTitle: tr("移除连接", "Remove connection")); alert.addButton(withTitle: tr("断开连接", "Disconnect")) }
        let form = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: 354))
        func field(_ title: String, value: String, y: CGFloat) -> NSTextField {
            let name = label(title, size: 12); name.frame = NSRect(x: 0, y: y + 4, width: 120, height: 20); form.addSubview(name)
            let input = NSTextField(string: value); input.frame = NSRect(x: 125, y: y, width: 370, height: 25); form.addSubview(input); input.setAccessibilityLabel(title)
            return input
        }
        let name = field(tr("名称", "Name"), value: original?.name ?? "", y: 0)
        let host = field(tr("地址", "Host"), value: original?.host ?? "", y: 38)
        let port = field(tr("端口", "Port"), value: String(original?.port ?? 22), y: 76)
        let user = field(tr("用户名", "Username"), value: original?.username ?? "", y: 114)
        let authLabel = label(tr("认证方式", "Authentication"), size: 12); authLabel.frame = NSRect(x: 0, y: 156, width: 120, height: 20); form.addSubview(authLabel)
        let auth = NSPopUpButton(frame: NSRect(x: 125, y: 152, width: 370, height: 26))
        auth.addItems(withTitles: [tr("私钥（Ed25519 / RSA）", "Private key (Ed25519 / RSA)"), tr("密码", "Password")])
        auth.selectItem(at: original?.authentication == "password" ? 1 : 0); form.addSubview(auth)
        let key = field(tr("私钥路径", "Private key path"), value: original?.keyPath ?? "~/.ssh/id_ed25519", y: 190)
        let secretLabel = label(tr("密码 / 私钥口令", "Password / passphrase"), size: 12); secretLabel.frame = NSRect(x: 0, y: 232, width: 125, height: 20); form.addSubview(secretLabel)
        let secret = NSSecureTextField(frame: NSRect(x: 125, y: 228, width: 370, height: 25))
        secret.placeholderString = tr("留空保留已有凭据", "Leave blank to keep existing credential"); secret.setAccessibilityLabel(secretLabel.stringValue); form.addSubview(secret)
        let forget = NSButton(checkboxWithTitle: tr("清除已保存的密码 / 口令", "Forget saved password / passphrase"), target: nil, action: nil)
        forget.frame = NSRect(x: 125, y: 266, width: 370, height: 24); form.addSubview(forget)
        let resetTrust = NSButton(checkboxWithTitle: tr("重新确认主机指纹", "Confirm host fingerprint again"), target: nil, action: nil)
        resetTrust.frame = NSRect(x: 125, y: 300, width: 370, height: 24); form.addSubview(resetTrust)
        alert.accessoryView = form
        let response = alert.runModal()
        if response == .alertSecondButtonReturn { return }
        if response.rawValue == NSApplication.ModalResponse.alertThirdButtonReturn.rawValue, let state {
            model.disconnect(state); CredentialStore.remove(state.profile.id)
            model.hosts.removeAll { $0.profile.id == state.profile.id }; model.save(); refresh(); return
        }
        if response.rawValue == NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1, let state {
            model.disconnect(state); refresh(); return
        }
        guard let portNumber = Int(port.stringValue), (1...65535).contains(portNumber), !host.stringValue.trimmingCharacters(in: .whitespaces).isEmpty, !user.stringValue.isEmpty else {
            model.showError(tr("请填写地址、用户名和有效端口。", "Enter a host, username and valid port.")); return
        }
        var profile = original ?? HostProfile(name: "", host: "", username: "")
        profile.name = name.stringValue.isEmpty ? host.stringValue : name.stringValue
        profile.host = host.stringValue.trimmingCharacters(in: .whitespaces); profile.port = portNumber
        profile.username = user.stringValue; profile.authentication = auth.indexOfSelectedItem == 0 ? "key" : "password"; profile.keyPath = key.stringValue
        if original?.host != profile.host || original?.port != profile.port || resetTrust.state == .on { profile.fingerprint = nil }
        do {
            if forget.state == .on || original?.authentication != profile.authentication || original?.keyPath != profile.keyPath { CredentialStore.remove(profile.id) }
            if !secret.stringValue.isEmpty { try CredentialStore.save(secret.stringValue, id: profile.id) }
            let storedCredential = try CredentialStore.load(profile.id)
            if profile.authentication == "password" && storedCredential == nil {
                model.showError(tr("请填写密码。", "Enter a password.")); return
            }
        } catch { model.showError(error.localizedDescription); return }
        let target = state ?? HostState(profile)
        target.profile = profile
        if state == nil { model.hosts.append(target); model.panes.select(profile.id) }
        model.save(); model.connect(target); refresh()
    }
}
