import AppKit

@MainActor final class DashboardView: FlippedView {
    let model = AppModel.shared
    let heading = label(size: 14, weight: .semibold)
    let language = NSSegmentedControl(labels: ["中文", "EN"], trackingMode: .selectOne, target: nil, action: nil)
    let theme = NSPopUpButton()
    let add = NSButton()
    let tabs = NSScrollView()
    let tabContent = FlippedView()
    var tabButtons: [NSButton] = []
    var panels: [UUID: PerformancePane] = [:]
    let emptyLabel = label(size: 24, weight: .medium)
    let emptyDetail = label(size: 14, secondary: true)
    let emptyAdd = NSButton()
    var lastStructure = ""
    var themeLanguage = ""
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        [heading, language, theme, add, tabs, emptyLabel, emptyDetail, emptyAdd].forEach(addSubview)
        language.target = self; language.action = #selector(changeLanguage)
        theme.target = self; theme.action = #selector(changeTheme)
        add.target = self; add.action = #selector(addHost); add.bezelStyle = .rounded
        emptyAdd.target = self; emptyAdd.action = #selector(addHost); emptyAdd.bezelStyle = .rounded
        tabs.documentView = tabContent; tabs.drawsBackground = false; tabs.hasHorizontalScroller = true; tabs.autohidesScrollers = true
        emptyLabel.alignment = .center; emptyDetail.alignment = .center
        model.onChange = { [weak self] in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        Style.sidebar.setFill(); bounds.fill()
        Style.grid.setFill(); NSRect(x: 0, y: 47, width: bounds.width, height: 0.5).fill()
    }
    func refresh() {
        heading.stringValue = tr("性能", "Performance") + (model.demo ? tr(" · 演示数据", " · Demo data") : "")
        language.selectedSegment = model.preferences.language == "zh" ? 0 : 1
        if themeLanguage != model.preferences.language {
            themeLanguage = model.preferences.language
            theme.removeAllItems(); theme.addItems(withTitles: [tr("跟随系统", "System theme"), tr("浅色", "Light"), tr("深色", "Dark")])
        }
        theme.selectItem(at: ["system", "light", "dark"].firstIndex(of: model.preferences.theme) ?? 0)
        add.title = tr("＋ 添加机器", "+ Add machine")
        emptyLabel.stringValue = tr("连接你的 DGX Spark", "Connect your DGX Spark")
        emptyDetail.stringValue = tr("通过 SSH 查看实时性能。无需在远端安装软件。", "Live performance over SSH. No remote installation required.")
        emptyAdd.title = tr("添加 SSH 连接", "Add SSH connection")
        [emptyLabel, emptyDetail, emptyAdd].forEach { $0.isHidden = !model.hosts.isEmpty }
        let structure = model.hosts.map { $0.profile.id.uuidString + $0.profile.name }.joined() + model.preferences.language
        if structure != lastStructure {
            lastStructure = structure
            tabButtons.forEach { $0.removeFromSuperview() }; tabButtons.removeAll()
            for (index, state) in model.hosts.enumerated() {
                let button = NSButton(title: state.profile.name, target: self, action: #selector(selectHost(_:)))
                button.tag = index; button.bezelStyle = .recessed; button.setButtonType(.pushOnPushOff)
                button.toolTip = state.profile.name
                tabContent.addSubview(button); tabButtons.append(button)
            }
        }
        for (id, panel) in panels where !model.hosts.contains(where: { $0.profile.id == id }) { panel.removeFromSuperview(); panels[id] = nil }
        for state in model.hosts {
            let id = state.profile.id
            if panels[id] == nil {
                let panel = PerformancePane(state: state)
                panel.onFocus = { [weak self] in self?.model.panes.focused = id; self?.refreshTabStates() }
                panel.onEdit = { [weak self] in self?.editHardware(state) }
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
            tab.state = model.panes.visible.contains(host.profile.id) ? .on : .off
            tab.title = (host.live ? "● " : "○ ") + host.profile.name
        }
    }
    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 22, y: 13, width: 270, height: 23)
        add.frame = NSRect(x: bounds.width - 376, y: 10, width: 133, height: 28)
        theme.frame = NSRect(x: bounds.width - 233, y: 10, width: 120, height: 28)
        language.frame = NSRect(x: bounds.width - 103, y: 11, width: 85, height: 25)
        tabs.frame = NSRect(x: 14, y: 55, width: bounds.width - 28, height: 38)
        var tabX: CGFloat = 0
        for tab in tabButtons {
            let w = max(125, CGFloat(tab.title.count) * 11 + 35)
            tab.frame = NSRect(x: tabX, y: 1, width: w, height: 27); tabX += w + 8
        }
        tabContent.frame = NSRect(x: 0, y: 0, width: max(tabs.contentSize.width, tabX), height: 30)
        model.panes.resize(width: bounds.width - 24, hosts: model.hosts.map { $0.profile.id })
        let n = model.panes.visible.count
        let w = (bounds.width - 24 - CGFloat(max(0, n - 1)) * 12) / CGFloat(max(1, n))
        for (id, panel) in panels { panel.isHidden = !model.panes.visible.contains(id) }
        for (i, id) in model.panes.visible.enumerated() {
            panels[id]?.frame = NSRect(x: 12 + CGFloat(i) * (w + 12), y: 94, width: w, height: bounds.height - 106)
        }
        refreshTabStates()
        emptyLabel.frame = NSRect(x: 40, y: bounds.height * 0.40, width: bounds.width - 80, height: 40)
        emptyDetail.frame = NSRect(x: 40, y: bounds.height * 0.40 + 48, width: bounds.width - 80, height: 30)
        emptyAdd.frame = NSRect(x: bounds.width / 2 - 115, y: bounds.height * 0.40 + 98, width: 230, height: 32)
    }
    @objc func changeLanguage() { model.preferences.language = language.selectedSegment == 0 ? "zh" : "en"; model.save(); refresh() }
    @objc func changeTheme() { model.preferences.theme = ["system", "light", "dark"][theme.indexOfSelectedItem]; model.save(); model.applyTheme() }
    @objc func selectHost(_ button: NSButton) { model.panes.select(model.hosts[button.tag].profile.id); needsLayout = true }
    @objc func addHost() { editHost(nil) }
}
