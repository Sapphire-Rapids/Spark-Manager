import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        NSColor(srgbRed: 0.94, green: 0.96, blue: 0.99, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: p * 0.05, y: p * 0.05, width: p * 0.9, height: p * 0.9), xRadius: p * 0.20, yRadius: p * 0.20).fill()
        let box = NSRect(x: p * 0.20, y: p * 0.23, width: p * 0.60, height: p * 0.54)
        let grid = NSBezierPath(); grid.lineWidth = max(1, p * 0.006)
        for i in 0...4 {
            let x = box.minX + box.width * CGFloat(i) / 4
            grid.move(to: NSPoint(x: x, y: box.minY)); grid.line(to: NSPoint(x: x, y: box.maxY))
            let y = box.minY + box.height * CGFloat(i) / 4
            grid.move(to: NSPoint(x: box.minX, y: y)); grid.line(to: NSPoint(x: box.maxX, y: y))
        }
        NSColor(srgbRed: 0.66, green: 0.81, blue: 0.89, alpha: 1).setStroke(); grid.stroke()
        let graph = NSBezierPath(); graph.lineWidth = p * 0.045; graph.lineJoinStyle = .round
        for (i, value) in [0.15, 0.24, 0.18, 0.78, 0.37, 0.55, 0.4, 0.65].enumerated() {
            let pt = NSPoint(x: box.minX + box.width * CGFloat(i) / 7, y: box.minY + box.height * value)
            if i == 0 { graph.move(to: pt) } else { graph.line(to: pt) }
        }
        NSColor(srgbRed: 0.12, green: 0.47, blue: 0.68, alpha: 1).setStroke(); graph.stroke()
        image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
