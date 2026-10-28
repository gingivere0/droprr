// Recolors the Droprr logo for each Bento theme: the purple half takes the theme's light-mode accent,
// the red half its light-mode secondary. Every theme is recolored, including the default Graphite & Lime.
// Writes file-swap-icon-pack/themes/<theme id>/ (logo-1024.png, menubar.png, menubar@2x.png, app-icon-1024.png).
//
//     swift apple/scripts/generate_theme_logos.swift      (run from the repo root)
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let pack = root.appendingPathComponent("file-swap-icon-pack")
let tokens = try! JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("design-system/droprr/tokens.json"))) as! [String: Any]
let themes = tokens["themes"] as! [String: Any]
let order = themes["order"] as! [String]
let list = themes["list"] as! [String: [String: Any]]

struct HSL { var h, s, l: Double }

func hsl(_ r: Double, _ g: Double, _ b: Double) -> HSL {
    let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
    guard mx != mn else { return HSL(h: 0, s: 0, l: l) }
    let d = mx - mn
    let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
    var h: Double
    switch mx {
    case r: h = (g - b) / d + (g < b ? 6 : 0)
    case g: h = (b - r) / d + 2
    default: h = (r - g) / d + 4
    }
    return HSL(h: h * 60, s: s, l: l)
}

func rgb(_ c: HSL) -> (Double, Double, Double) {
    func f(_ n: Double) -> Double {
        let k = (n + c.h / 30).truncatingRemainder(dividingBy: 12)
        let a = c.s * min(c.l, 1 - c.l)
        return c.l - a * max(-1, min(k - 3, 9 - k, 1))
    }
    return (f(0), f(8), f(4))
}

func hex(_ s: String) -> HSL {
    let v = UInt32(s.dropFirst(), radix: 16)!
    return hsl(Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
}

// Reference colors of the source artwork.
let basePurple = hex("#5C21F7"), baseRed = hex("#FF5E5C")

/// Draws an image into a plain 8-bit RGBA (premultiplied) buffer we can edit directly.
func rgbaCopy(_ src: NSBitmapImageRep) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: src.pixelsWide, pixelsHigh: src.pixelsHigh,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: src.pixelsWide * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    src.draw(in: NSRect(x: 0, y: 0, width: src.pixelsWide, height: src.pixelsHigh))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func recolor(_ src: NSBitmapImageRep, accent: HSL, secondary: HSL) -> NSBitmapImageRep {
    let out = rgbaCopy(src)
    let data = out.bitmapData!
    for i in 0..<(out.pixelsWide * out.pixelsHigh) {
        let o = i * 4
        let a = Double(data[o + 3]) / 255
        guard a > 0 else { continue }
        // Un-premultiply.
        let p = hsl(Double(data[o]) / 255 / a, Double(data[o + 1]) / 255 / a, Double(data[o + 2]) / 255 / a)
        guard p.s > 0.25, p.l < 0.85 else { continue }   // whites, pale tints and grays (arrows, background) stay
        let isPurple = p.h > 200 && p.h < 320
        let isRed = p.h >= 320 || p.h < 40
        guard isPurple || isRed else { continue }
        let base = isPurple ? basePurple : baseRed, target = isPurple ? accent : secondary
        let n = HSL(h: target.h, s: min(1, target.s * p.s / max(base.s, 0.01)),
                    l: min(0.97, max(0.03, target.l + (p.l - base.l))))
        let (r, g, b) = rgb(n)
        data[o] = UInt8(max(0, min(255, (r * a * 255).rounded())))
        data[o + 1] = UInt8(max(0, min(255, (g * a * 255).rounded())))
        data[o + 2] = UInt8(max(0, min(255, (b * a * 255).rounded())))
    }
    return out
}

/// The Mac app icon (macOS doesn't mask icons): a rounded square with margins, a soft shadow and the logo.
func macIcon(logo: NSBitmapImageRep, background hexColor: String, to dir: URL) {
    let size: CGFloat = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10); shadow.set()
    NSColor.white.setFill(); path.fill()
    NSGraphicsContext.restoreGraphicsState()
    let v = UInt32(hexColor.dropFirst(), radix: 16)!
    let base = NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    NSGradient(starting: base.blended(withFraction: 0.35, of: .white)!, ending: base.blended(withFraction: 0.06, of: .black)!)!
        .draw(in: path, angle: -90)
    let img = NSImage(size: NSSize(width: logo.pixelsWide, height: logo.pixelsHigh)); img.addRepresentation(logo)
    img.draw(in: plate.insetBy(dx: 30, dy: 30))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("mac-icon-1024.png"))
    _ = size
}

func write(_ rep: NSBitmapImageRep, _ url: URL, size: Int? = nil) {
    var r = rep
    if let size {
        let resized = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
        NSGraphicsContext.current?.imageInterpolation = .high
        let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)); img.addRepresentation(rep)
        img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        r = resized
    }
    try! r.representation(using: .png, properties: [:])!.write(to: url)
}

let logo = NSBitmapImageRep(data: try! Data(contentsOf: pack.appendingPathComponent("brand/logo-transparent-1024.png")))!

/// The phone icon: the theme's logo, large, on a soft tile of the theme's tint (iOS adds the rounded mask).
func appIcon(logo: NSBitmapImageRep, background hexColor: String) -> NSBitmapImageRep {
    let size = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let v = UInt32(hexColor.dropFirst(), radix: 16)!
    let base = NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    let top = base.blended(withFraction: 0.35, of: .white)!, bottom = base.blended(withFraction: 0.06, of: .black)!
    NSGradient(starting: top, ending: bottom)!.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 36
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    let inset = CGFloat(size) * 0.05   // the logo art has its own padding; this leaves a comfortable margin
    let img = NSImage(size: NSSize(width: logo.pixelsWide, height: logo.pixelsHigh)); img.addRepresentation(logo)
    img.draw(in: NSRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for id in order {
    let light = (list[id]!["light"] as! [String: String])
    let dir = pack.appendingPathComponent("themes/\(id)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let l = recolor(logo, accent: hex(light["accent"]!), secondary: hex(light["secondary"]!))
    let i = appIcon(logo: l, background: light["accentTint"]!)
    if id == (themes["default"] as! String) { macIcon(logo: l, background: light["accentTint"]!, to: dir) }
    write(l, dir.appendingPathComponent("logo-1024.png"))
    write(l, dir.appendingPathComponent("menubar.png"), size: 18)
    write(l, dir.appendingPathComponent("menubar@2x.png"), size: 36)
    write(i, dir.appendingPathComponent("app-icon-1024.png"))
    // App icons must be opaque: flatten through JPEG with sips.
    let flat = Process()
    flat.executableURL = URL(fileURLWithPath: "/bin/sh")
    let icon = dir.appendingPathComponent("app-icon-1024.png").path
    flat.arguments = ["-c", "sips -s format jpeg -s formatOptions best '\(icon)' --out /tmp/droprr-flat.jpg >/dev/null && sips -s format png /tmp/droprr-flat.jpg --out '\(icon)' >/dev/null"]
    try! flat.run(); flat.waitUntilExit()
    print("wrote", id)
}
