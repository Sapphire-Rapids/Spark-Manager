import AppKit

@MainActor enum Style {
    static var dark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    static var surface: NSColor { dark ? NSColor(white: 0.13, alpha: 1) : .white }
    static var sidebar: NSColor { dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1) }
    static var grid: NSColor { dark ? NSColor(white: 0.27, alpha: 1) : NSColor(white: 0.88, alpha: 1) }
    static var selected: NSColor { dark ? NSColor(white: 0.23, alpha: 1) : NSColor(white: 0.92, alpha: 1) }
    static func color(_ kind: HardwareKind) -> NSColor {
        switch kind {
        case .cpu: return NSColor(srgbRed: 0.15, green: 0.52, blue: 0.69, alpha: 1)
        case .memory: return NSColor(srgbRed: 0.38, green: 0.42, blue: 0.81, alpha: 1)
        case .disk: return NSColor(srgbRed: 0.42, green: 0.59, blue: 0.17, alpha: 1)
        case .network: return NSColor(srgbRed: 0.69, green: 0.34, blue: 0.49, alpha: 1)
        case .gpu: return NSColor(srgbRed: 0.57, green: 0.33, blue: 0.77, alpha: 1)
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
    var ceiling: Double = 100
    var stacked = false
    var compact = false
    var coreIndex: Int?
    var onMode: ((Bool) -> Void)?
    var logical = false
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
            for i in 1..<10 {
                let x = rect.minX + rect.width * CGFloat(i) / 10
                grid.move(to: NSPoint(x: x, y: rect.minY)); grid.line(to: NSPoint(x: x, y: rect.maxY))
            }
            for i in 1..<5 {
                let y = rect.minY + rect.height * CGFloat(i) / 5
                grid.move(to: NSPoint(x: rect.minX, y: y)); grid.line(to: NSPoint(x: rect.maxX, y: y))
            }
            Style.grid.setStroke(); grid.stroke()
        }
        let now = Date()
        func render(secondary: Bool, fill: Bool, alpha: CGFloat, dash: Bool = false) {
            var run: [NSPoint] = []; var lastDate: Date?
            func finish() {
                guard !run.isEmpty else { return }
                let line = NSBezierPath(); line.move(to: run[0]); run.dropFirst().forEach { line.line(to: $0) }
                if fill {
                    let area = line.copy() as! NSBezierPath
                    area.line(to: NSPoint(x: run.last!.x, y: rect.maxY))
                    area.line(to: NSPoint(x: run[0].x, y: rect.maxY)); area.close()
                    color.withAlphaComponent(alpha).setFill(); area.fill()
                }
                color.withAlphaComponent(secondary ? 0.85 : 1).setStroke(); line.lineWidth = compact ? 1 : 1.35
                if dash { line.setLineDash([4, 3], count: 2, phase: 0) }
                line.stroke(); run.removeAll(keepingCapacity: true)
            }
            for sample in points {
                let value = secondary ? sample.secondary : sample.total
                if let lastDate, sample.time.timeIntervalSince(lastDate) > 3 { finish() }
                lastDate = sample.time
                guard let value, value.isFinite else { finish(); continue }
                let age = now.timeIntervalSince(sample.time)
                guard age <= 60 else { continue }
                let x = rect.maxX - CGFloat(max(0, age) / 60) * rect.width
                let y = rect.maxY - CGFloat(max(0, min(ceiling, value)) / max(1, ceiling)) * rect.height
                run.append(NSPoint(x: x, y: y))
            }
            finish()
        }
        render(secondary: false, fill: true, alpha: Style.dark ? 0.20 : 0.16)
        render(secondary: true, fill: stacked, alpha: Style.dark ? 0.52 : 0.38, dash: !stacked)
        color.withAlphaComponent(0.6).setStroke(); NSBezierPath(rect: rect).stroke()
        if let coreIndex {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
            ("CPU \(coreIndex)" as NSString).draw(at: NSPoint(x: 5, y: 3), withAttributes: attrs)
        }
    }
}

@MainActor final class HardwareRow: NSButton {
    let device: HardwareDevice
    let chart = ChartView()
    let nameLabel = label(size: 13)
    let subtitle = label(size: 11, secondary: true)
    var selected = false
    init(device: HardwareDevice) {
        self.device = device
        super.init(frame: .zero)
        isBordered = false; title = ""; focusRingType = .none
        chart.compact = true; chart.color = Style.color(device.kind)
        chart.setAccessibilityElement(false)
        addSubview(chart); addSubview(nameLabel); addSubview(subtitle)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func layout() {
        super.layout()
        chart.frame = NSRect(x: 12, y: 14, width: 62, height: 39)
        nameLabel.frame = NSRect(x: 86, y: 11, width: bounds.width - 92, height: 20)
        subtitle.frame = NSRect(x: 86, y: 32, width: bounds.width - 92, height: 28)
        subtitle.maximumNumberOfLines = 2
    }
    override func draw(_ dirtyRect: NSRect) {
        (selected ? Style.selected : Style.sidebar).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
        if selected { Style.color(device.kind).setFill(); NSBezierPath(roundedRect: NSRect(x: 3, y: 17, width: 3, height: 34), xRadius: 1.5, yRadius: 1.5).fill() }
    }
}

@MainActor func deviceTitle(_ device: HardwareDevice) -> String {
    switch device.kind {
    case .cpu: return "CPU"
    case .memory: return tr("内存", "Memory")
    case .disk: return tr("磁盘", "Disk") + " " + device.name
    case .network: return device.model == "Ethernet" ? tr("以太网", "Ethernet") : device.model
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
