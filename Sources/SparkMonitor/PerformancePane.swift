import AppKit

@MainActor final class PerformancePane: FlippedView {
    let state: HostState
    let titleLabel = label(size: 32)
    let modelLabel = label(size: 18)
    let hostLabel = label(size: 14)
    let sidebar = NSScrollView()
    let rowContainer = FlippedView()
    let detailScroll = NSScrollView()
    let content = FlippedView()
    let editButton = NSButton()
    let composition = MemoryCompositionView()
    var rows: [HardwareRow] = []
    var charts: [ChartView] = []
    var chartTitles: [NSTextField] = []
    var chartScales: [NSTextField] = []
    var chartTimes: [NSTextField] = []
    var chartZeros: [NSTextField] = []
    var details: [(NSTextField, NSRect)] = []
    var onEdit: (() -> Void)?
    var onConnection: (() -> Void)?
    var onFocus: (() -> Void)?
    var viewKey = ""
    var showsHost = false
    var statsTop: CGFloat = 0
    var detailLayoutKey = ""
    let sideWidth: CGFloat = 232
    init(state: HostState) {
        self.state = state
        super.init(frame: .zero)
        sidebar.documentView = rowContainer; sidebar.hasVerticalScroller = true; sidebar.autohidesScrollers = true; sidebar.drawsBackground = false
        detailScroll.documentView = content; detailScroll.hasVerticalScroller = true; detailScroll.autohidesScrollers = true; detailScroll.drawsBackground = false
        addSubview(sidebar); addSubview(detailScroll); addSubview(hostLabel)
        content.addSubview(titleLabel); content.addSubview(modelLabel); content.addSubview(composition)
        modelLabel.alignment = .right
        editButton.isBordered = false; editButton.font = .systemFont(ofSize: 14); editButton.target = self; editButton.action = #selector(edit)
        addSubview(editButton)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func edit() { onEdit?() }
    override func mouseDown(with event: NSEvent) { onFocus?() }
    override func draw(_ dirtyRect: NSRect) { Style.surface.setFill(); bounds.fill() }
    var selected: HardwareDevice? { state.visibleDevices.first { $0.id == state.profile.selectedDevice } ?? state.visibleDevices.first }
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
            (chartTitles + chartScales + chartTimes + chartZeros).forEach { $0.removeFromSuperview() }
            chartTitles = []; chartScales = []; chartTimes = []; chartZeros = []
            if let device = selected {
                let cores = Int(device.metadata["cores"] ?? "20") ?? 20
                let count = device.kind == .cpu && state.profile.logicalCPU ? cores : device.kind == .disk ? 2 : device.kind == .gpu ? 6 : 1
                for i in 0..<count {
                    let chart = ChartView(); chart.kind = device.kind; chart.color = Style.color(device.kind)
                    chart.stacked = device.kind == .cpu; chart.logical = state.profile.logicalCPU
                    if device.kind == .cpu {
                        if state.profile.logicalCPU { chart.coreIndex = i; chart.toolTip = "CPU \(i)" }
                        chart.onMode = { [weak self] logical in
                            guard let self else { return }; onFocus?(); state.profile.logicalCPU = logical
                            AppModel.shared.save(); refresh()
                        }
                    }
                    content.addSubview(chart); charts.append(chart)
                    let title = label(size: 12, secondary: true), scale = label(size: 12, secondary: true)
                    let time = label(size: 12, secondary: true), zero = label("0", size: 12, secondary: true)
                    scale.alignment = .right; zero.alignment = .right
                    [title, scale, time, zero].forEach(content.addSubview)
                    chartTitles.append(title); chartScales.append(scale); chartTimes.append(time); chartZeros.append(zero)
                }
            }
        }
        hostLabel.stringValue = state.profile.name
        editButton.title = tr("编辑", "Edit")
        titleLabel.stringValue = selected.map { $0.kind == .gpu ? "GPU" : deviceTitle($0) } ?? tr("性能", "Performance")
        modelLabel.stringValue = selected?.model ?? ""
        for row in rows {
            let d = row.device, m = state.latest?.devices[d.id]
            row.selected = d.id == selected?.id
            row.nameLabel.stringValue = deviceTitle(d)
            let percent = number(m?.value("usage"), "%", digits: 0)
            switch d.kind {
            case .cpu: row.subtitle.stringValue = percent + " " + number(m?.value("frequency").map { $0 / 1000 }, " GHz", digits: 2)
            case .memory: row.subtitle.stringValue = memoryPair(m?.value("used"), m?.value("total")) + " (\(percent))"
            case .disk: row.subtitle.stringValue = (d.metadata["type"] ?? "SSD (NVMe)") + "\n" + percent
            case .network:
                row.subtitle.stringValue = d.name + "\n" + tr("发送: ", "S: ") + bitRate(m?.value("send")) + " " + tr("接收: ", "R: ") + bitRate(m?.value("receive"))
            case .gpu: row.subtitle.stringValue = d.model + "\n" + percent + " (" + number(m?.value("temperature"), " °C", digits: 0) + ")"
            }
            let key = d.kind == .network ? "receive" : "usage"
            row.chart.points = series(state, device: d, key: key, second: d.kind == .network ? "send" : nil)
            row.chart.ceiling = d.kind == .network ? rateCeiling(row.chart.points, multiplier: 8) / 8 : 100
            row.chart.needsDisplay = true; row.needsDisplay = true
            row.setAccessibilityLabel(row.nameLabel.stringValue + ", " + row.subtitle.stringValue)
        }
        composition.isHidden = selected?.kind != .memory
        if let d = selected {
            let metric = state.latest?.devices[d.id]
            if d.kind == .memory, let total = metric?.value("total") {
                modelLabel.stringValue = bytes(total) + " LPDDR5X"
                composition.fraction = metric?.value("used").map { $0 / total }
            } else { composition.fraction = nil }
            composition.needsDisplay = true
            for (i, chart) in charts.enumerated() {
                var key = "usage", second: String? = d.kind == .cpu ? "system" : nil
                var caption = tr("利用率 %", "% Utilization")
                chart.unavailable = nil
                switch d.kind {
                case .cpu: caption = state.profile.logicalCPU ? tr("60 秒内的利用率 %", "% Utilization over 60 seconds") : tr("利用率 %", "% Utilization")
                case .memory: key = "used"; caption = tr("内存使用量", "Memory usage")
                case .disk: caption = i == 0 ? tr("活动时间", "Active time") : tr("磁盘传输速率", "Disk transfer rate"); if i == 1 { key = "read"; second = "write" }
                case .network: key = "receive"; second = "send"; caption = tr("吞吐量", "Throughput")
                case .gpu:
                    key = ["usage", "memoryActivity", "encoder", "decoder", "dedicatedUsed", "sharedUsed"][i]
                    caption = ["GPU", tr("内存活动", "Memory activity"), "Video Encode", "Video Decode", tr("专用 GPU 内存", "Dedicated GPU memory"), tr("共享 GPU 内存", "Shared GPU memory")][i]
                    if i >= 4 { chart.unavailable = tr("驱动未提供此指标", "Not reported by the driver") }
                }
                chart.points = series(state, device: d, key: key, second: second, core: chart.coreIndex)
                if d.kind == .memory { chart.ceiling = metric?.value("total") ?? Double(d.metadata["total"] ?? "") ?? 1 }
                else if d.kind == .network { chart.ceiling = rateCeiling(chart.points, multiplier: 8) / 8 }
                else if d.kind == .disk && i == 1 { chart.ceiling = rateCeiling(chart.points) }
                else { chart.ceiling = 100 }
                chartTitles[i].stringValue = caption
                chartScales[i].stringValue = d.kind == .memory ? bytes(chart.ceiling) : d.kind == .network ? bitRate(chart.ceiling) : d.kind == .disk && i == 1 ? bytes(chart.ceiling, perSecond: true) : d.kind == .gpu ? (i >= 4 ? "—" : number(metric?.value(key), "%", digits: 0)) : "100%"
                chartTimes[i].stringValue = tr("60 秒", "60 seconds")
                let current = chart.coreIndex.flatMap { c in metric?.cores?.first { ($0["index"] ?? nil) == Double(c) }?["usage"] ?? nil } ?? metric?.value(key)
                chart.setAccessibilityLabel((chart.coreIndex.map { "CPU \($0)" } ?? caption) + ", " + number(current))
                chart.needsDisplay = true
            }
        }
        if content.bounds.width > 0 { updateDetails(selected, top: statsTop, width: content.bounds.width) }
        needsLayout = true; needsDisplay = true
    }
    @objc func selectRow(_ row: HardwareRow) {
        onFocus?(); state.profile.selectedDevice = row.device.id
        AppModel.shared.save(); refresh()
    }
    func updateDetails(_ d: HardwareDevice?, top: CGFloat, width: CGFloat) {
        details.forEach { $0.0.removeFromSuperview() }; details.removeAll()
        guard let d else {
            let text = label(state.error ?? tr("连接机器后显示硬件指标。", "Connect a machine to view performance."), size: 14, secondary: true)
            text.maximumNumberOfLines = 5; text.lineBreakMode = .byWordWrapping
            content.addSubview(text); text.frame = NSRect(x: 0, y: 100, width: width, height: 130); details.append((text, text.frame)); return
        }
        let m = state.latest?.devices[d.id]
        func v(_ key: String) -> Double? { m?.value(key) }
        func add(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
            let field = label(text, size: size, secondary: secondary)
            let frame = NSRect(x: x, y: top + y, width: w, height: size + 8)
            field.frame = frame; content.addSubview(field); details.append((field, frame)); return field
        }
        func stat(_ title: String, _ value: String, x: CGFloat, y: CGFloat, w: CGFloat = 160) {
            _ = add(title, x: x, y: y, w: w, secondary: true)
            _ = add(value, x: x, y: y + 17, w: w, size: 24)
        }
        let zh = AppModel.shared.preferences.language == "zh"
        var facts: [(String, String)] = []; var factsX: CGFloat = 228; var keyWidth: CGFloat = zh ? 86 : 138
        switch d.kind {
        case .cpu:
            stat(tr("利用率", "Utilization"), number(v("usage"), "%", digits: 0), x: 0, y: 0, w: 68)
            stat(tr("速度", "Speed"), number(v("frequency").map { $0 / 1000 }, " GHz", digits: 2), x: 76, y: 0, w: 148)
            stat(tr("进程", "Processes"), number(v("processes"), digits: 0), x: 0, y: 56, w: 68)
            stat(tr("线程", "Threads"), number(v("threads"), digits: 0), x: 76, y: 56, w: 68)
            stat(tr("句柄", "Handles"), "—", x: 150, y: 56, w: 72)
            let uptime = state.latest.map { Int($0.uptime) }
            let duration = uptime.map { String(format: "%d:%02d:%02d:%02d", $0 / 86400, $0 / 3600 % 24, $0 / 60 % 60, $0 % 60) } ?? "—"
            stat(tr("正常运行时间", "Up time"), duration, x: 0, y: 112, w: 225)
            let user = add(tr("用户 ", "User ") + number(v("user"), "%"), x: 108, y: 166, w: 118, size: 13)
            let system = add(tr("系统 ", "System ") + number(v("system"), "%"), x: 0, y: 166, w: 108, size: 13)
            user.textColor = Style.color(.cpu); system.textColor = Style.color(.cpu).blended(withFraction: 0.3, of: .labelColor)
            facts = [(tr("基准速度", "Base speed"), "—"), (tr("插槽", "Sockets"), d.metadata["sockets"] ?? "—"),
                     (tr("内核", "Cores"), d.metadata["cores"] ?? "—"), (tr("逻辑处理器", "Logical processors"), d.metadata["cores"] ?? "—"),
                     (tr("虚拟化", "Virtualization"), "—")]
            for level in 1...3 { facts.append(("L\(level) " + tr("缓存", "cache"), bytes(d.metadata["cacheL\(level)"].flatMap(Double.init)))) }
            facts.append((tr("温度", "Temperature"), number(v("temperature"), " °C", digits: 0)))
        case .memory:
            stat(tr("使用中", "In use"), bytes(v("used")), x: 0, y: 0, w: 195)
            stat(tr("可用", "Available"), bytes(v("available")), x: 196, y: 0, w: 120)
            stat(tr("已提交", "Committed"), memoryPair(v("committed"), v("commitLimit")), x: 0, y: 56, w: 180)
            stat(tr("已缓存", "Cached"), bytes(v("cached")), x: 196, y: 56, w: 120)
            stat("Swap", bytes(v("swapUsed")), x: 0, y: 112, w: 135)
            stat(tr("Swap 总量", "Swap total"), bytes(v("swapTotal")), x: 136, y: 112, w: 155)
            factsX = 320; keyWidth = zh ? 126 : 153
            facts = [(tr("速度", "Speed"), "—"), (tr("已使用的插槽", "Slots used"), tr("不适用", "N/A")),
                     (tr("外形规格", "Form factor"), tr("板载", "Onboard")), (tr("为硬件保留的内存", "Hardware reserved"), "—")]
        case .disk:
            stat(tr("活动时间", "Active time"), number(v("usage"), "%", digits: 0), x: 0, y: 0, w: 76)
            stat(tr("平均响应时间", "Average response time"), number(v("latency"), tr(" 毫秒", " ms")), x: 78, y: 0, w: 194)
            stat(tr("读取速度", "Read speed"), bytes(v("read"), perSecond: true), x: 8, y: 56, w: 151)
            stat(tr("写入速度", "Write speed"), bytes(v("write"), perSecond: true), x: 167, y: 56, w: 150)
            factsX = 315; keyWidth = zh ? 86 : 116
            facts = [(tr("容量", "Capacity"), bytes(v("capacity"))), (tr("已格式化", "Formatted"), bytes(v("total"))),
                     (tr("系统磁盘", "System disk"), d.metadata["system"].map { $0 == "true" ? tr("是", "Yes") : tr("否", "No") } ?? "—"),
                     (tr("类型", "Type"), d.metadata["type"] ?? "SSD (NVMe)"), (tr("温度", "Temperature"), number(v("temperature"), " °C", digits: 0))]
        case .network:
            stat(tr("发送", "Send"), bitRate(v("send")), x: 8, y: 0, w: 136)
            stat(tr("接收", "Receive"), bitRate(v("receive")), x: 8, y: 56, w: 136)
            factsX = 130; keyWidth = zh ? 90 : 132
            facts = [(tr("适配器名称", "Adapter name"), deviceTitle(d)), ("SSID", d.metadata["ssid"] ?? "—"),
                     (tr("DNS 名称", "DNS name"), d.metadata["dns"] ?? "—"), (tr("连接类型", "Connection type"), d.metadata["type"] ?? "—"),
                     (tr("IPv4 地址", "IPv4 address"), d.metadata["ipv4"].flatMap { $0.isEmpty ? nil : $0 } ?? "—"),
                     (tr("IPv6 地址", "IPv6 address"), d.metadata["ipv6"].flatMap { $0.isEmpty ? nil : $0 } ?? "—"),
                     (tr("链路速度", "Link speed"), v("linkSpeed").map { bitRate($0 * 1_000_000 / 8) } ?? "—")]
            if d.metadata["rdma_ports"] != nil && d.metadata["rdma_ports"] != "[]" { facts.append((tr("RDMA 发送 / 接收", "RDMA sent / received"), bytes(v("rdmaSent")) + " / " + bytes(v("rdmaReceived")))) }
        case .gpu:
            stat(tr("利用率", "Utilization"), number(v("usage"), "%", digits: 0), x: 0, y: 0, w: 130)
            stat(tr("专用 GPU 内存", "Dedicated GPU memory"), "—", x: 145, y: 0, w: 165)
            stat(tr("GPU 内存", "GPU memory"), "—", x: 0, y: 56, w: 130)
            stat(tr("共享 GPU 内存", "Shared GPU memory"), "—", x: 145, y: 56, w: 165)
            stat(tr("温度", "Temperature"), number(v("temperature"), " °C", digits: 0), x: 145, y: 112, w: 130)
            stat(tr("功耗", "Power"), number(v("power"), " W"), x: 0, y: 112, w: 130)
            factsX = 314; keyWidth = zh ? 106 : 143
            facts = [(tr("驱动程序版本", "Driver version"), d.metadata["driver"] ?? "—"), (tr("驱动程序日期", "Driver date"), "—"),
                     (tr("内存架构", "Memory architecture"), tr("统一内存", "Unified memory")), (tr("频率", "Clock"), number(v("frequency"), " MHz", digits: 0))]
        }
        for (i, fact) in facts.enumerated() {
            let title = add(fact.0 + ":", x: factsX, y: CGFloat(i) * 21, w: keyWidth, secondary: true)
            let value = add(fact.1, x: factsX + keyWidth + 4, y: CGFloat(i) * 21, w: max(50, width - factsX - keyWidth - 4))
            title.toolTip = fact.0; value.toolTip = fact.1
            if d.kind == .cpu && i == facts.count - 1 { value.toolTip = (m?.sensors ?? [:]).sorted { $0.key < $1.key }.map { $0.key + ": " + number($0.value, " °C") }.joined(separator: "\n") }
        }
        if d.kind == .memory {
            let text = label(tr("内存组合", "Memory composition"), size: 12, secondary: true)
            text.frame = NSRect(x: 0, y: composition.frame.minY - 23, width: 190, height: 20)
            content.addSubview(text); details.append((text, text.frame))
        }
    }
    override func layout() {
        super.layout()
        guard bounds.width > sideWidth + 80 else { return }
        let offset: CGFloat = showsHost ? 26 : 0
        hostLabel.isHidden = !showsHost; hostLabel.frame = NSRect(x: 16, y: 3, width: bounds.width - 32, height: 22)
        sidebar.frame = NSRect(x: 4, y: offset + 8, width: sideWidth - 4, height: max(80, bounds.height - offset - 52))
        rowContainer.frame = NSRect(x: 0, y: 0, width: sidebar.contentSize.width, height: CGFloat(rows.count) * 72)
        for (i, row) in rows.enumerated() { row.frame = NSRect(x: 0, y: CGFloat(i) * 72, width: rowContainer.bounds.width, height: 70) }
        editButton.frame = NSRect(x: 10, y: bounds.height - 39, width: sideWidth - 20, height: 30)
        detailScroll.frame = NSRect(x: sideWidth + 30, y: offset, width: bounds.width - sideWidth - 56, height: bounds.height - offset)
        let w = detailScroll.contentSize.width
        let h = max(640, detailScroll.contentSize.height)
        content.frame = NSRect(x: 0, y: 0, width: w, height: h)
        titleLabel.frame = NSRect(x: 0, y: 12, width: w * 0.5, height: 44)
        modelLabel.frame = NSRect(x: w * 0.34, y: 26, width: w * 0.66, height: 26)
        let top: CGFloat = 76
        var frames: [NSRect] = []; var newStatsTop: CGFloat = 0
        let kind = selected?.kind
        switch kind {
        case .cpu:
            let height = h - 294
            if state.profile.logicalCPU {
                let rowCount = CGFloat((charts.count + 4) / 5), cellW = (w - 16) / 5
                let cellH = (height - (rowCount - 1) * 5) / max(1, rowCount)
                frames = charts.indices.map { NSRect(x: CGFloat($0 % 5) * (cellW + 4), y: top + CGFloat($0 / 5) * (cellH + 5), width: cellW, height: cellH) }
            } else { frames = [NSRect(x: 0, y: top, width: w, height: height)] }
            newStatsTop = top + height + 26
        case .memory:
            frames = [NSRect(x: 0, y: top, width: w, height: h - 382)]
            composition.frame = NSRect(x: 0, y: frames[0].maxY + 45, width: w, height: 58)
            newStatsTop = composition.frame.maxY + 28
        case .disk:
            frames = [NSRect(x: 0, y: top, width: w, height: h - 352)]
            frames.append(NSRect(x: 0, y: frames[0].maxY + 45, width: w, height: 75))
            newStatsTop = frames[1].maxY + 28
        case .network:
            frames = [NSRect(x: 0, y: top, width: w, height: h - 276)]
            newStatsTop = frames[0].maxY + 32
        case .gpu:
            let half = (w - 10) / 2
            let gpuTop = top + 8
            frames = (0..<4).map { NSRect(x: CGFloat($0 % 2) * (half + 10), y: gpuTop + CGFloat($0 / 2) * 116, width: half, height: 85) }
            frames += [NSRect(x: 0, y: gpuTop + 233, width: w, height: 75), NSRect(x: 0, y: gpuTop + 332, width: w, height: 75)]
            newStatsTop = gpuTop + 425
            content.frame.size.height = max(h, newStatsTop + 188)
        default: break
        }
        for (i, chart) in charts.enumerated() where i < frames.count {
            chart.frame = frames[i]
            let title = chartTitles[i], scale = chartScales[i], time = chartTimes[i], zero = chartZeros[i]
            let logical = kind == .cpu && state.profile.logicalCPU
            title.isHidden = logical && i != 0; scale.isHidden = logical && i != charts.count - 1
            if logical {
                title.frame = NSRect(x: 0, y: top - 22, width: w * 0.7, height: 19)
                scale.frame = NSRect(x: w * 0.7, y: top - 22, width: w * 0.3, height: 19)
            } else {
                title.frame = NSRect(x: chart.frame.minX, y: chart.frame.minY - 22, width: chart.frame.width * 0.75, height: 19)
                scale.frame = NSRect(x: chart.frame.minX + chart.frame.width * 0.75, y: chart.frame.minY - 22, width: chart.frame.width * 0.25, height: 19)
            }
            time.isHidden = logical || kind == .gpu; zero.isHidden = logical || kind == .gpu
            time.frame = NSRect(x: chart.frame.minX, y: chart.frame.maxY + 1, width: 100, height: 18)
            zero.frame = NSRect(x: chart.frame.maxX - 25, y: chart.frame.maxY + 1, width: 25, height: 18)
        }
        statsTop = newStatsTop
        let key = "\(w),\(h),\(viewKey)"
        if key != detailLayoutKey {
            detailLayoutKey = key
            updateDetails(selected, top: statsTop, width: w)
        }
    }
}

