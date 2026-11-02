import CoreImage.CIFilterBuiltins
import SwiftUI

/// Droprr's styled QR code (design-system/droprr/qr-style.md), ported from site/qrstyle.js, the reference
/// implementation: change them together.
enum QRStyle {
    /// design-system/droprr/qr-outline.json: in units of the outline's longest side, centered on (0, 0).
    static let outline: [(Double, Double)] = [
        (-0.0844, -0.5), (-0.1287, -0.4935), (-0.1564, -0.4751), (-0.1914, -0.417), (-0.2431, -0.3524),
        (-0.3049, -0.2509), (-0.3077, -0.1836), (-0.2975, -0.0969), (-0.2984, -0.0489), (-0.3206, -0.0101),
        (-0.3418, 0.0507), (-0.3482, 0.1338), (-0.3768, 0.2168), (-0.3796, 0.2463), (-0.4304, 0.3164),
        (-0.4479, 0.3745), (-0.4377, 0.4419), (-0.4091, 0.4797), (-0.3704, 0.4991), (-0.3298, 0.5),
        (-0.2763, 0.4926), (-0.2163, 0.4622), (-0.184, 0.4317), (-0.1195, 0.3884), (-0.0595, 0.3146),
        (0.0291, 0.2638), (0.089, 0.1836), (0.1342, 0.1531), (0.1628, 0.1218), (0.1896, 0.1052), (0.2597, 0.0839),
        (0.3971, 0.095), (0.434, 0.0839), (0.4479, 0.0701), (0.446, 0.0443), (0.4202, 0.0157), (0.3464, -0.0295),
        (0.2689, -0.0637), (0.2006, -0.1218), (0.1444, -0.1218), (0.0586, -0.0996), (-0.0577, -0.1596),
        (-0.065, -0.1753), (-0.0623, -0.1882), (-0.03, -0.2482), (-0.0217, -0.3063), (-0.0226, -0.3782),
        (-0.0383, -0.4493), (-0.0613, -0.4732), (-0.0696, -0.4908),
    ]
    static let size = 0.8   // the outline's longest side, as a share of the code
    static let gap = 0.5    // dark modules closer than this to the outline's edge are left out (in modules)
    static let dot = 0.95   // dot diameter, in modules
    static let quiet = 3    // white margin, in modules

    enum Module: UInt8 { case light, outer, inner, eye }

    /// Rows and columns of the alignment pattern centers for a version.
    static func alignment(_ version: Int) -> [Int] {
        if version == 1 { return [] }
        let count = version / 7 + 2
        let step = version == 32 ? 26 : (version * 4 + count * 2 + 1) / (count * 2 - 2) * 2
        var result = [6]
        var pos = 17 + version * 4 - 7
        while result.count < count { result.insert(pos, at: 1); pos -= step }
        return result
    }

    /// Function modules, which are always drawn: finders with separators and format information, timing, version
    /// information, and alignment patterns.
    static func functionModules(_ n: Int) -> [[Bool]] {
        let version = (n - 17) / 4
        var marked = Array(repeating: Array(repeating: false, count: n), count: n)
        func mark(_ r0: Int, _ c0: Int, _ rows: Int, _ cols: Int) {
            for r in max(0, r0)..<min(n, r0 + rows) { for c in max(0, c0)..<min(n, c0 + cols) { marked[r][c] = true } }
        }
        mark(0, 0, 9, 9); mark(0, n - 8, 9, 8); mark(n - 8, 0, 8, 9)
        mark(6, 0, 1, n); mark(0, 6, n, 1)
        if version >= 7 { mark(0, n - 11, 6, 3); mark(n - 11, 0, 3, 6) }
        let centers = alignment(version)
        for r in centers {
            for c in centers where !((r < 9 && c < 9) || (r < 9 && c > n - 10) || (r > n - 10 && c < 9)) {
                mark(r - 2, c - 2, 5, 5)
            }
        }
        return marked
    }

    static func isEye(_ r: Int, _ c: Int, _ n: Int) -> Bool {
        (r < 7 && c < 7) || (r < 7 && c >= n - 7) || (r >= n - 7 && c < 7)
    }

    /// What to draw for each module of a code without its quiet zone: dark[row][column].
    static func classify(_ dark: [[Bool]]) -> [[Module]] {
        let n = dark.count
        let fixed = functionModules(n)
        let half = Double(n) / 2
        let poly = outline.map { ($0.0 * size * Double(n) + half, $0.1 * size * Double(n) + half) }
        var kinds = Array(repeating: Array(repeating: Module.light, count: n), count: n)
        for r in 0..<n {
            for c in 0..<n {
                if isEye(r, c, n) { kinds[r][c] = .eye; continue }
                guard dark[r][c] else { continue }
                let x = Double(c) + 0.5, y = Double(r) + 0.5
                if !fixed[r][c] && edgeDistance(x, y, poly) < gap { continue }
                kinds[r][c] = inside(x, y, poly) ? .inner : .outer
            }
        }
        return kinds
    }

