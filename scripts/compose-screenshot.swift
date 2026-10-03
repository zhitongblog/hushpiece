import AppKit
// compose <out.png> <screenshot.png> <headline> <subline>
let a = CommandLine.arguments
let (out, shot, head, sub) = (a[1], a[2], a[3], a[4])
let W: CGFloat = 2880, H: CGFloat = 1800
func paint() {
    // background
    NSGradient(colors: [NSColor(srgbRed: 0.204, green: 0.212, blue: 0.31, alpha: 1), NSColor(srgbRed: 0.043, green: 0.047, blue: 0.078, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -60)
    NSGradient(colors: [NSColor(srgbRed: 1, green: 0.773, blue: 0.42, alpha: 0.13), NSColor(srgbRed: 1, green: 0.773, blue: 0.42, alpha: 0)])!
        .draw(fromCenter: NSPoint(x: W * 0.78, y: H * 0.18), radius: 0, toCenter: NSPoint(x: W * 0.78, y: H * 0.18), radius: 1300, options: [])
    // text
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let hf = NSFont(name: "PingFangSC-Semibold", size: 118) ?? .systemFont(ofSize: 118, weight: .semibold)
    let sf = NSFont(name: "PingFangSC-Regular", size: 50) ?? .systemFont(ofSize: 50)
    (head as NSString).draw(in: NSRect(x: 120, y: 120, width: W - 240, height: 170), withAttributes: [.font: hf, .foregroundColor: NSColor.white, .paragraphStyle: p])
    (sub as NSString).draw(in: NSRect(x: 200, y: 300, width: W - 400, height: 150), withAttributes: [.font: sf, .foregroundColor: NSColor(white: 1, alpha: 0.62), .paragraphStyle: p])
    // screenshot
    guard let s = NSImage(contentsOfFile: shot), let rep = s.representations.first else { return }
    let iw = CGFloat(rep.pixelsWide), ih = CGFloat(rep.pixelsHigh)
    let areaTop: CGFloat = 500, areaH = H - areaTop - 90, maxW: CGFloat = 2480
    let scale = min(maxW / iw, areaH / ih, 1.6)
    let w = iw * scale, h = ih * scale
    let r = NSRect(x: (W - w) / 2, y: areaTop + (areaH - h) / 2, width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowBlurRadius = 60; sh.shadowOffset = NSSize(width: 0, height: -20); sh.shadowColor = NSColor(white: 0, alpha: 0.55); sh.set()
    NSBezierPath(roundedRect: r, xRadius: 28, yRadius: 28).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: r, xRadius: 28, yRadius: 28).addClip()
    s.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 1, alpha: 0.10).setStroke()
    let b = NSBezierPath(roundedRect: r, xRadius: 28, yRadius: 28); b.lineWidth = 3; b.stroke()
}
let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)   // top-left origin, like the layout above
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
paint()
NSGraphicsContext.restoreGraphicsState()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
