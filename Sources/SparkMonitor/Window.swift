import AppKit

@MainActor final class NavigationRow: NSButton {
    var caption = ""
    var symbol = "desktopcomputer"
    var selected = false
    var compact = false
    var online = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if selected {
            (Style.dark ? NSColor(white: 0.21, alpha: 1) : NSColor(srgbRed: 0.902, green: 0.918, blue: 0.926, alpha: 1)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 4, yRadius: 4).fill()
            NSColor(srgbRed: 0.08, green: 0.46, blue: 0.69, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 5, y: 11, width: 3, height: 19), xRadius: 1.5, yRadius: 1.5).fill()
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular).applying(.init(paletteColors: [.labelColor]))
            let icon = image.withSymbolConfiguration(configuration) ?? image
            icon.draw(in: NSRect(x: compact ? 15 : 18, y: 11, width: 19, height: 19))
        }
        if !compact {
            (caption as NSString).draw(in: NSRect(x: 54, y: 10, width: bounds.width - 79, height: 25), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor])
        }
    }
}

@MainActor final class DashboardView: FlippedView {
    let model = AppModel.shared
    let heading = label(size: 15)
    let language = NSSegmentedControl(labels: ["中文", "EN"], trackingMode: .selectOne, target: nil, action: nil)
    let more = NSButton()
    let add = NSButton()
    let hamburger = NSButton()
    let settings = NavigationRow()
    let tabs = NSScrollView()
    let tabContent = FlippedView()
    var tabButtons: [NavigationRow] = []
    var panels: [UUID: PerformancePane] = [:]
    let emptyLabel = label(size: 24)
    let emptyDetail = label(size: 14, secondary: true)
    let emptyAdd = NSButton()
    var lastStructure = ""
    var collapsed: Bool?
    var navigationWidth: CGFloat = 268
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        [heading, language, more, add, hamburger, settings, tabs, emptyLabel, emptyDetail, emptyAdd].forEach(addSubview)
        language.target = self; language.action = #selector(changeLanguage)
        add.target = self; add.action = #selector(addHost); add.isBordered = false; add.font = .systemFont(ofSize: 14)
        add.image = NSImage(systemSymbolName: "plus.rectangle.on.rectangle", accessibilityDescription: nil); add.imagePosition = .imageLeading
        more.title = "…"; more.font = .systemFont(ofSize: 22); more.isBordered = false; more.target = self; more.action = #selector(showMore)
        hamburger.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil); hamburger.isBordered = false
        hamburger.target = self; hamburger.action = #selector(toggleNavigation); hamburger.setAccessibilityLabel("Navigation")
        settings.isBordered = false; settings.symbol = "gearshape"; settings.target = self; settings.action = #selector(openSettings)
        emptyAdd.target = self; emptyAdd.action = #selector(addHost); emptyAdd.bezelStyle = .rounded
        tabs.documentView = tabContent; tabs.drawsBackground = false; tabs.hasVerticalScroller = true; tabs.autohidesScrollers = true
        emptyLabel.alignment = .center; emptyDetail.alignment = .center
        model.onChange = { [weak self] in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        Style.sidebar.setFill(); bounds.fill()
        let paper = NSRect(x: navigationWidth, y: 24, width: bounds.width - navigationWidth + 12, height: bounds.height - 12)
        let outline = NSBezierPath(roundedRect: paper, xRadius: 9, yRadius: 9)
        Style.surface.setFill(); outline.fill()
        Style.grid.setStroke(); outline.lineWidth = 1; outline.stroke()
        Style.grid.setFill(); NSRect(x: navigationWidth, y: 79, width: bounds.width - navigationWidth, height: 1).fill()
    }
    func refresh() {
        window?.title = tr("DGX Spark管理器", "Spark Manager")
        heading.stringValue = model.demo ? tr("性能（演示数据）", "Performance (demo)") : tr("性能", "Performance")
        language.selectedSegment = model.preferences.language == "zh" ? 0 : 1
        add.title = tr("添加机器", "Add machine")
        settings.caption = tr("设置", "Settings"); settings.setAccessibilityLabel(settings.caption)
        more.setAccessibilityLabel(tr("更多选项", "More options"))
        emptyLabel.stringValue = tr("连接你的 DGX Spark", "Connect your DGX Spark")
        emptyDetail.stringValue = tr("通过 SSH 查看实时性能。无需在远端安装软件。", "Live performance over SSH. No remote installation required.")
        emptyAdd.title = tr("添加 SSH 连接", "Add SSH connection")
        [emptyLabel, emptyDetail, emptyAdd].forEach { $0.isHidden = !model.hosts.isEmpty }
        let structure = model.hosts.map { $0.profile.id.uuidString + $0.profile.name }.joined() + model.preferences.language
        if structure != lastStructure {
            lastStructure = structure
            tabButtons.forEach { $0.removeFromSuperview() }; tabButtons.removeAll()
            for (index, state) in model.hosts.enumerated() {
                let button = NavigationRow(); button.isBordered = false; button.caption = state.profile.name
                button.target = self; button.action = #selector(selectHost(_:)); button.tag = index
                button.setAccessibilityLabel(state.profile.name); button.toolTip = state.profile.name
                tabContent.addSubview(button); tabButtons.append(button)
            }
        }
        for (id, panel) in panels where !model.hosts.contains(where: { $0.profile.id == id }) { panel.removeFromSuperview(); panels[id] = nil }
        for state in model.hosts {
            let id = state.profile.id
            if panels[id] == nil {
                let panel = PerformancePane(state: state)
                panel.onFocus = { [weak self] in self?.model.panes.focused = id; self?.refreshTabStates() }
                panel.onConnection = { [weak self] in self?.editHost(state) }
                panels[id] = panel; addSubview(panel)
            }
            panels[id]?.refresh()
        }
        needsLayout = true; needsDisplay = true
    }
    func refreshTabStates() {
        for (index, tab) in tabButtons.enumerated() {
            let host = model.hosts[index]
            tab.selected = model.panes.focused == host.profile.id
            tab.online = host.live
            tab.toolTip = host.profile.name + "\n" + (host.live ? tr("已连接", "Connected") : host.error ?? tr("未连接", "Disconnected"))
            tab.needsDisplay = true
        }
    }
    override func layout() {
        super.layout()
        let compact = collapsed ?? (bounds.width < 1140)
        navigationWidth = compact ? 48 : 268
        let bodyWidth = bounds.width - navigationWidth
        heading.frame = NSRect(x: navigationWidth + 19, y: 41, width: 235, height: 24)
        add.frame = NSRect(x: bounds.width - 254, y: 39, width: 128, height: 29)
        language.frame = NSRect(x: bounds.width - 122, y: 42, width: 80, height: 24)
        more.frame = NSRect(x: bounds.width - 40, y: 35, width: 35, height: 33)
        hamburger.frame = NSRect(x: 10, y: 29, width: 34, height: 36)
        tabs.frame = NSRect(x: 0, y: 76, width: navigationWidth - 4, height: bounds.height - 142)
        for (i, tab) in tabButtons.enumerated() { tab.compact = compact; tab.frame = NSRect(x: 0, y: CGFloat(i) * 44, width: navigationWidth - 4, height: 40) }
        tabContent.frame = NSRect(x: 0, y: 0, width: tabs.contentSize.width, height: CGFloat(tabButtons.count) * 44)
        settings.compact = compact; settings.frame = NSRect(x: 0, y: bounds.height - 49, width: navigationWidth - 4, height: 40); settings.needsDisplay = true
        model.panes.resize(width: bodyWidth, hosts: model.hosts.map { $0.profile.id })
        let n = model.panes.visible.count
        let w = (bodyWidth - CGFloat(max(0, n - 1)) * 12) / CGFloat(max(1, n))
        for (id, panel) in panels { panel.isHidden = !model.panes.visible.contains(id) }
        for (i, id) in model.panes.visible.enumerated() {
            panels[id]?.showsHost = n > 1
            panels[id]?.frame = NSRect(x: navigationWidth + CGFloat(i) * (w + 12), y: 80, width: w, height: bounds.height - 80)
        }
        refreshTabStates()
        emptyLabel.frame = NSRect(x: navigationWidth + 30, y: bounds.height * 0.40, width: bodyWidth - 60, height: 40)
        emptyDetail.frame = NSRect(x: navigationWidth + 30, y: bounds.height * 0.40 + 48, width: bodyWidth - 60, height: 30)
        emptyAdd.frame = NSRect(x: navigationWidth + bodyWidth / 2 - 115, y: bounds.height * 0.40 + 98, width: 230, height: 32)
    }
    @objc func changeLanguage() { model.preferences.language = language.selectedSegment == 0 ? "zh" : "en"; model.save(); refresh() }
    @objc func toggleNavigation() { collapsed = !(navigationWidth == 48); needsLayout = true; needsDisplay = true }
    @objc func selectHost(_ button: NSButton) { model.panes.select(model.hosts[button.tag].profile.id); needsLayout = true }
    @objc func addHost() { editHost(nil) }
    @objc func openSettings() { editHost(model.hosts.first { $0.profile.id == model.panes.focused }) }
    @objc func showMore() {
        let menu = NSMenu()
        for (i, name) in [tr("跟随系统", "System theme"), tr("浅色", "Light"), tr("深色", "Dark")].enumerated() {
            let item = NSMenuItem(title: name, action: #selector(changeTheme(_:)), keyEquivalent: "")
            item.target = self; item.tag = i; item.state = model.preferences.theme == ["system", "light", "dark"][i] ? .on : .off; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height), in: more)
    }
    @objc func changeTheme(_ item: NSMenuItem) { model.preferences.theme = ["system", "light", "dark"][item.tag]; model.save(); model.applyTheme() }
}
