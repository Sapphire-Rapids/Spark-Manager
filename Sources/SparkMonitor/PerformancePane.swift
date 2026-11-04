import AppKit

@MainActor final class PerformancePane: FlippedView {
    let state: HostState
    let titleLabel = label(size: 32)
    let modelLabel = label(size: 18)
    let hostLabel = label(size: 14)
    let sidebar = NSScrollView()
    let rowContainer = HardwareListView()
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
    var engineMenus: [NSPopUpButton] = []
    var details: [(NSTextField, NSRect)] = []
    var editingHardware = false
    var displayedDeviceID: String?
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
        rowContainer.onMove = { [weak self] id, index in
            guard let self else { return }
            state.moveDevice(id, to: index); AppModel.shared.save(); refresh()
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func edit() {
        editingHardware.toggle(); onFocus?(); refresh()
    }
    override func mouseDown(with event: NSEvent) { onFocus?() }
    override func draw(_ dirtyRect: NSRect) { Style.surface.setFill(); bounds.fill() }
    var localMac: Bool { state.profile.isLocal }
    var windows: Bool { state.inventory?.platform == "windows" }
    var engineKeys: [String] {
        let reported = (selected?.metadata.keys.filter { $0.hasPrefix("engine:") } ?? []).sorted { (Int($0.dropFirst(7)) ?? 0) < (Int($1.dropFirst(7)) ?? 0) }
        return !reported.isEmpty ? reported : ["usage", "memoryActivity", "encoder", "decoder"]
    }
    var gpuActivityCount: Int { localMac ? min(4, engineKeys.count) : 4 }
    func engineTitle(_ key: String) -> String {
        if let title = selected?.metadata[key] { return title }
        return ["usage": tr("总体利用率", "GPU utilization"), "memoryActivity": tr("内存读写活动", "Memory activity"), "encoder": "Video Encode", "decoder": "Video Decode"][key] ?? "—"
    }
    var gpuMemoryFields: [String] {
        guard let device = selected, device.kind == .gpu else { return [] }
        if localMac { return ["allocated"] }
        if !windows { return [] }
        let dedicated = state.latest?.devices[device.id]?.value("dedicatedTotal")
            ?? Double(device.metadata["dedicatedTotal"] ?? "")
            ?? state.history.reversed().lazy.compactMap { $0.snapshot?.devices[device.id]?.value("dedicatedTotal") }.first
        return (dedicated.map { $0 > 0 } == true ? ["dedicated"] : []) + ["shared"]
    }
    var selectedEngines: [String] {
        let saved = selected.flatMap { state.profile.gpuGraphs?[$0.id] } ?? []
        return (0..<gpuActivityCount).map { i in i < saved.count && engineKeys.contains(saved[i]) ? saved[i] : (i < engineKeys.count ? engineKeys[i] : "") }
    }
    @objc func chooseEngine(_ menu: NSPopUpButton) {
        guard let id = selected?.id, let key = menu.selectedItem?.representedObject as? String else { return }
        var choices = selectedEngines; choices[menu.tag] = key
        if state.profile.gpuGraphs == nil { state.profile.gpuGraphs = [:] }
        state.profile.gpuGraphs?[id] = choices
        AppModel.shared.save(); refresh()
    }
    var selected: HardwareDevice? { state.visibleDevices.first { $0.id == state.profile.selectedDevice } ?? state.visibleDevices.first }
    func refresh() {
        let devices = editingHardware ? state.editableDevices : state.visibleDevices
        let key = [devices.map(\.id).joined(separator: "|"), selected?.id ?? "", String(state.profile.logicalCPU),
                   String(editingHardware), AppModel.shared.preferences.language, engineKeys.joined(),
                   String(windows), gpuMemoryFields.joined()].joined(separator: ";")
        if key != viewKey {
            viewKey = key
            rows.forEach { $0.removeFromSuperview() }; rows.removeAll()
            for device in devices {
                let row = HardwareRow(device: device); row.target = self; row.action = #selector(selectRow(_:))
                row.onToggle = { [weak self] checked in
                    guard let self else { return }
                    state.setVisible(checked, device: device); AppModel.shared.save(); refresh()
                }
                rowContainer.addSubview(row); rows.append(row)
            }
            charts.forEach { $0.removeFromSuperview() }; charts.removeAll()
            engineMenus.forEach { $0.removeFromSuperview() }; engineMenus.removeAll()
            (chartTitles + chartScales + chartTimes + chartZeros).forEach { $0.removeFromSuperview() }
            chartTitles = []; chartScales = []; chartTimes = []; chartZeros = []
            if let device = selected {
                let cores = Int(device.metadata["logicalProcessors"] ?? device.metadata["cores"] ?? "20") ?? 20
                let count = device.kind == .cpu && state.profile.logicalCPU ? cores : device.kind == .disk ? 2 : device.kind == .gpu ? gpuActivityCount + gpuMemoryFields.count : 1
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
                    if device.kind == .gpu && i < gpuActivityCount {
                        let menu = NSPopUpButton(); menu.isBordered = false; menu.font = .systemFont(ofSize: 12)
                        menu.target = self; menu.action = #selector(chooseEngine(_:)); menu.tag = i
                        for key in engineKeys {
                            menu.addItem(withTitle: engineTitle(key)); menu.lastItem?.representedObject = key
                        }
                        menu.setAccessibilityLabel(tr("GPU 图表", "GPU chart") + " \(i + 1)")
                        content.addSubview(menu); engineMenus.append(menu)
                    }
                }
            }
        }
        if displayedDeviceID != selected?.id {
            displayedDeviceID = selected?.id
            detailScroll.contentView.scroll(to: .zero)
        }
        rowContainer.editing = editingHardware; rowContainer.rowCount = rows.count
        hostLabel.stringValue = state.profile.displayName
        editButton.title = editingHardware ? tr("完成", "Done") : tr("编辑", "Edit")
        titleLabel.stringValue = selected.map(deviceTitle) ?? tr("性能", "Performance")
        modelLabel.stringValue = selected?.model ?? ""
        for (index, row) in rows.enumerated() {
            row.device = devices[index]
            row.editing = editingHardware; row.visible = state.isVisible(row.device); row.needsLayout = true
            let d = row.device, m = state.latest?.devices[d.id]
            row.selected = d.id == selected?.id
            row.nameLabel.stringValue = deviceTitle(d)
            let percent = number(m?.value("usage"), "%", digits: 0)
            switch d.kind {
            case .cpu: row.subtitle.stringValue = percent + " " + number(m?.value("frequency").map { $0 / 1000 }, " GHz", digits: 2)
            case .memory: row.subtitle.stringValue = memoryPair(m?.value("used"), m?.value("total")) + " (\(percent))"
            case .disk:
                let detail = localMac ? tr("读 ", "R ") + bytes(m?.value("read"), perSecond: true) + "\n" + tr("写 ", "W ") + bytes(m?.value("write"), perSecond: true) : (d.metadata["type"] ?? "SSD (NVMe)") + "\n" + percent
                row.subtitle.stringValue = detail
            case .network:
                row.subtitle.stringValue = d.name + "\n" + tr("发送: ", "S: ") + bitRate(m?.value("send")) + " " + tr("接收: ", "R: ") + bitRate(m?.value("receive"))
            case .gpu: row.subtitle.stringValue = d.model + "\n" + percent + (m?.value("temperature").map { " (" + number($0, " °C", digits: 0) + ")" } ?? "")
            }
            let key = d.kind == .network ? "receive" : (localMac && d.kind == .disk ? "read" : "usage")
            row.chart.points = series(state, device: d, key: key, second: d.kind == .network ? "send" : (localMac && d.kind == .disk ? "write" : nil))
            row.chart.ceiling = d.kind == .network ? rateCeiling(row.chart.points, multiplier: 8) / 8 : (localMac && d.kind == .disk ? rateCeiling(row.chart.points) : 100)
            row.chart.needsDisplay = true; row.needsDisplay = true
            row.setAccessibilityLabel(row.nameLabel.stringValue + ", " + row.subtitle.stringValue)
        }
        composition.isHidden = selected?.kind != .memory
        if let d = selected {
            let metric = state.latest?.devices[d.id]
            if d.kind == .memory, let total = metric?.value("total") {
                let installed = windows ? Double(d.metadata["installed"] ?? "") ?? total : total
                modelLabel.stringValue = bytes(installed)
                composition.fraction = metric?.value("used").map { $0 / total }
                composition.modified = windows ? metric?.value("modified").map { $0 / total } : nil
                composition.standby = windows ? metric?.value("standby").map { $0 / total } : nil
                composition.toolTip = windows ? tr("使用中 / 已修改 / 备用 / 空闲", "In use / Modified / Standby / Free") : nil
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
                    if i < gpuActivityCount {
                        key = selectedEngines[i]; caption = engineTitle(key)
                        let index = engineKeys.firstIndex(of: key) ?? -1
                        if engineMenus[i].indexOfSelectedItem != index { engineMenus[i].selectItem(at: index) }
                    } else {
                        let field = gpuMemoryFields[i - gpuActivityCount]
                        key = field == "allocated" ? field : field + "Used"
                        caption = field == "allocated" ? tr("GPU 驱动内存", "GPU driver memory") : (field == "dedicated" ? tr("专用 GPU 内存使用量", "Dedicated GPU memory usage") : tr("共享 GPU 内存使用量", "Shared GPU memory usage"))
                    }
                }
                if localMac && d.kind == .disk && i == 0 { key = "operations"; caption = tr("磁盘活动（IOPS）", "Disk activity (IOPS)") }
                let chartMetric = state.latest?.devices[d.id]
                chart.points = series(state, device: d, key: key, second: second, core: chart.coreIndex)
                let memoryChart = d.kind == .memory || (d.kind == .gpu && i >= gpuActivityCount)
                chart.toolTip = chart.coreIndex.map { "CPU \($0)" }
                if d.kind == .network {
                    chart.toolTip = tr("实线：接收；虚线：发送。", "Solid: receive; dashed: send.")
                }
                var capacity: Double?
                if memoryChart {
                    if key == "allocated" {
                        // The axis is a range for the observed allocation, not a claimed GPU memory limit.
                        let peak = max(1_048_576, chart.points.compactMap(\.total).max() ?? 0)
                        capacity = pow(2, ceil(log2(peak)))
                    } else {
                        let capacityKey = d.kind == .gpu ? gpuMemoryFields[i - gpuActivityCount] + "Total" : "total"
                        capacity = chartMetric?.value(capacityKey) ?? Double(d.metadata[capacityKey] ?? "")
                            ?? state.history.reversed().lazy.compactMap { $0.snapshot?.devices[d.id]?.value(capacityKey) }.first
                    }
                    chart.ceiling = capacity ?? 1
                    if capacity == nil { chart.points = []; chart.unavailable = "—" }
                }
                else if d.kind == .network { chart.ceiling = rateCeiling(chart.points, multiplier: 8) / 8 }
                else if d.kind == .disk && (i == 1 || localMac) { chart.ceiling = rateCeiling(chart.points) }
                else { chart.ceiling = 100 }
                chartTitles[i].stringValue = caption
                chartScales[i].stringValue = memoryChart ? bytes(capacity) : d.kind == .network ? bitRate(chart.ceiling) : d.kind == .disk && i == 1 ? bytes(chart.ceiling, perSecond: true) : d.kind == .gpu ? number(chartMetric?.value(key), "%", digits: 0) : "100%"
                if localMac && d.kind == .disk && i == 0 { chartScales[i].stringValue = number(chart.ceiling, " IOPS", digits: 0) }
                chartTimes[i].stringValue = tr("60 秒", "60 seconds")
                let current = chart.coreIndex.flatMap { c in chartMetric?.cores?.first { ($0["index"] ?? nil) == Double(c) }?["usage"] ?? nil } ?? chartMetric?.value(key)
                chart.setAccessibilityLabel((chart.coreIndex.map { "CPU \($0)" } ?? caption) + ", " + number(current))
                chart.needsDisplay = true
            }
        }
        if content.bounds.width > 0 { updateDetails(selected, top: statsTop, width: content.bounds.width) }
        needsLayout = true; needsDisplay = true
    }
    @objc func selectRow(_ row: HardwareRow) {
        guard !editingHardware else { return }
        onFocus?(); state.profile.selectedDevice = row.device.id
        AppModel.shared.save(); refresh()
    }
    func updateDetails(_ d: HardwareDevice?, top: CGFloat, width: CGFloat) {
        var cursor = 0
        defer {
            while details.count > cursor { details.removeLast().0.removeFromSuperview() }
        }
        func add(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
            let field: NSTextField
            if cursor < details.count { field = details[cursor].0 }
            else { field = label(); content.addSubview(field); details.append((field, .zero)) }
            let frame = NSRect(x: x, y: top + y, width: w, height: size + 8)
            field.stringValue = text; field.font = .systemFont(ofSize: size)
            field.textColor = secondary ? .secondaryLabelColor : .labelColor
            field.toolTip = nil; field.maximumNumberOfLines = 1
            field.frame = frame; details[cursor].1 = frame; cursor += 1
            return field
        }
        @discardableResult func stat(_ title: String, _ value: String, x: CGFloat, y: CGFloat, w: CGFloat = 160) -> NSTextField {
            _ = add(title, x: x, y: y, w: w, secondary: true)
            return add(value, x: x, y: y + 17, w: w, size: 24)
        }
        guard let d else {
            let text = add(state.error ?? tr("连接机器后显示硬件指标。", "Connect a machine to view performance."), x: 0, y: 100, w: width, size: 14, secondary: true)
            text.maximumNumberOfLines = 5; text.lineBreakMode = .byWordWrapping; text.frame.size.height = 130
            return
        }
        let m = state.latest?.devices[d.id]
        func v(_ key: String) -> Double? { m?.value(key) }
        func meta(_ key: String) -> String { d.metadata[key].flatMap { $0.isEmpty ? nil : $0 } ?? "—" }
        let zh = AppModel.shared.preferences.language == "zh"
        var facts: [(String, String)] = []; var factsX: CGFloat = 228; var keyWidth: CGFloat = zh ? 86 : 138
        switch d.kind {
        case .cpu:
            stat(tr("利用率", "Utilization"), number(v("usage"), "%", digits: 0), x: 0, y: 0, w: 68)
            stat(localMac ? tr("性能核速度", "P-core speed") : tr("速度", "Speed"), number(v("frequency").map { $0 / 1000 }, " GHz", digits: 2), x: 76, y: 0, w: 148)
            stat(tr("进程", "Processes"), number(v("processes"), digits: 0), x: 0, y: 56, w: 68)
            stat(tr("线程", "Threads"), number(v("threads"), digits: 0), x: 76, y: 56, w: 68)
            if localMac { stat(tr("能效核速度", "E-core speed"), number(v("efficiencyFrequency").map { $0 / 1000 }, " GHz", digits: 2), x: 150, y: 56, w: 103) }
            else { stat(windows ? tr("句柄", "Handles") : tr("负载 (1m)", "Load (1m)"), number(v(windows ? "handles" : "load"), digits: windows ? 0 : 1), x: 150, y: 56, w: 103) }
            let uptime = state.latest.map { Int($0.uptime) }
            let duration = uptime.map { String(format: "%d:%02d:%02d:%02d", $0 / 86400, $0 / 3600 % 24, $0 / 60 % 60, $0 % 60) } ?? "—"
            stat(tr("正常运行时间", "Up time"), duration, x: 0, y: 112, w: 225)
            factsX = 260
            let virtualization = d.metadata["virtualization"].map { $0.lowercased() == "true" ? tr("已启用", "Enabled") : tr("已禁用", "Disabled") } ?? "—"
            let frequencyKey = d.metadata["baseFrequency"] != nil ? "baseFrequency" : "maxFrequency"
            facts = [(frequencyKey == "baseFrequency" ? tr("基准速度", "Base speed") : tr("最高频率", "Maximum clock"), number(d.metadata[frequencyKey].flatMap(Double.init).map { $0 / 1000 }, " GHz", digits: 2)),
                     (tr("插槽", "Sockets"), meta("sockets")), (tr("内核", "Cores"), meta("cores")),
                     (tr("逻辑处理器", "Logical processors"), d.metadata["logicalProcessors"] ?? meta("cores")),
                     (d.metadata["virtualization"] != nil ? tr("虚拟化", "Virtualization") : tr("架构", "Architecture"), d.metadata["virtualization"] != nil ? virtualization : meta("architecture"))]
            for level in 1...3 where d.metadata["cacheL\(level)"] != nil {
                facts.append(("L\(level) " + tr("缓存", "cache"), bytes(d.metadata["cacheL\(level)"].flatMap(Double.init))))
            }
        case .memory:
            let compressed = v("compressed")
            stat(compressed == nil ? tr("使用中", "In use") : tr("使用中（已压缩）", "In use (Compressed)"), bytes(v("used")) + (compressed.map { " (" + bytes($0) + ")" } ?? ""), x: 0, y: 0, w: 195)
            stat(tr("可用", "Available"), bytes(v("available")), x: 196, y: 0, w: 120)
            stat(localMac ? tr("App 内存", "App memory") : tr("已提交", "Committed"), localMac ? bytes(v("app")) : memoryPair(v("committed"), v("commitLimit")), x: 0, y: 56, w: 180)
            stat(tr("已缓存", "Cached"), bytes(v("cached")), x: 196, y: 56, w: 120)
            stat(windows ? tr("分页池", "Paged pool") : (localMac ? tr("联动内存", "Wired memory") : tr("已用 Swap", "Swap used")), bytes(v(windows ? "paged" : (localMac ? "wired" : "swapUsed"))), x: 0, y: 112, w: 180)
            stat(windows ? tr("非分页池", "Non-paged pool") : (localMac ? tr("已用 Swap", "Swap used") : tr("Swap 总量", "Swap total")), bytes(v(windows ? "nonpaged" : (localMac ? "swapUsed" : "swapTotal"))), x: 196, y: 112, w: 120)
            factsX = 320; keyWidth = zh ? 126 : 153
            facts = [(tr("速度", "Speed"), d.metadata["speed"].map { $0 + " MT/s" } ?? "—"), (tr("已使用的插槽", "Slots used"), meta("slots")),
                     (tr("外形规格", "Form factor"), meta("form") == "Other" ? tr("其他", "Other") : meta("form")),
                     (tr("为硬件保留的内存", "Hardware reserved"), bytes(v("reserved")))]
            if localMac {
                facts = [(tr("内存架构", "Memory model"), tr("统一内存", "Unified memory")),
                         (tr("可清除内存", "Purgeable"), bytes(v("purgeable"))), (tr("Swap 总量", "Swap total"), bytes(v("swapTotal")))]
            } else if !windows {
                facts = [(tr("类型", "Type"), d.model), (tr("内核缓存", "Kernel slab"), bytes(v("slab"))),
                         (tr("可回收内核缓存", "Reclaimable slab"), bytes(v("reclaimable"))), (tr("共享页", "Shared pages"), bytes(v("shared"))), (tr("待写回", "Dirty pages"), bytes(v("dirty")))]
            }
        case .disk:
            stat(localMac ? tr("每秒操作数", "IOPS") : tr("活动时间", "Active time"), localMac ? number(v("operations"), digits: 0) : number(v("usage"), "%", digits: 0), x: 0, y: 0, w: localMac ? 112 : 76)
            stat(tr("平均响应时间", "Average response time"), number(v("latency"), tr(" 毫秒", " ms")), x: localMac ? 120 : 78, y: 0, w: 194)
            stat(tr("读取速度", "Read speed"), bytes(v("read"), perSecond: true), x: 8, y: 56, w: 151)
            stat(tr("写入速度", "Write speed"), bytes(v("write"), perSecond: true), x: 167, y: 56, w: 150)
            factsX = 315; keyWidth = zh ? 86 : 116
            facts = [(tr("容量", "Capacity"), bytes(v("capacity"))), (tr("已格式化", "Formatted"), bytes(v("total"))),
                     (tr("系统磁盘", "System disk"), d.metadata["system"].map { $0 == "true" ? tr("是", "Yes") : tr("否", "No") } ?? "—"),
                     (tr("页面文件", "Page file"), d.metadata["pagefile"].map { $0 == "true" ? tr("是", "Yes") : tr("否", "No") } ?? "—"), (tr("类型", "Type"), meta("type"))]
            if !windows { facts.removeAll { $0.0 == tr("页面文件", "Page file") }; facts.append((tr("可用空间", "Available space"), bytes(v("free")))) }
        case .network:
            stat(tr("发送", "Send"), bitRate(v("send")), x: 8, y: 0, w: 136)
            stat(tr("接收", "Receive"), bitRate(v("receive")), x: 8, y: 56, w: 136)
            factsX = 168; keyWidth = zh ? 104 : 132
            let wifi = d.metadata["type"] == "Wi-Fi"
            facts = [(tr("适配器名称", "Adapter name"), d.name)]
            if wifi { facts.append(("SSID", state.live ? meta("ssid") : "—")) }
            facts += [(tr("DNS 名称", "DNS name"), meta("domain")), (tr("连接类型", "Connection type"), wifi ? meta("protocol") : meta("type")),
                      (tr("IPv4 地址", "IPv4 address"), meta("ipv4")), (tr("IPv6 地址", "IPv6 address"), meta("ipv6"))]
            if wifi { facts.append((tr("信号强度", "Signal strength"), number(v("signal"), d.metadata["signalUnit"] == "%" ? "%" : " dBm", digits: 0))) }
        case .gpu:
            let dedicated = gpuMemoryFields.contains("dedicated")
            stat(tr("利用率", "Utilization"), number(v("usage"), "%", digits: 0), x: 0, y: 0, w: 135)
            if dedicated {
                stat(tr("专用 GPU 内存", "Dedicated GPU memory"), memoryPair(v("dedicatedUsed"), v("dedicatedTotal")), x: 160, y: 0, w: 195)
                let used = v("dedicatedUsed").flatMap { a in v("sharedUsed").map { a + $0 } }
                let total = v("dedicatedTotal").flatMap { a in v("sharedTotal").map { a + $0 } }
                stat(tr("GPU 内存", "GPU memory"), memoryPair(used, total), x: 0, y: 56, w: 158)
            }
            if localMac { stat(tr("GPU 驱动内存", "GPU driver memory"), bytes(v("allocated")), x: 160, y: 0, w: 195) }
            else if gpuMemoryFields.contains("shared") { stat(tr("共享 GPU 内存", "Shared GPU memory"), memoryPair(v("sharedUsed"), v("sharedTotal")), x: 160, y: dedicated ? 56 : 0, w: 195) }
            if let temperature = v("temperature") { stat(tr("GPU 温度", "GPU temperature"), number(temperature, " °C", digits: 0), x: 0, y: dedicated ? 112 : 56, w: 155) }
            factsX = 363; keyWidth = zh ? 103 : 110
            facts = [(tr("驱动版本", "Driver version"), localMac ? "—" : meta("driver")), (tr("驱动日期", "Driver date"), meta("driverDate")),
                     (tr("DirectX 版本", "DirectX version"), meta("directX")), (tr("物理位置", "Physical location"), meta("pci"))]
            if localMac { facts = [(tr("GPU 核心", "GPU cores"), meta("cores")), (tr("内存架构", "Memory model"), tr("CPU / GPU 共享", "CPU / GPU shared")), (tr("驱动", "Driver"), meta("driver"))] }
        }
        facts.removeAll { $0.1 == "—" || $0.1.isEmpty }
        for (i, fact) in facts.enumerated() {
            let title = add(fact.0 + ":", x: factsX, y: CGFloat(i) * 21, w: keyWidth, secondary: true)
            let value = add(fact.1, x: factsX + keyWidth + 4, y: CGFloat(i) * 21, w: max(50, width - factsX - keyWidth - 4))
            title.toolTip = fact.0; value.toolTip = fact.1
            if d.kind == .network, fact.0 == tr("信号强度", "Signal strength"), let signal = v("signal") {
                // Windows WLAN quality maps -100...-50 dBm linearly to 0...100.
                let quality = d.metadata["signalUnit"] == "%" ? signal : 2 * (signal + 100)
                let bars = NSMutableAttributedString(string: "▂▄▆█", attributes: [.foregroundColor: NSColor.tertiaryLabelColor])
                let count = Int(ceil(max(0, min(100, quality)) / 25))
                bars.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: count))
                value.attributedStringValue = bars
                value.setAccessibilityLabel(fact.0 + ", " + fact.1)
            }
        }
        if d.kind == .memory {
            _ = add(tr("内存组合", "Memory composition"), x: 0, y: composition.frame.minY - 23 - top, w: 190, size: 12, secondary: true)
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
        titleLabel.frame = NSRect(x: 0, y: 12, width: w * 0.5, height: 44)
        modelLabel.frame = NSRect(x: w * 0.34, y: 26, width: w * 0.66, height: 26)
        let top: CGFloat = 76
        var frames: [NSRect] = []; var newStatsTop: CGFloat = 0
        let kind = selected?.kind
        switch kind {
        case .cpu:
            let height = h - 270
            if state.profile.logicalCPU {
                let columns = charts.count == 20 ? 5 : (charts.count > 16 ? 8 : 4)
                let rowCount = CGFloat((charts.count + columns - 1) / columns), cellW = (w - CGFloat(columns - 1) * 4) / CGFloat(columns)
                let cellH = (height - (rowCount - 1) * 5) / max(1, rowCount)
                frames = charts.indices.map { NSRect(x: CGFloat($0 % columns) * (cellW + 4), y: top + CGFloat($0 / columns) * (cellH + 5), width: cellW, height: cellH) }
            } else { frames = [NSRect(x: 0, y: top, width: w, height: height)] }
            newStatsTop = top + height + 26
        case .memory:
            frames = [NSRect(x: 0, y: top, width: w, height: h - 382)]
            composition.frame = NSRect(x: 0, y: frames[0].maxY + 45, width: w, height: 58)
            newStatsTop = composition.frame.maxY + 28
        case .disk:
            frames = [NSRect(x: 0, y: top, width: w, height: h - 398)]
            frames.append(NSRect(x: 0, y: frames[0].maxY + 45, width: w, height: 75))
            newStatsTop = frames[1].maxY + 28
        case .network:
            frames = [NSRect(x: 0, y: top, width: w, height: h - 376)]
            newStatsTop = frames[0].maxY + 32
        case .gpu:
            let half = (w - 10) / 2
            let gpuTop = top + 8
            let graphHeight = (h - (gpuMemoryFields.count == 2 ? 372 : 340)) / CGFloat(2 + gpuMemoryFields.count)
            frames = (0..<gpuActivityCount).map { NSRect(x: CGFloat($0 % 2) * (half + 10), y: gpuTop + CGFloat($0 / 2) * (graphHeight + 32), width: half, height: graphHeight) }
            for index in gpuMemoryFields.indices {
                frames.append(NSRect(x: 0, y: gpuTop + CGFloat(2 + index) * (graphHeight + 32), width: w, height: graphHeight))
            }
            newStatsTop = frames.last!.maxY + 28
        default: break
        }
        let finalFrame = NSRect(x: 0, y: 0, width: w, height: h)
        if content.frame != finalFrame { content.frame = finalFrame }
        for (i, chart) in charts.enumerated() where i < frames.count {
            chart.frame = frames[i]
            let title = chartTitles[i], scale = chartScales[i], time = chartTimes[i], zero = chartZeros[i]
            let logical = kind == .cpu && state.profile.logicalCPU
            title.isHidden = (logical && i != 0) || (kind == .gpu && i < gpuActivityCount); scale.isHidden = logical && i != charts.count - 1
            if logical {
                title.frame = NSRect(x: 0, y: top - 22, width: w * 0.7, height: 19)
                scale.frame = NSRect(x: w * 0.7, y: top - 22, width: w * 0.3, height: 19)
            } else {
                title.frame = NSRect(x: chart.frame.minX, y: chart.frame.minY - 22, width: chart.frame.width * 0.75, height: 19)
                scale.frame = NSRect(x: chart.frame.minX + chart.frame.width * 0.75, y: chart.frame.minY - 22, width: chart.frame.width * 0.25, height: 19)
            }
            if i < engineMenus.count {
                let menu = engineMenus[i]
                let titleWidth = ((menu.titleOfSelectedItem ?? "") as NSString).size(withAttributes: [.font: menu.font ?? NSFont.systemFont(ofSize: 12)]).width
                menu.frame = NSRect(x: chart.frame.minX - 4, y: chart.frame.minY - 25, width: min(chart.frame.width * 0.7, ceil(titleWidth) + 28), height: 23)
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
    var modified: Double?
    var standby: Double?
    override func draw(_ dirtyRect: NSRect) {
        Style.surface.setFill(); bounds.fill()
        if let fraction {
            Style.fill(.memory).setFill()
            NSRect(x: 0, y: 0, width: bounds.width * CGFloat(min(1, max(0, fraction))), height: bounds.height).fill()
            Style.color(.memory).setFill()
            NSRect(x: bounds.width * CGFloat(min(1, max(0, fraction))), y: 0, width: 1, height: bounds.height).fill()
        }
        if let fraction, let modified, let standby {
            let start = bounds.width * CGFloat(fraction)
            Style.color(.memory).withAlphaComponent(0.55).setFill()
            NSRect(x: start, y: 0, width: bounds.width * CGFloat(modified), height: bounds.height).fill()
            for f in [fraction + modified, fraction + modified + standby] {
                Style.color(.memory).setFill(); NSRect(x: bounds.width * CGFloat(min(1, f)), y: 0, width: 1, height: bounds.height).fill()
            }
        }
        Style.color(.memory).setStroke(); let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); path.lineWidth = 1; path.stroke()
    }
}

func memoryPair(_ used: Double?, _ total: Double?) -> String {
    guard let used, let total else { return "—" }
    let small = total < 1_073_741_824
    let divisor: Double = small ? 1_048_576 : 1_073_741_824
    return number(used / divisor, digits: small ? 0 : 1) + "/" + number(total / divisor, small ? " MB" : " GB", digits: small ? 0 : 1)
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
