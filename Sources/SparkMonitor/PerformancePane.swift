import AppKit

@MainActor final class PerformancePane: FlippedView {
    let state: HostState
    let titleLabel = label(size: 28, weight: .semibold)
    let modelLabel = label(size: 13)
    let hostLabel = label(size: 12, weight: .semibold)
    let statusLabel = label(size: 11, secondary: true)
    let unitLabel = label(size: 11, secondary: true)
    let scaleLabel = label(size: 11, secondary: true)
    let timeLabel = label(size: 11, secondary: true)
    let zeroLabel = label("0", size: 11, secondary: true)
    let transferLabel = label(size: 11, secondary: true)
    let transferScale = label(size: 11, secondary: true)
    let sidebar = NSScrollView()
    let rowContainer = FlippedView()
    let editButton = NSButton()
    let connectionButton = NSButton()
    var rows: [HardwareRow] = []
    var charts: [ChartView] = []
    var details: [NSTextField] = []
    var detailFrames: [NSRect] = []
    var onEdit: (() -> Void)?
    var onConnection: (() -> Void)?
    var onFocus: (() -> Void)?
    var viewKey = ""
    var chartBottom: CGFloat = 0
    let sideWidth: CGFloat = 218
    init(state: HostState) {
        self.state = state
        super.init(frame: .zero)
        [titleLabel, modelLabel, hostLabel, statusLabel, unitLabel, scaleLabel, timeLabel, zeroLabel, transferLabel, transferScale].forEach(addSubview)
        modelLabel.alignment = .right; scaleLabel.alignment = .right; zeroLabel.alignment = .right
        transferScale.alignment = .right
        sidebar.documentView = rowContainer; sidebar.hasVerticalScroller = true; sidebar.drawsBackground = false
        addSubview(sidebar)
        editButton.isBordered = false; editButton.target = self; editButton.action = #selector(edit)
        connectionButton.isBordered = false; connectionButton.target = self; connectionButton.action = #selector(connection)
        addSubview(editButton); addSubview(connectionButton)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func edit() { onEdit?() }
    @objc func connection() { onConnection?() }
    override func mouseDown(with event: NSEvent) { onFocus?() }
    override func draw(_ dirtyRect: NSRect) {
        Style.surface.setFill(); bounds.fill()
        Style.sidebar.setFill(); NSRect(x: 0, y: 38, width: sideWidth, height: bounds.height - 38).fill()
        Style.grid.setFill(); NSRect(x: 0, y: 37, width: bounds.width, height: 0.5).fill()
    }
    var selected: HardwareDevice? {
        state.visibleDevices.first { $0.id == state.profile.selectedDevice } ?? state.visibleDevices.first
    }
    func refresh() {
        let devices = state.visibleDevices
        let key = devices.map(\.id).joined(separator: "|") + (selected?.id ?? "") + String(state.profile.logicalCPU) + AppModel.shared.preferences.language
        if key != viewKey {
            viewKey = key
            rows.forEach { $0.removeFromSuperview() }; rows.removeAll()
            for device in devices {
                let row = HardwareRow(device: device); row.target = self; row.action = #selector(selectRow(_:))
                rowContainer.addSubview(row); rows.append(row)
            }
            charts.forEach { $0.removeFromSuperview() }; charts.removeAll()
            if let device = selected {
                let coreCount = state.inventory?.devices.first { $0.kind == .cpu }?.metadata["cores"].flatMap(Int.init) ?? 20
                let count = device.kind == .cpu && state.profile.logicalCPU ? coreCount : device.kind == .disk ? 2 : 1
                for i in 0..<count {
                    let chart = ChartView(); chart.color = Style.color(device.kind)
                    chart.stacked = device.kind == .cpu; chart.logical = state.profile.logicalCPU
                    if device.kind == .cpu {
                        if state.profile.logicalCPU { chart.coreIndex = i }
                        chart.onMode = { [weak self] logical in
                            guard let self else { return }; state.profile.logicalCPU = logical
                            AppModel.shared.save(); self.refresh()
                        }
                    }
                    addSubview(chart); charts.append(chart)
                }
            }
        }
        hostLabel.stringValue = state.profile.name
        statusLabel.stringValue = state.live ? tr("已连接 · 每秒更新", "Connected · 1 second updates") : state.status == "connecting" ? tr("正在连接…", "Connecting…") : tr("未连接", "Disconnected")
        statusLabel.textColor = state.live ? .secondaryLabelColor : .systemOrange
        statusLabel.toolTip = state.error
        connectionButton.title = state.error != nil ? tr("连接详情", "Connection details") : tr("连接设置", "Connection settings")
        editButton.title = tr("编辑", "Edit")
        let device = selected
        titleLabel.stringValue = device.map(deviceTitle) ?? tr("性能", "Performance")
        modelLabel.stringValue = device?.model ?? ""
        let metric = device.flatMap { state.latest?.devices[$0.id] }
        transferLabel.isHidden = device?.kind != .disk; transferScale.isHidden = device?.kind != .disk
        for row in rows {
            row.selected = row.device.id == device?.id
            row.nameLabel.stringValue = deviceTitle(row.device)
            let m = state.latest?.devices[row.device.id]
            if row.device.kind == .network {
                row.subtitle.stringValue = row.device.name + "\n" + bytes(m?.value("receive"), perSecond: true)
                row.chart.points = series(state, device: row.device, key: "receive", second: "send")
                row.chart.ceiling = max(1024, row.chart.points.flatMap { [$0.total, $0.secondary].compactMap { $0 } }.max() ?? 0) * 1.1
            } else {
                row.subtitle.stringValue = row.device.kind == .memory ? bytes(m?.value("used")) + " (" + number(m?.value("usage"), "%", digits: 0) + ")" : number(m?.value("usage"), "%", digits: 0)
                row.chart.points = series(state, device: row.device)
            }
            row.setAccessibilityLabel(row.nameLabel.stringValue + ", " + row.subtitle.stringValue)
            row.chart.needsDisplay = true; row.needsDisplay = true
        }
        unitLabel.stringValue = tr("% 利用率", "% Utilization")
        scaleLabel.stringValue = "100%"
        timeLabel.stringValue = tr("60 秒", "60 seconds")
        if let device {
            for (index, chart) in charts.enumerated() {
                var key = "usage"; var second: String? = device.kind == .cpu ? "system" : nil
                if device.kind == .network { key = "receive"; second = "send" }
                if device.kind == .disk && index == 1 { key = "read"; second = "write" }
                chart.points = series(state, device: device, key: key, second: second, core: chart.coreIndex)
                chart.ceiling = key == "usage" ? 100 : max(1024, chart.points.flatMap { [$0.total, $0.secondary].compactMap { $0 } }.max() ?? 0) * 1.1
                if device.kind == .network {
                    unitLabel.stringValue = tr("接收（实线）／发送（虚线）", "Receive (solid) / Send (dashed)")
                    scaleLabel.stringValue = bytes(chart.ceiling, perSecond: true)
                }
                if device.kind == .disk && index == 1 {
                    transferLabel.stringValue = tr("磁盘传输速率 · 读实线 / 写虚线", "Disk transfer rate · Read solid / Write dashed")
                    transferScale.stringValue = bytes(chart.ceiling, perSecond: true)
                }
                let accessibleUsage = chart.coreIndex.flatMap { index in metric?.cores?.first { ($0["index"] ?? nil) == Double(index) }?["usage"] ?? nil } ?? metric?.value("usage")
                chart.setAccessibilityLabel((chart.coreIndex.map { "CPU \($0)" } ?? deviceTitle(device)) + ", " + number(accessibleUsage, "%"))
                chart.needsDisplay = true
            }
            updateDetails(device: device, metric: metric)
        } else {
            details.forEach { $0.removeFromSuperview() }; details.removeAll(); detailFrames.removeAll()
            let text = label(state.error ?? tr("连接机器后显示硬件指标。", "Connect a machine to view hardware metrics."), size: 14, secondary: true)
            text.maximumNumberOfLines = 6; text.lineBreakMode = .byWordWrapping
            addSubview(text); details.append(text)
        }
        needsLayout = true; needsDisplay = true
    }
    @objc func selectRow(_ row: HardwareRow) {
        onFocus?(); state.profile.selectedDevice = row.device.id
        AppModel.shared.save(); refresh()
    }
    func updateDetails(device: HardwareDevice, metric: DeviceMetrics?) {
        details.forEach { $0.removeFromSuperview() }; details.removeAll(); detailFrames.removeAll()
        func v(_ key: String) -> Double? { metric?.value(key) }
        var primary: [(String, String)] = []
        var facts: [(String, String)] = []
        switch device.kind {
        case .cpu:
            primary = [(tr("利用率", "Utilization"), number(v("usage"), "%")), (tr("速度", "Speed"), number(v("frequency").map { $0 / 1000 }, " GHz", digits: 2)),
                       (tr("系统", "System"), number(v("system"), "%")), (tr("用户", "User"), number(v("user"), "%"))]
            let uptime = state.latest.map { Int($0.uptime) }
            let duration = uptime.map { String(format: "%d:%02d:%02d:%02d", $0 / 86400, $0 / 3600 % 24, $0 / 60 % 60, $0 % 60) } ?? "—"
            facts = [(tr("逻辑处理器", "Logical processors"), device.metadata["cores"] ?? "—"),
                     (tr("体系结构", "Architecture"), device.metadata["architecture"] ?? "—"),
                     (tr("CPU 热区最高温", "CPU hottest zone"), number(v("temperature"), " °C")),
                     (tr("运行时间", "Up time"), duration)]
            for (name, temperature) in (metric?.sensors ?? [:]).sorted(by: { $0.key < $1.key }) {
                facts.append((name, number(temperature, " °C")))
            }
        case .memory:
            primary = [(tr("已用", "In use"), bytes(v("used"))), (tr("可用", "Available"), bytes(v("available"))),
                       (tr("已缓存", "Cached"), bytes(v("cached"))), (tr("Swap 已用", "Swap used"), bytes(v("swapUsed")))]
            facts = [(tr("系统总量", "OS total"), bytes(v("total"))), (tr("Swap 总量", "Swap total"), bytes(v("swapTotal"))),
                     (tr("内存类型", "Memory type"), "LPDDR5X"), (tr("架构", "Architecture"), tr("CPU / GPU 统一内存", "CPU / GPU unified memory")),
                     (tr("已用口径", "In-use calculation"), tr("总量 − 可用", "Total − available"))]
        case .disk:
            unitLabel.stringValue = tr("% 活动时间", "% Active time")
            primary = [(tr("活动时间", "Active time"), number(v("usage"), "%")), (tr("温度", "Temperature"), number(v("temperature"), " °C")),
                       (tr("读取速度", "Read speed"), bytes(v("read"), perSecond: true)), (tr("写入速度", "Write speed"), bytes(v("write"), perSecond: true))]
            facts = [(tr("物理容量", "Physical capacity"), bytes(v("capacity"))), (tr("文件系统总量", "Filesystem total"), bytes(v("total"))),
                     (tr("可用空间", "Available space"), bytes(v("free"))), (tr("温度来源", "Temperature source"), "NVMe Composite")]
        case .network:
            primary = [(tr("发送", "Send"), bytes(v("send"), perSecond: true)), (tr("接收", "Receive"), bytes(v("receive"), perSecond: true)),
                       (tr("累计发送", "Total sent"), bytes(v("sent"))), (tr("累计接收", "Total received"), bytes(v("received")))]
            facts = [(tr("接口", "Interface"), device.name), (tr("链路速度", "Link speed"), number(v("linkSpeed"), " Mbps", digits: 0)),
                     ("IP", device.metadata["address"].flatMap { $0.isEmpty ? nil : $0 } ?? "—"),
                     (tr("链路状态", "Link state"), v("up").map { $0 == 1 ? tr("已连接", "Up") : tr("未连接", "Down") } ?? "—"),
                     (tr("错误 / 丢包", "Errors / drops"), number(v("errors"), digits: 0) + " / " + number(v("drops"), digits: 0))]
            if device.metadata["rdma_ports"] != "[]" {
                facts += [(tr("RDMA 累计发送", "RDMA total sent"), bytes(v("rdmaSent"))), (tr("RDMA 累计接收", "RDMA total received"), bytes(v("rdmaReceived")))]
            }
        case .gpu:
            primary = [(tr("利用率", "Utilization"), number(v("usage"), "%")), (tr("GPU 温度", "GPU temperature"), number(v("temperature"), " °C")),
                       (tr("GPU 功耗", "GPU power"), number(v("power"), " W")), (tr("频率", "Clock"), number(v("frequency"), " MHz", digits: 0))]
            facts = [(tr("驱动版本", "Driver version"), device.metadata["driver"] ?? "—"), (tr("内存架构", "Memory architecture"), tr("与 CPU 共用系统内存", "Shared with the CPU")),
                     (tr("内存活动率", "Memory activity"), number(v("memoryActivity"), "%")),
                     (tr("功耗口径", "Power scope"), tr("驱动读数，非整机功耗", "Driver reading, not wall power"))]
        }
        for (index, pair) in primary.enumerated() {
            let x = CGFloat(index % 2) * 154; let y = CGFloat(index / 2) * 65
            let title = label(pair.0, size: 12, secondary: true)
            let value = label(pair.1, size: 22)
            if device.kind == .cpu && index >= 2 { value.textColor = Style.color(.cpu).withAlphaComponent(index == 2 ? 1 : 0.7) }
            addSubview(title); addSubview(value); details += [title, value]
            detailFrames += [NSRect(x: x, y: y, width: 150, height: 18), NSRect(x: x, y: y + 19, width: 150, height: 30)]
        }
        for (index, pair) in facts.enumerated() {
            let title = label(pair.0 + ":", size: 11, secondary: true)
            let value = label(pair.1, size: 11)
            title.toolTip = pair.0; value.toolTip = pair.1
            addSubview(title); addSubview(value); details += [title, value]
            detailFrames += [NSRect(x: 322, y: CGFloat(index) * 23, width: 130, height: 19), NSRect(x: 457, y: CGFloat(index) * 23, width: 180, height: 19)]
        }
    }
    override func layout() {
        super.layout()
        let width = bounds.width
        hostLabel.frame = NSRect(x: 16, y: 10, width: 180, height: 19)
        statusLabel.frame = NSRect(x: 200, y: 11, width: max(100, width - 365), height: 18)
        connectionButton.frame = NSRect(x: width - 146, y: 6, width: 134, height: 26)
        sidebar.frame = NSRect(x: 7, y: 49, width: sideWidth - 12, height: max(80, bounds.height - 102))
        rowContainer.frame = NSRect(x: 0, y: 0, width: sidebar.contentSize.width, height: CGFloat(rows.count) * 72)
        for (i, row) in rows.enumerated() { row.frame = NSRect(x: 0, y: CGFloat(i) * 72, width: rowContainer.bounds.width, height: 70) }
        editButton.frame = NSRect(x: 12, y: bounds.height - 41, width: sideWidth - 24, height: 30)
        let x = sideWidth + 25; let w = width - x - 25
        titleLabel.frame = NSRect(x: x, y: 57, width: w * 0.55, height: 39)
        modelLabel.frame = NSRect(x: x + w * 0.5, y: 70, width: w * 0.5, height: 22)
        unitLabel.frame = NSRect(x: x, y: 111, width: w * 0.75, height: 19)
        scaleLabel.frame = NSRect(x: x + w * 0.75, y: 111, width: w * 0.25, height: 19)
        let top: CGFloat = 136
        let height = max(200, min(460, bounds.height - 405))
        if selected?.kind == .cpu && state.profile.logicalCPU {
            let rows = CGFloat((charts.count + 4) / 5)
            let cellWidth = (w - 24) / 5; let cellHeight = (height - max(0, rows - 1) * 6) / max(1, rows)
            for (i, chart) in charts.enumerated() { chart.frame = NSRect(x: x + CGFloat(i % 5) * (cellWidth + 6), y: top + CGFloat(i / 5) * (cellHeight + 6), width: cellWidth, height: cellHeight) }
        } else if selected?.kind == .disk && charts.count == 2 {
            charts[0].frame = NSRect(x: x, y: top, width: w, height: height * 0.59 - 7)
            transferLabel.frame = NSRect(x: x, y: top + height * 0.59, width: w * 0.75, height: 19)
            transferScale.frame = NSRect(x: x + w * 0.75, y: top + height * 0.59, width: w * 0.25, height: 19)
            charts[1].frame = NSRect(x: x, y: top + height * 0.59 + 23, width: w, height: height * 0.41 - 23)
            charts[1].toolTip = tr("传输速度：读取实线，写入虚线。自动纵轴。", "Transfer rate: read solid, write dashed. Automatic scale.")
        } else { charts.first?.frame = NSRect(x: x, y: top, width: w, height: height) }
        chartBottom = top + height
        timeLabel.frame = NSRect(x: x, y: chartBottom + 7, width: 180, height: 19)
        zeroLabel.frame = NSRect(x: x + w - 28, y: chartBottom + 7, width: 28, height: 19)
        let statsY = chartBottom + 43
        for (i, detail) in details.enumerated() {
            if i < detailFrames.count {
                var r = detailFrames[i]
                // Preserve legible detail columns at the minimum pane width.
                if r.minX >= 322 { r.origin.x = w * 0.53 + (r.minX == 322 ? 0 : w * 0.23); r.size.width = r.minX >= w * 0.75 ? w * 0.24 : w * 0.23 }
                r.origin.x += x; r.origin.y += statsY; detail.frame = r
            } else { detail.frame = NSRect(x: x, y: top + 60, width: w, height: 160) }
        }
    }
}
