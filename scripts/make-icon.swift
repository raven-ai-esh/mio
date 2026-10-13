import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let pixels = size * factor
        let canvas = NSImage(size: NSSize(width: pixels, height: pixels))
        canvas.lockFocus()
        let side = CGFloat(pixels)
        let inset = side * 0.04
        let background = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2), xRadius: side * 0.22, yRadius: side * 0.22)
        let gradient = NSGradient(starting: NSColor(calibratedRed: 0.23, green: 0.60, blue: 0.98, alpha: 1), ending: NSColor(calibratedRed: 0.10, green: 0.26, blue: 0.68, alpha: 1))!
        gradient.draw(in: background, angle: -70)
        let points = [NSPoint(x: side * 0.28, y: side * 0.31), NSPoint(x: side * 0.50, y: side * 0.70), NSPoint(x: side * 0.72, y: side * 0.31)]
        let path = NSBezierPath(); path.move(to: points[0]); path.line(to: points[1]); path.line(to: points[2]); path.line(to: points[0]); path.lineWidth = side * 0.047
        NSColor.white.withAlphaComponent(0.78).setStroke(); path.stroke()
        for point in points {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - side * 0.078, y: point.y - side * 0.078, width: side * 0.156, height: side * 0.156)).fill()
        }
        canvas.unlockFocus()
        let bitmap = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let name = "icon_\(size)x\(size)\(factor == 2 ? "@2x" : "").png"
        try data.write(to: output.appendingPathComponent(name))
    }
}
