import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One Bento color theme (see design-system/droprr, "Bento themes"). Values live in ThemePalettes.swift.
struct ThemePalette: Identifiable, Equatable {
    struct Roles: Equatable {
        var surface, tile, border, textPrimary, textSecondary, primaryButton, onPrimaryButton: UInt32
        var accent, onAccent, accentText, accentTint, secondary, secondaryTint, secondaryText: UInt32
    }

    let id: String
    let name: String
    let light: Roles
    let dark: Roles

    static func named(_ id: String) -> ThemePalette {
        all.first { $0.id == id } ?? all.first { $0.id == defaultID }!
    }
}

/// Droprr's look: the Bento Grid in the theme chosen in Settings (Graphite & Lime by default).
/// Every color follows light and dark mode. Reading these inside a view's body re-renders it when the
/// theme changes, because the selection lives in the observable settings.
enum Theme {
    static var palette: ThemePalette { ThemePalette.named(DroprrSettings.shared.theme) }

    private static func color(_ role: KeyPath<ThemePalette.Roles, UInt32>) -> Color {
        let p = palette
        return Color.adaptive(hex: p.light[keyPath: role], dark: p.dark[keyPath: role])
    }

    /// The accent fill: selected tiles, toggles, the app glyph tile.
    static var start: Color { color(\.accent) }
    static var onAccent: Color { color(\.onAccent) }
    /// The theme's secondary color: the message tile and "waiting" badges.
    static var end: Color { color(\.secondary) }
    static var secondaryTint: Color { color(\.secondaryTint) }
    static var secondaryText: Color { color(\.secondaryText) }
    /// Bento uses flat fills; kept as a gradient type so existing call sites keep working.
    static var gradient: LinearGradient { LinearGradient(colors: [start, start], startPoint: .top, endPoint: .bottom) }
    static var accentText: Color { color(\.accentText) }
    static var accentTint: Color { color(\.accentTint) }
    static var surface: Color { color(\.surface) }
    static var tile: Color { color(\.tile) }
    static var stroke: Color { color(\.border) }
    static var primaryButton: Color { color(\.primaryButton) }
    static var onPrimaryButton: Color { color(\.onPrimaryButton) }
    static var successFill: Color { Color.adaptive(hex: ThemePalette.successFill.light, dark: ThemePalette.successFill.dark) }
    static var successText: Color { Color.adaptive(hex: ThemePalette.successText.light, dark: ThemePalette.successText.dark) }

    static func symbol(for peer: Peer) -> String {
        switch peer.platform {
        case "ios": return "iphone"
        case "macos": return "laptopcomputer"
        case "windows": return "pc"
        default: return "desktopcomputer"
        }
    }

    static func platformName(_ platform: String?) -> String {
        switch platform {
        case "ios": return "iPhone"
        case "macos": return "Mac"
        case "windows": return "Windows"
        default: return "Computer"
        }
    }

    static func symbol(for item: ReceivedItem) -> String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .url: return "link"
        case .file(let url):
            switch url.pathExtension.lowercased() {
            case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp": return "photo"
            case "mov", "mp4", "m4v": return "film"
            case "pdf": return "doc.richtext"
            case "zip": return "doc.zipper"
            case "mp3", "m4a", "wav": return "waveform"
            default: return "doc"
            }
        }
    }
}

/// space.* — the 4-point grid. Use only these steps.
enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// radius.* by role. Always used with `style: .continuous`.
enum Radius {
    static let smallControl: CGFloat = 6
    static let button: CGFloat = 7
    static let row: CGFloat = 8
    static let card: CGFloat = 12
    static let feature: CGFloat = 14
    /// Bento tiles (tokens.json "bento.radius.tile").
    #if os(macOS)
    static let tile: CGFloat = 16
    #else
    static let tile: CGFloat = 20
    #endif
}

/// motion.*: short ease-out transitions that respect Reduce Motion.
enum Motion {
    static let fast = Animation.easeOut(duration: 0.12)
    static let standard = Animation.easeOut(duration: 0.2)
    static let slow = Animation.easeOut(duration: 0.3)

    static var reduced: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }

    /// `withAnimation`, skipped when Reduce Motion is on.
    static func perform<Result>(_ animation: Animation = standard, _ body: () throws -> Result) rethrows -> Result {
        try withAnimation(reduced ? nil : animation, body)
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    var animation: Animation
    var value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that shows the final state immediately when Reduce Motion is on.
    func motion<V: Equatable>(_ animation: Animation = Motion.standard, value: V) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

extension Color {
    static func adaptive(hex light: UInt32, dark: UInt32) -> Color {
        func rgb(_ v: UInt32) -> (Int, Int, Int) { (Int(v >> 16 & 0xFF), Int(v >> 8 & 0xFF), Int(v & 0xFF)) }
        return adaptive(light: rgb(light), dark: rgb(dark))
    }

    static func adaptive(light: (Int, Int, Int), dark: (Int, Int, Int), lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        func rgb(_ c: (Int, Int, Int)) -> (CGFloat, CGFloat, CGFloat) { (CGFloat(c.0) / 255, CGFloat(c.1) / 255, CGFloat(c.2) / 255) }
        let (l, d) = (rgb(light), rgb(dark))
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: d.0, green: d.1, blue: d.2, alpha: darkAlpha)
                : NSColor(srgbRed: l.0, green: l.1, blue: l.2, alpha: lightAlpha)
        })
        #else
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: d.0, green: d.1, blue: d.2, alpha: darkAlpha)
                : UIColor(red: l.0, green: l.1, blue: l.2, alpha: lightAlpha)
        })
        #endif
    }
}

