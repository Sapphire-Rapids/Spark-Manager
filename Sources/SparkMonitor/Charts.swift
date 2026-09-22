import AppKit

@MainActor enum Style {
    static var dark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    static var surface: NSColor { dark ? NSColor(white: 0.13, alpha: 1) : .white }
    static var sidebar: NSColor { dark ? NSColor(white: 0.16, alpha: 1) : NSColor(srgbRed: 0.947, green: 0.954, blue: 0.960, alpha: 1) }
    static var grid: NSColor { dark ? NSColor(white: 0.20, alpha: 1) : NSColor(white: 0.947, alpha: 1) }
    static var selected: NSColor { dark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.962, alpha: 1) }
    static var border: NSColor { dark ? NSColor(white: 0.38, alpha: 1) : NSColor(white: 0.74, alpha: 1) }
    static func fill(_ kind: HardwareKind) -> NSColor {
        if dark { return color(kind).withAlphaComponent(0.25) }
        switch kind {
        case .cpu: return NSColor(srgbRed: 0.73, green: 0.88, blue: 0.94, alpha: 1)
        case .memory: return NSColor(srgbRed: 0.78, green: 0.87, blue: 0.99, alpha: 1)
        case .disk: return NSColor(srgbRed: 0.82, green: 0.92, blue: 0.67, alpha: 1)
        case .network: return NSColor(srgbRed: 0.95, green: 0.79, blue: 0.85, alpha: 1)
        case .gpu: return NSColor(srgbRed: 0.86, green: 0.76, blue: 0.98, alpha: 1)
        }
    }
    static func color(_ kind: HardwareKind) -> NSColor {
        switch kind {
        case .cpu: return NSColor(srgbRed: 0.48, green: 0.64, blue: 0.70, alpha: 1)
        case .memory: return NSColor(srgbRed: 0.38, green: 0.59, blue: 0.85, alpha: 1)
        case .disk: return NSColor(srgbRed: 0.61, green: 0.72, blue: 0.45, alpha: 1)
        case .network: return NSColor(srgbRed: 0.77, green: 0.53, blue: 0.62, alpha: 1)
        case .gpu: return NSColor(srgbRed: 0.67, green: 0.48, blue: 0.86, alpha: 1)
        }
    }
}

@MainActor class FlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor func label(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
    let v = NSTextField(labelWithString: text)
    v.font = .systemFont(ofSize: size, weight: weight)
    v.textColor = secondary ? .secondaryLabelColor : .labelColor
    v.lineBreakMode = .byTruncatingTail
    return v
}

struct ChartPoint {
    var time: Date
    var total: Double?
    var secondary: Double?
}

@MainActor final class ChartView: FlippedView {
    var points: [ChartPoint] = []
    var color = Style.color(.cpu)
    var kind: HardwareKind = .cpu
    var ceiling: Double = 100
    var stacked = false
    var compact = false
    var coreIndex: Int?
    var onMode: ((Bool) -> Void)?
    var logical = false
    var unavailable: String?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard onMode != nil else { return nil }
        let m = NSMenu(title: tr("图形更改为", "Change graph to"))
        for (name, mode) in [(tr("总体利用率", "Overall utilization"), false), (tr("逻辑处理器", "Logical processors"), true)] {
            let item = NSMenuItem(title: name, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self; item.tag = mode ? 1 : 0; item.state = logical == mode ? .on : .off
            m.addItem(item)
        }
        return m
    }
    @objc private func selectMode(_ item: NSMenuItem) { onMode?(item.tag == 1) }
    override func draw(_ dirtyRect: NSRect) {
        Style.surface.setFill(); bounds.fill()
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let grid = NSBezierPath(); grid.lineWidth = 0.5
        if !compact {
            let columns = coreIndex == nil ? max(10, Int(rect.width / 30)) : 10
            for i in 1..<columns {
                let x = rect.minX + rect.width * CGFloat(i) / CGFloat(columns)
                grid.move(to: NSPoint(x: x, y: rect.minY)); grid.line(to: NSPoint(x: x, y: rect.maxY))
            }
            for i in 1..<10 {
                let y = rect.minY + rect.height * CGFloat(i) / 10
                grid.move(to: NSPoint(x: rect.minX, y: y)); grid.line(to: NSPoint(x: rect.maxX, y: y))
            }
            Style.grid.setStroke(); grid.stroke()
        }
        // Advance the graph only when a sample arrives. Redraws and resizing must
        // not move the newest point away from the right border.
        let end = points.last?.time ?? Date()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        func render(secondary: Bool, fill: Bool, alpha: CGFloat, dash: Bool = false) {
            var run: [NSPoint] = []; var lastDate: Date?
            func finish() {
                guard !run.isEmpty else { return }
                let line = NSBezierPath(); line.move(to: run[0]); run.dropFirst().forEach { line.line(to: $0) }
                if fill {
                    let area = line.copy() as! NSBezierPath
                    area.line(to: NSPoint(x: run.last!.x, y: rect.maxY))
                    area.line(to: NSPoint(x: run[0].x, y: rect.maxY)); area.close()
                    (secondary ? color.withAlphaComponent(alpha) : Style.fill(kind)).setFill(); area.fill()
                }
                color.withAlphaComponent(secondary ? 0.8 : 1).setStroke(); line.lineWidth = compact ? 0.65 : 0.7
                if dash { line.setLineDash([4, 3], count: 2, phase: 0) }
                line.stroke(); run.removeAll(keepingCapacity: true)
            }
            for sample in points {
                let value = secondary ? sample.secondary : sample.total
                if let lastDate, sample.time.timeIntervalSince(lastDate) > 3 { finish() }
                lastDate = sample.time
                guard let value, value.isFinite else { finish(); continue }
                let age = end.timeIntervalSince(sample.time)
                // The retained point before -60s is clipped at the frame, so
                // the line and fill meet the left border without a moving gap.
                let x = rect.maxX - CGFloat(age / 60) * rect.width
                let y = rect.maxY - CGFloat(max(0, min(ceiling, value)) / max(1, ceiling)) * rect.height
                run.append(NSPoint(x: x, y: y))
            }
            finish()
        }
        if unavailable == nil {
            render(secondary: false, fill: true, alpha: 1)
            render(secondary: true, fill: stacked, alpha: Style.dark ? 0.48 : 0.32, dash: !stacked)
        }
        NSGraphicsContext.restoreGraphicsState()
        Style.border.setStroke(); let border = NSBezierPath(rect: rect); border.lineWidth = 0.7; border.stroke()
        if let unavailable {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor]
            let text = unavailable as NSString; let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
    }
}