    private static func inside(_ x: Double, _ y: Double, _ poly: [(Double, Double)]) -> Bool {
        var result = false
        var j = poly.count - 1
        for i in poly.indices {
            let (xi, yi) = poly[i], (xj, yj) = poly[j]
            if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi { result.toggle() }
            j = i
        }
        return result
    }

    private static func edgeDistance(_ x: Double, _ y: Double, _ poly: [(Double, Double)]) -> Double {
        var best = Double.infinity
        var j = poly.count - 1
        for i in poly.indices {
            let (ax, ay) = poly[j], (bx, by) = poly[i]
            let dx = bx - ax, dy = by - ay
            let length = dx * dx + dy * dy
            let t = max(0, min(1, ((x - ax) * dx + (y - ay) * dy) / (length == 0 ? 1 : length)))
            best = min(best, ((x - ax - t * dx) * (x - ax - t * dx) + (y - ay - t * dy) * (y - ay - t * dy)).squareRoot())
            j = i
        }
        return best
    }

    /// The theme's light-palette colors (0xRRGGBB): outer is the accent; inner is the primary text, or the secondary
    /// text when the accent is itself nearly black.
    static func colors(_ palette: ThemePalette) -> (outer: UInt32, inner: UInt32) {
        let p = palette.light
        return (p.accent, luminance(p.accent) < 0.05 ? p.secondaryText : p.textPrimary)
    }

    private static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let x = Double(v) / 255
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb >> 16 & 255) + 0.7152 * channel(rgb >> 8 & 255) + 0.0722 * channel(rgb & 255)
    }

    /// The code's modules from Core Image at error correction Q, without the quiet zone Core Image adds.
    static func modules(_ text: String) -> [[Bool]]? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // One pixel per module. The dark modules' bounds are the code itself, since the finders sit in its corners.
        var top = height, left = width, bottom = -1, right = -1
        for y in 0..<height { for x in 0..<width where pixels[y * width + x] < 128 {
            top = min(top, y); bottom = max(bottom, y); left = min(left, x); right = max(right, x)
        } }
        let n = bottom - top + 1
        guard n >= 21, right - left + 1 == n else { return nil }
        return (0..<n).map { r in (0..<n).map { c in pixels[(top + r) * width + left + c] < 128 } }
    }
}

/// A styled QR code, drawn in the current theme's light colors on white.
struct StyledQRCode: View {
    var text: String

    var body: some View {
        let kinds = QRStyle.modules(text).map(QRStyle.classify)
        let (outer, inner) = QRStyle.colors(Theme.palette)
        Canvas { context, size in
            guard let kinds else { return }
            let n = kinds.count
            let unit = min(size.width, size.height) / CGFloat(n + QRStyle.quiet * 2)
            let offset = CGFloat(QRStyle.quiet) * unit
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var outerDots = Path(), innerDots = Path()
            let d = CGFloat(QRStyle.dot) * unit
            for r in 0..<n {
                for c in 0..<n {
                    let rect = CGRect(x: offset + (CGFloat(c) + 0.5) * unit - d / 2, y: offset + (CGFloat(r) + 0.5) * unit - d / 2,
                                      width: d, height: d)
                    switch kinds[r][c] {
                    case .outer: outerDots.addEllipse(in: rect)
                    case .inner: innerDots.addEllipse(in: rect)
                    default: break
                    }
                }
            }
            context.fill(outerDots, with: .color(Self.color(outer)))
            context.fill(innerDots, with: .color(Self.color(inner)))
            // The eyes: a 7-module rounded square, a white 5, and a 3, all in the outer color.
            for (row, col) in [(0, 0), (0, n - 7), (n - 7, 0)] {
                let x = offset + CGFloat(col) * unit, y = offset + CGFloat(row) * unit
                func square(_ inset: CGFloat, _ side: CGFloat, _ radius: CGFloat) -> Path {
                    Path(roundedRect: CGRect(x: x + inset * unit, y: y + inset * unit, width: side * unit, height: side * unit),
                         cornerRadius: radius * unit)
                }
                context.fill(square(0, 7, 2.4), with: .color(Self.color(outer)))
                context.fill(square(1, 5, 1.6), with: .color(.white))
                context.fill(square(2, 3, 1), with: .color(Self.color(outer)))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("QR code")
    }

    private static func color(_ rgb: UInt32) -> Color {
        Color(red: Double(rgb >> 16 & 255) / 255, green: Double(rgb >> 8 & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}