/// The app mark from the icon pack (file with swap arrows).
struct LogoBadge: View {
    var size: CGFloat = 28

    var body: some View {
        Image("Logo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: Theme.start.opacity(0.25), radius: size * 0.1, y: size * 0.05)
    }
}

/// A round icon on a tinted background, used for devices and items.
struct GlyphCircle: View {
    var symbol: String
    var size: CGFloat = 30
    var filled = false

    var body: some View {
        // Bento icon well: a rounded square, accent-filled when selected.
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(filled ? Theme.start : Theme.accentTint)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(filled ? Theme.onAccent : Theme.accentText)
            }
    }
}

/// A native-style status banner for sends: spinner and progress while sending,
/// a green check when sent, an orange warning on failure, and plain info otherwise.
struct SendStatusView: View {
    var message: String?
    var progress: Double?

    enum Kind { case working, success, failure, info }

    static func kind(of message: String) -> Kind {
        if message.hasPrefix("Sending") || message.hasPrefix("Preparing") || message.hasPrefix("Queueing") { return .working }
        if message.hasPrefix("Sent") || message.hasPrefix("Paired") || message.hasPrefix("Cleared") || message.hasSuffix("paired.") { return .success }
        if message.hasPrefix("Couldn't") || message.hasPrefix("Open the") || message.contains("empty") { return .failure }
        return .info
    }

    var body: some View {
        if let message {
            let kind = Self.kind(of: message)
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    icon(kind)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if let progress, kind == .working {
                    ProgressView(value: progress).tint(Theme.end)
                        .accessibilityLabel("Upload progress")
                }
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint(kind), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        }
    }

    @ViewBuilder private func icon(_ kind: Kind) -> some View {
        switch kind {
        case .working: ProgressView().controlSize(.small)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(Theme.accentText)
        }
    }

    private func tint(_ kind: Kind) -> Color {
        switch kind {
        case .success: return Theme.successFill
        case .failure: return Color.orange.opacity(0.14)
        case .working, .info: return Theme.accentTint
        }
    }
}

extension ReceivedItem {
    var subtitle: String {
        let time = date.formatted(.relative(presentation: .named))
        switch kind {
        case .file: return "File · \(time)"
        #if os(macOS)
        case .text: return "Text · copied · \(time)"
        case .url: return "Link · copied · \(time)"
        #else
        case .text: return "Text · \(time)"
        case .url: return "Link · \(time)"
        #endif
        }
    }
}

#if os(macOS)
/// Shows a small hint after the pointer rests on a view for a second. Used instead of `.help`,
/// whose tooltips don't appear reliably in a menu bar panel.
private struct HoverHint: ViewModifier {
    var text: String
    var delay: Duration
    @State private var showing = false
    @State private var timer: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                timer?.cancel()
                if inside {
                    timer = Task {
                        try? await Task.sleep(for: delay)
                        if !Task.isCancelled { showing = true }
                    }
                } else {
                    showing = false
                }
            }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
            }
            .accessibilityHint(text)
    }
}

/// Mac buttons that visibly shade on hover, so it's clear what's clickable.
struct HoverButtonStyle: ButtonStyle {
    enum Kind { case bordered, prominent, plain }
    var kind: Kind
    var compact = false

    init(_ kind: Kind, compact: Bool = false) {
        self.kind = kind
        self.compact = compact
    }

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, kind: kind, compact: compact)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let active = hovering && isEnabled
            configuration.label
                .padding(.horizontal, kind == .plain ? 4 : (compact ? 8 : 12))
                .padding(.vertical, kind == .plain ? 3 : (compact ? 4 : 6))
                .foregroundStyle(kind == .prominent ? AnyShapeStyle(Theme.onPrimaryButton) : AnyShapeStyle(.primary))
                .background {
                    let shape = RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    switch kind {
                    case .prominent:
                        shape.fill(Theme.primaryButton)
                            .overlay(shape.fill(Color.white.opacity(active ? 0.18 : 0)))
                            .overlay(shape.fill(Color.black.opacity(configuration.isPressed ? 0.15 : 0)))
                    case .bordered:
                        shape.fill(Color.primary.opacity(configuration.isPressed ? 0.22 : active ? 0.15 : 0.07))
                    case .plain:
                        shape.fill(Color.primary.opacity(configuration.isPressed ? 0.16 : active ? 0.09 : 0))
                    }
                }
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .motion(Motion.fast, value: active)
        }
    }
}

extension View {
    func hoverHint(_ text: String, after delay: Duration = .seconds(1)) -> some View {
        modifier(HoverHint(text: text, delay: delay))
    }
}
#endif
