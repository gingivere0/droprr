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
        case .text: return "Text · copied · \(time)"
        case .url: return "Link · copied · \(time)"
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

extension View {
    func hoverHint(_ text: String, after delay: Duration = .seconds(1)) -> some View {
        modifier(HoverHint(text: text, delay: delay))
    }
}
#endif