@MainActor final class MemoryCompositionView: FlippedView {
    var fraction: Double?
    override func draw(_ dirtyRect: NSRect) {
        Style.surface.setFill(); bounds.fill()
        if let fraction {
            Style.fill(.memory).setFill()
            NSRect(x: 0, y: 0, width: bounds.width * CGFloat(min(1, max(0, fraction))), height: bounds.height).fill()
            Style.color(.memory).setFill()
            NSRect(x: bounds.width * CGFloat(min(1, max(0, fraction))), y: 0, width: 1, height: bounds.height).fill()
        }
        Style.color(.memory).setStroke(); let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); path.lineWidth = 1; path.stroke()
    }
}

func memoryPair(_ used: Double?, _ total: Double?) -> String {
    guard let used, let total else { return "—" }
    return number(used / 1_073_741_824, digits: 1) + "/" + number(total / 1_073_741_824, " GiB", digits: 1)
}
func bitRate(_ bytes: Double?) -> String {
    guard let bytes else { return "—" }
    let bits = bytes * 8
    if bits >= 1_000_000_000 { return number(bits / 1_000_000_000, " Gbps") }
    if bits >= 1_000_000 { return number(bits / 1_000_000, " Mbps") }
    return number(bits / 1000, " Kbps")
}
func rateCeiling(_ points: [ChartPoint], multiplier: Double = 1) -> Double {
    let peak = max(1, (points.flatMap { [$0.total, $0.secondary].compactMap { $0 } }.max() ?? 1) * multiplier)
    let magnitude = pow(10, floor(log10(peak)))
    return ([1.0, 2, 5, 10].first { $0 * magnitude >= peak } ?? 10) * magnitude
}
