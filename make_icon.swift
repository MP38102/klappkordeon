import AppKit
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let dir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for s in sizes {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let f = CGFloat(s)
    let rect = NSRect(x: f * 0.1, y: f * 0.1, width: f * 0.8, height: f * 0.8)
    NSGradient(colors: [NSColor(red: 0.80, green: 0.17, blue: 0.20, alpha: 1), NSColor(red: 0.42, green: 0.06, blue: 0.09, alpha: 1)])!
        .draw(in: NSBezierPath(roundedRect: rect, xRadius: f * 0.18, yRadius: f * 0.18), angle: -90)
    let emoji = "🪗" as NSString
    let font = NSFont.systemFont(ofSize: f * 0.5)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let sz = emoji.size(withAttributes: attrs)
    emoji.draw(at: NSPoint(x: (f - sz.width) / 2, y: (f - sz.height) / 2), withAttributes: attrs)
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    let png = rep.representation(using: .png, properties: [:])!
    for (name, px) in [("icon_\(s)x\(s).png", s), ("icon_\(s/2)x\(s/2)@2x.png", s)] where px >= 32 || name.hasPrefix("icon_16") {
        if name.contains("@2x") && s / 2 < 16 { continue }
        try! png.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    }
}
