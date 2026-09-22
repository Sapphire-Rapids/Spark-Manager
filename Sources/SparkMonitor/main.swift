import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var dashboard: DashboardView!
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        if CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--render-previews") { model.loadDemo() } else { model.load() }
        if CommandLine.arguments.contains("--english") { model.preferences.language = "en" }
        if CommandLine.arguments.contains("--dark") { model.preferences.theme = "dark" }
        if CommandLine.arguments.contains("--light") { model.preferences.theme = "light" }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = tr("DGX Spark管理器", "Spark Manager")
        window.minSize = NSSize(width: 920, height: 740)
        window.isReleasedWhenClosed = false
        dashboard = DashboardView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        window.contentView = dashboard
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appMenu.addItem(appItem)
        let menu = NSMenu(); menu.addItem(withTitle: "Quit Spark Manager", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = menu
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); let editMenu = NSMenu(title: "Edit")
        for (name, action, key) in [("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(withTitle: name, action: action, keyEquivalent: key)
        }
        edit.submenu = editMenu; appMenu.addItem(edit); NSApp.mainMenu = appMenu
        model.applyTheme(); window.center()
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > index + 1 {
            renderPreviews(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            NSApp.terminate(nil); return
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if model.demo { model.tickDemo() }
                for state in model.hosts where !model.demo && state.status == "connected" && Date().timeIntervalSince(state.lastReceived ?? Date()) > 6 {
                    model.connect(state)
                }
                self?.dashboard.refresh()
            }
        }
        if !model.demo { model.hosts.forEach(model.connect) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func renderPreviews(to directory: URL) {
        let model = AppModel.shared
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, theme, language, logical, device, width) in [
                ("cpu-zh", "light", "zh", true, "cpu", 1280.0),
                ("memory-zh", "light", "zh", false, "memory", 1280.0),
                ("disk-zh", "light", "zh", false, "disk:demo", 1280.0),
                ("network-zh", "light", "zh", false, "net:demo", 1280.0),
                ("gpu-zh", "light", "zh", false, "gpu:demo", 1280.0),
                ("light-en", "light", "en", false, "cpu", 1280.0),
                ("dark-zh-cores", "dark", "zh", true, "cpu", 1280.0),
                ("wide-two-machines", "light", "en", false, "cpu", 2320.0)
            ] {
                model.preferences.theme = theme; model.preferences.language = language
                model.hosts[0].profile.logicalCPU = logical
                model.hosts[0].profile.selectedDevice = device
                window.setContentSize(NSSize(width: width, height: 720))
                model.applyTheme(); dashboard.refresh(); dashboard.layoutSubtreeIfNeeded()
                let rep = dashboard.bitmapImageRepForCachingDisplay(in: dashboard.bounds)!
                dashboard.cacheDisplay(in: dashboard.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
            }
        } catch { fputs("Preview export failed: \(error)\n", stderr) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        timer?.invalidate(); AppModel.shared.save()
        Task { await AppModel.shared.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.setActivationPolicy(.regular)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
