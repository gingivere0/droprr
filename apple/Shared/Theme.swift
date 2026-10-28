import SwiftUI

/// Droprr's look, taken from the icon pack: violet into coral, rounded cards, platform glyphs.
enum Theme {
    static let start = Color(red: 0.36, green: 0.13, blue: 0.97)
    static let end = Color(red: 1.0, green: 0.37, blue: 0.36)
    static let gradient = LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)

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
        Circle()
            .fill(filled ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.start.opacity(0.12)))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.start))
            }
    }
}

/// The send result line, with a thin gradient progress bar while uploading.
struct SendStatusView: View {
    var message: String?
    var progress: Double?

    var body: some View {
        if message != nil || progress != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let progress {
                    ProgressView(value: progress).tint(Theme.end)
                }
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .transition(.opacity)
        }
    }
}

extension ReceivedItem {
    var subtitle: String {
        let time = date.formatted(.relative(presentation: .named))
        switch kind {
        case .file: return "File · \(time)"
        case .text: return "Text · \(time)"
        case .url: return "Link · \(time)"
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
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
                .foregroundStyle(kind == .prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background {
                    let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
                    switch kind {
                    case .prominent:
                        shape.fill(Theme.gradient)
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
                .animation(.easeOut(duration: 0.12), value: active)
        }
    }
}

extension View {
    func hoverHint(_ text: String, after delay: Duration = .seconds(1)) -> some View {
        modifier(HoverHint(text: text, delay: delay))
    }
}
#endif
