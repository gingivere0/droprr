#if os(macOS)

import SwiftUI

/// The Mac app's "Atelier" look: warm paper, a serif title, hairline rules, small spaced capitals
/// for labels, and restrained buttons. The selected theme still supplies the accent (primary
/// buttons, selection) and its secondary color (the small status dot and fine details).
enum Atelier {
    static let paper = Color.adaptive(hex: 0xFBFAF6, dark: 0x1A1916)
    static let page = Color.adaptive(hex: 0xF3F0E9, dark: 0x141310)
    static let ink = Color.adaptive(hex: 0x1C1B19, dark: 0xEDEAE3)
    static let muted = Color.adaptive(hex: 0x7D776B, dark: 0xA29C90)
    static let hairline = Color.adaptive(hex: 0xE6E1D6, dark: 0x2F2D28)
    static let stripe = Color.adaptive(hex: 0xF4F1EA, dark: 0x201F1B)

    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

/// A small, letter-spaced capital label ("SEND TO", "GENERAL").
struct Kicker: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .medium))
            .tracking(2.2)
            .foregroundStyle(Atelier.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A one-pixel rule in the warm hairline color.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Atelier.hairline).frame(height: 1).accessibilityHidden(true)
    }
}

/// The main action: a crisp dark block with spaced capitals; the icon picks up the theme's second color.
struct AtelierPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Content(configuration: configuration) }

    private struct Content: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundStyle(Theme.onPrimaryButton)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Theme.primaryButton)
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(hovering && isEnabled ? 0.10 : 0)))
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.black.opacity(configuration.isPressed ? 0.15 : 0)))
                }
                .opacity(isEnabled ? 1 : 0.35)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .motion(Motion.fast, value: hovering)
        }
    }
}

/// A secondary action: spaced capitals over a thin underline, like a printed link.
struct AtelierLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Content(configuration: configuration) }

    private struct Content: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: .semibold))
                .tracking(1.8)
                .textCase(.uppercase)
                .foregroundStyle(hovering && isEnabled ? Atelier.muted : Atelier.ink)
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(hovering && isEnabled ? Atelier.muted : Atelier.ink).frame(height: 1)
                }
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .motion(Motion.fast, value: hovering)
        }
    }
}

/// A slim outlined switch: ink outline and knob off, filled with the accent and a secondary-colored knob on.
struct AtelierToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Theme.primaryButton : Color.clear)
                    .overlay(Capsule().strokeBorder(configuration.isOn ? Color.clear : Atelier.ink, lineWidth: 1))
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(configuration.isOn ? Theme.end : Atelier.ink)
                    .frame(width: 12, height: 12)
                    .padding(.horizontal, 3)
            }
        }
        .buttonStyle(.plain)
        .motion(Motion.fast, value: configuration.isOn)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// A settings line: label on the left, value or control on the right, with a hairline above.
struct AtelierRow<Trailing: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(alignment: .center, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Atelier.ink)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Atelier.muted) }
                }
                Spacer(minLength: Space.md)
                trailing()
            }
            .padding(.vertical, 11)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The small status dot beside "Ready", in the theme's secondary color.
struct StatusDot: View {
    var on: Bool
    var body: some View {
        Circle()
            .fill(on ? Theme.end : Color.orange)
            .frame(width: 6, height: 6)
            .overlay(Circle().stroke((on ? Theme.end : Color.orange).opacity(0.3), lineWidth: 3))
            .accessibilityHidden(true)
    }
}

/// Fine diagonal hatching, used inside the drop zone.
struct Stripes: View {
    var spacing: CGFloat = 7

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .foreground, lineWidth: 1)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
#endif
