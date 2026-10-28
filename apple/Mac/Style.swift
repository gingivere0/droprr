import AppKit
import SwiftUI

/// Mac-only building blocks for the richer Send and Settings screens.

/// A rounded-square gradient tile with a white glyph, like an app icon.
struct GradientTile: View {
    var symbol: String
    var size: CGFloat = 32
    var glowing = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Theme.start.opacity(glowing ? 0.45 : 0.2), radius: glowing ? size * 0.3 : size * 0.12, y: size * 0.08)
            .accessibilityHidden(true)
    }
}

/// A solid-color icon tile for section headers, like System Settings.
struct ColorTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.smallControl, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// A raised card: material fill, hairline stroke, soft shadow.
struct CardBackground: ViewModifier {
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .padding(Space.lg)
            .background {
                RoundedRectangle(cornerRadius: Radius.feature, style: .continuous)
                    .fill(.background.secondary)
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
                    .overlay(RoundedRectangle(cornerRadius: Radius.feature, style: .continuous)
                        .strokeBorder(highlighted ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.stroke),
                                      lineWidth: highlighted ? 2 : 1))
            }
    }
}

extension View {
    func card(highlighted: Bool = false) -> some View { modifier(CardBackground(highlighted: highlighted)) }
}

/// A card header: colored icon tile, title, optional subtitle and trailing accessory.
struct CardHeader<Accessory: View>: View {
    var symbol: String
    var color: Color
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    init(symbol: String, color: Color, title: String, subtitle: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.symbol = symbol
        self.color = color
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: Space.md) {
            ColorTile(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            accessory()
        }
        .accessibilityElement(children: .contain)
    }
}

/// A soft brand glow behind a window's top edge, so screens don't feel flat.
struct WindowGlow: View {
    var body: some View {
        ZStack {
            Circle().fill(Theme.start.opacity(0.16)).frame(width: 320).blur(radius: 80).offset(x: -160, y: -170)
            Circle().fill(Theme.end.opacity(0.12)).frame(width: 260).blur(radius: 80).offset(x: 200, y: -190)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A capsule label, e.g. "Ready" or "iPhone".
struct Pill: View {
    var text: String
    var symbol: String?
    var color: Color = Theme.accentText

    var body: some View {
        HStack(spacing: Space.xs) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Hides the window's title bar strip so the content (and its glow) runs to the top edge.
/// The close/minimize buttons stay; content leaves room for them.
struct SeamlessTitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
    }
}

extension View {
    /// Seamless title bar plus top room for the window buttons.
    func seamlessWindow() -> some View {
        self
            .padding(.top, Space.lg)
            .background(SeamlessTitleBar().frame(width: 0, height: 0))
            .ignoresSafeArea(.container, edges: .top)
    }
}
