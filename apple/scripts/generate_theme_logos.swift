// Recolors the Droprr logo for each Bento theme: the purple half takes the theme's light-mode accent,
// the red half its light-mode secondary. Graphite & Lime keeps the original purple and red.
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
let originalTheme = themes["default"] as! String   // keeps the brand purple and red

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
let icon = NSBitmapImageRep(data: try! Data(contentsOf: pack.appendingPathComponent("ios/AppIcon.appiconset/app-icon-1024.png")))!

for id in order {
    let light = (list[id]!["light"] as! [String: String])
    let dir = pack.appendingPathComponent("themes/\(id)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let (l, i): (NSBitmapImageRep, NSBitmapImageRep)
    if id == originalTheme {
        (l, i) = (logo, icon)
    } else {
        let a = hex(light["accent"]!), s = hex(light["secondary"]!)
        (l, i) = (recolor(logo, accent: a, secondary: s), recolor(icon, accent: a, secondary: s))
    }
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