@MainActor final class HardwareRow: NSButton, NSDraggingSource {
    var device: HardwareDevice
    let chart = ChartView()
    let nameLabel = label(size: 18)
    let subtitle = label(size: 13, secondary: true)
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    var selected = false
    var editing = false
    var visible = true
    var onToggle: ((Bool) -> Void)?
    static let pasteboardType = NSPasteboard.PasteboardType("org.sparkmanager.hardware")
    init(device: HardwareDevice) {
        self.device = device
        super.init(frame: .zero)
        isBordered = false; title = ""; focusRingType = .none
        chart.compact = true; chart.kind = device.kind; chart.color = Style.color(device.kind)
        chart.setAccessibilityElement(false)
        addSubview(chart); addSubview(nameLabel); addSubview(subtitle); addSubview(checkbox)
        checkbox.target = self; checkbox.action = #selector(toggleVisibility)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return editing && checkbox.frame.contains(local) ? checkbox : self
    }
    @objc func toggleVisibility() { onToggle?(checkbox.state == .on) }
    override func mouseDown(with event: NSEvent) {
        guard editing else { super.mouseDown(with: event); return }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return }
            guard hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) > 4 else { continue }
            let item = NSPasteboardItem(); item.setString(device.id, forType: Self.pasteboardType)
            let dragging = NSDraggingItem(pasteboardWriter: item)
            let image = NSImage(size: bounds.size)
            image.lockFocus(); Style.selected.setFill(); bounds.fill()
            (nameLabel.stringValue as NSString).draw(at: NSPoint(x: 12, y: 25), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.labelColor])
            image.unlockFocus()
            dragging.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [dragging], event: event, source: self)
            return
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    override func layout() {
        super.layout()
        chart.frame = NSRect(x: 10, y: 11, width: 66, height: 48)
        let textWidth = bounds.width - (editing ? 124 : 94)
        nameLabel.frame = NSRect(x: 90, y: 5, width: textWidth, height: 24)
        subtitle.frame = NSRect(x: 90, y: 29, width: textWidth, height: 35)
        subtitle.maximumNumberOfLines = 2
        checkbox.isHidden = !editing; checkbox.state = visible ? .on : .off
        checkbox.frame = NSRect(x: bounds.width - 27, y: 25, width: 21, height: 22)
        checkbox.setAccessibilityLabel(tr("显示", "Show") + " " + deviceTitle(device) + " " + device.name)
        for view in [chart, nameLabel, subtitle] { view.alphaValue = editing ? (visible ? 0.75 : 0.32) : 1 }
    }
    override func draw(_ dirtyRect: NSRect) {
        ((editing ? visible : selected) ? Style.selected : Style.surface).setFill()
        bounds.fill()
    }
}

@MainActor final class HardwareListView: FlippedView {
    var editing = false
    var rowCount = 0
    var insertion: Int?
    var onMove: ((String, Int) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame); registerForDraggedTypes([HardwareRow.pasteboardType])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard editing, let row = sender.draggingSource as? HardwareRow, row.superview === self else { return [] }
        if let event = NSApp.currentEvent { autoscroll(with: event) }
        insertion = min(rowCount, max(0, Int((convert(sender.draggingLocation, from: nil).y + 36) / 72)))
        needsDisplay = true; return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { insertion = nil; needsDisplay = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let insertion, let row = sender.draggingSource as? HardwareRow, row.superview === self else { return false }
        self.insertion = nil; needsDisplay = true; onMove?(row.device.id, insertion); return true
    }
    override func draw(_ dirtyRect: NSRect) {
        if let insertion {
            NSColor.controlAccentColor.setFill()
            NSRect(x: 2, y: max(0, CGFloat(insertion) * 72 - 2), width: bounds.width - 4, height: 2).fill()
        }
    }
}

@MainActor func deviceTitle(_ device: HardwareDevice) -> String {
    switch device.kind {
    case .cpu: return "CPU"
    case .memory: return tr("内存", "Memory")
    case .disk:
        let index = device.metadata["index"] ?? "0"
        return tr("磁盘", "Disk") + " " + index
    case .network:
        let type = device.metadata["type"] ?? device.model
        return type == "Wi-Fi" ? "Wi-Fi" : tr("以太网", "Ethernet")
    case .gpu: return device.name
    }
}

@MainActor func series(_ state: HostState, device: HardwareDevice, key: String = "usage", second: String? = nil, core: Int? = nil) -> [ChartPoint] {
    state.history.map { point in
        let m = point.snapshot?.devices[device.id]
        if let core {
            let values = m?.cores?.first { ($0["index"] ?? nil) == Double(core) }
            return ChartPoint(time: point.received, total: values?[key] ?? nil, secondary: values?[second ?? "system"] ?? nil)
        }
        return ChartPoint(time: point.received, total: m?.value(key), secondary: second.flatMap { m?.value($0) })
    }
}
