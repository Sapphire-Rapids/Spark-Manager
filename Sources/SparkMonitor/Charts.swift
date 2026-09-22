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
                let age = now.timeIntervalSince(sample.time)
                guard age <= 60 else { continue }
                let x = rect.maxX - CGFloat(max(0, age) / 60) * rect.width
                let y = rect.maxY - CGFloat(max(0, min(ceiling, value)) / max(1, ceiling)) * rect.height
                run.append(NSPoint(x: x, y: y))
            }
            finish()
        }
        if unavailable == nil {
            render(secondary: false, fill: true, alpha: 1)
            render(secondary: true, fill: stacked, alpha: Style.dark ? 0.48 : 0.32, dash: !stacked)
        }
        Style.border.setStroke(); let border = NSBezierPath(rect: rect); border.lineWidth = 0.7; border.stroke()
        if let unavailable {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor]
            let text = unavailable as NSString; let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
        }
    }
}

@MainActor final class HardwareRow: NSButton {
    let device: HardwareDevice
    let chart = ChartView()
    let nameLabel = label(size: 18)
    let subtitle = label(size: 13, secondary: true)
    var selected = false
    init(device: HardwareDevice) {
        self.device = device
        super.init(frame: .zero)
        isBordered = false; title = ""; focusRingType = .none
        chart.compact = true; chart.kind = device.kind; chart.color = Style.color(device.kind)
        chart.setAccessibilityElement(false)
        addSubview(chart); addSubview(nameLabel); addSubview(subtitle)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func layout() {
        super.layout()
        chart.frame = NSRect(x: 10, y: 11, width: 66, height: 48)
        nameLabel.frame = NSRect(x: 90, y: 5, width: bounds.width - 94, height: 24)
        subtitle.frame = NSRect(x: 90, y: 29, width: bounds.width - 94, height: 35)
        subtitle.maximumNumberOfLines = 2
    }
    override func draw(_ dirtyRect: NSRect) {
        (selected ? Style.selected : Style.surface).setFill()
        bounds.fill()
    }
}

@MainActor func deviceTitle(_ device: HardwareDevice) -> String {
    switch device.kind {
    case .cpu: return "CPU"
    case .memory: return tr("内存", "Memory")
    case .disk:
        let index = device.metadata["index"] ?? "0"
        let mount = device.metadata["system"] == "true" ? " (/)" : ""
        return tr("磁盘", "Disk") + " " + index + mount
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
