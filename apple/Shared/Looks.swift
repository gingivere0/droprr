import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The Mac app's window styles. The color theme (ThemePalette) still supplies the accent and
/// secondary colors; the style decides surfaces, shapes, type and controls.
enum LookStyle: String, CaseIterable, Identifiable {
    case atelier, material, clay, spatial

    var id: String { rawValue }

    var name: String {
        switch self {
        case .material: return "Material You"
        case .clay: return "Clay"
        case .spatial: return "Spatial"
        case .atelier: return "Atelier"
        }
    }

    var detail: String {
        switch self {
        case .material: return "Tonal surfaces, big rounded shapes"
        case .clay: return "Soft, puffy 3D shapes"
        case .spatial: return "Dark frosted glass"
        case .atelier: return "Ivory paper, serif titles"
        }
    }
}

/// Style tokens for the current LookStyle. Reading them inside a view's body tracks the setting,
/// so views redraw when the style changes.
enum Look {
    static var style: LookStyle { LookStyle(rawValue: DroprrSettings.shared.style) ?? .atelier }
    static var isAtelier: Bool { style == .atelier }
    /// Spatial is always dark glass.
    static var forcesDark: Bool { style == .spatial }

    /// The color scheme to show: Spatial's dark, the user's Light/Dark choice, or nil to follow the system.
    static var colorScheme: ColorScheme? {
        if forcesDark { return .dark }
        switch DroprrSettings.shared.colorMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    #if os(macOS)
    /// Applies the Light/Dark choice to every Droprr window, the menu bar panel included.
    @MainActor
    static func applyAppAppearance() {
        switch DroprrSettings.shared.colorMode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
    #endif

    static var background: Color {
        switch style {
        case .material: return Color.adaptive(hex: 0xF8F8F3, dark: 0x131411)
        case .clay: return Color.adaptive(hex: 0xF3F0FA, dark: 0x1C1925)
        case .spatial: return Color(white: 0.14)
        case .atelier: return Color.adaptive(hex: 0xFBFAF6, dark: 0x1A1916)
        }
    }

    /// The fill behind grouped content (cards, fields, the drop zone).
    static var container: Color {
        switch style {
        case .material: return Color.adaptive(hex: 0xECEDE5, dark: 0x1F211C)
        case .clay: return Color.adaptive(hex: 0xFBF9FF, dark: 0x272333)
        case .spatial: return Color.white.opacity(0.08)
        case .atelier: return Color.adaptive(hex: 0xFBFAF6, dark: 0x1A1916)
        }
    }

    static var ink: Color {
        switch style {
        case .material: return Color.adaptive(hex: 0x1B1C18, dark: 0xE4E4DC)
        case .clay: return Color.adaptive(hex: 0x37324C, dark: 0xECE8F8)
        case .spatial: return .white
        case .atelier: return Color.adaptive(hex: 0x1C1B19, dark: 0xEDEAE3)
        }
    }

    static var muted: Color {
        switch style {
        case .material: return Color.adaptive(hex: 0x5C5E55, dark: 0xA9AAA1)
        // Light Clay and Atelier are nudged to 4.5:1 on their tiles; Spatial's is opaque for the
        // same reason (on its glass at the room's lightest corner). Windows uses the same values.
        case .clay: return Color.adaptive(hex: 0x756F8F, dark: 0xA7A1C2)
        case .spatial: return Color(hex: 0xDAD9D7)
        case .atelier: return Color.adaptive(hex: 0x787266, dark: 0xA29C90)
        }
    }

    static var hairline: Color {
        switch style {
        case .material: return Color.adaptive(hex: 0xDADBD2, dark: 0x30322B)
        case .clay: return Color.adaptive(hex: 0xECE8F6, dark: 0x332E42)
        case .spatial: return Color.white.opacity(0.08)
        case .atelier: return Color.adaptive(hex: 0xE6E1D6, dark: 0x2F2D28)
        }
    }

    static let stripe = Color.adaptive(hex: 0xF4F1EA, dark: 0x201F1B)

    /// The theme's accent text, lightened in Spatial until it reads at 4.5:1 on the glass.
    static var accentText: Color {
        guard forcesDark, drawsGlass else { return Theme.accentText }
        return Color(hex: Contrast.ensure(Theme.palette.dark.accentText, on: Contrast.spatialTile))
    }

    /// The iPhone share sheet keeps the plain look, so it doesn't need Spatial's lighter text.
    private static var drawsGlass: Bool {
        #if os(iOS)
        return Bundle.main.bundleURL.pathExtension != "appex"
        #else
        return true
        #endif
    }

    /// Fill and text for a selected device card.
    static var selectedFill: Color { style == .spatial ? Color.white.opacity(0.9) : Theme.secondaryTint }
    static var selectedInk: Color { style == .spatial ? Color(white: 0.08) : Theme.secondaryText }

    static var cardRadius: CGFloat {
        switch style {
        case .material: return 24
        case .clay: return 22
        case .spatial: return 24
        case .atelier: return 0
        }
    }

    /// Display type: page titles and device names.
    static func display(_ size: CGFloat, weight: Font.Weight? = nil) -> Font {
        switch style {
        case .material: return .system(size: size, weight: weight ?? .regular)
        case .clay: return .system(size: size, weight: weight ?? .heavy, design: .rounded)
        case .spatial: return .system(size: size, weight: weight ?? .bold)
        case .atelier: return .system(size: size, weight: .regular, design: .serif)
        }
    }

    /// Smaller display text such as device names, which shouldn't be heavy.
    static func name(_ size: CGFloat) -> Font {
        switch style {
        case .atelier: return .system(size: size, design: .serif)
        case .clay: return .system(size: size - 2, weight: .bold, design: .rounded)
        default: return .system(size: size - 2, weight: .semibold)
        }
    }

    #if os(macOS)
    /// The window's own background color behind the SwiftUI content.
    static var windowColor: NSColor { style == .spatial ? .clear : NSColor(background) }
    #endif
}

// MARK: Backgrounds and containers

#if os(macOS)
private struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}
#endif

/// The window background for the current style.
struct LookBackground: View {
    static let snapshotting = ProcessInfo.processInfo.environment["DROPRR_SNAPSHOT"] != nil
    static let room = LinearGradient(colors: [Color(red: 0.42, green: 0.39, blue: 0.35), Color(red: 0.24, green: 0.27, blue: 0.3)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        switch Look.style {
        case .spatial:
            ZStack {
                #if os(macOS)
                if Self.snapshotting {
                    // Snapshots can't draw AppKit views; stand in for the blurred desktop.
                    Self.room
                } else {
                    VisualEffect(material: .hudWindow)
                }
                #else
                // iPhone apps can't see what's behind them, so Spatial floats over a soft, dim room.
                Self.room
                #endif
                Color.black.opacity(0.18)
                // A faint glow of the theme's second color, like light in the room.
                RadialGradient(colors: [Theme.end.opacity(0.18), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            }
        case .material:
            ZStack { Look.background; Theme.start.opacity(0.03) }
        default:
            Look.background
        }
    }
}

extension View {
    /// Root of a window or panel: background, text color, type design, toggles and the color
    /// scheme the style needs.
    func lookRoot() -> some View {
        self
            .foregroundStyle(Look.ink)
            .fontDesign(Look.style == .clay ? .rounded : .default)
            #if os(macOS)
            .toggleStyle(LookToggleStyle())
            #endif
            .background { LookBackground().ignoresSafeArea() }
            .modifier(ForcedDark())
    }

    /// Wraps grouped content in the style's card. `list` cards have no vertical padding so their
    /// rows' separators run edge to edge (the first one is tucked under the top edge).
    func lookCard(list: Bool = false, padding: CGFloat = Space.lg) -> some View {
        modifier(LookCard(list: list, padding: padding))
    }
}

/// Spatial is always dark; the other styles follow the Mac.
struct ForcedDark: ViewModifier {
    func body(content: Content) -> some View {
        if Look.forcesDark { content.environment(\.colorScheme, .dark) } else { content }
    }
}

struct LookCard: ViewModifier {
    var list: Bool
    var padding: CGFloat

    func body(content: Content) -> some View {
        if Look.isAtelier {
            content
        } else {
            let shape = RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous)
            content
                .padding(.top, list ? -1 : padding)
                .padding(.bottom, list ? 0 : padding)
                .padding(.horizontal, padding)
                .background { LookSurface(shape: shape) }
                .clipShape(shape)
                .modifier(ClayShadow())
        }
    }
}

/// A container fill in the current style: tonal (Material), raised (Clay) or glass (Spatial).
struct LookSurface<S: InsettableShape>: View {
    var shape: S
    var inset = false

    var body: some View {
        switch Look.style {
        case .clay where inset:
            shape.fill(Look.background
                .shadow(.inner(color: Color.adaptive(hex: 0x7864B4, dark: 0x000000).opacity(0.22), radius: 8, x: 5, y: 5))
                .shadow(.inner(color: Color.white.opacity(0.9), radius: 8, x: -5, y: -5)))
        case .spatial:
            shape.fill(inset ? Color.black.opacity(0.16) : Look.container)
                .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        case .material where !inset:
            ZStack { shape.fill(Look.container); shape.fill(Theme.start.opacity(0.03)) }
        default:
            shape.fill(Look.container)
        }
    }
}

/// Clay's soft double shadow: a dark one down-right and a light one up-left.
struct ClayShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        if Look.style == .clay {
            content
                .shadow(color: (scheme == .dark ? Color.black : Color(red: 0.47, green: 0.39, blue: 0.7)).opacity(scheme == .dark ? 0.45 : 0.18),
                        radius: 10, x: 6, y: 6)
                .shadow(color: Color.white.opacity(scheme == .dark ? 0.04 : 0.9), radius: 8, x: -5, y: -5)
        } else {
            content
        }
    }
}

// MARK: Text and rules

/// A section label: spaced capitals in Atelier, a quiet label elsewhere.
struct Kicker: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Group {
            switch Look.style {
            case .atelier:
                Text(text.uppercased()).font(.system(size: 10.5, weight: .medium)).tracking(2.2).foregroundStyle(Look.muted)
            case .material:
                Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accentText)
            case .clay:
                Text(text).font(.system(size: 12, weight: .bold)).foregroundStyle(Look.muted)
            case .spatial:
                Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Look.muted)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A decorative one-pixel rule. Only Atelier draws it; the other styles use space and cards.
struct Hairline: View {
    var body: some View {
        if Look.isAtelier {
            Rectangle().fill(Look.hairline).frame(height: 1).accessibilityHidden(true)
        }
    }
}

/// The line between rows of a list.
struct RowSeparator: View {
    var body: some View {
        Rectangle().fill(Look.hairline).frame(height: 1).accessibilityHidden(true)
    }
}

// MARK: Buttons and toggles

/// The main action. Atelier: a crisp block in spaced capitals. Material: a filled tonal block.
/// Clay: a puffy pill. Spatial: a glowing pill in the theme's second color.
struct PrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Content(configuration: configuration) }

    private struct Content: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let style = Look.style
            let fill = style == .spatial ? Theme.end : Theme.primaryButton
            let ink = style == .spatial ? Color.black : Theme.onPrimaryButton
            let radius: CGFloat = switch style {
            case .atelier: 3
            case .material: 16
            default: 100
            }
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            label(style)
                .foregroundStyle(ink)
                .padding(.horizontal, style == .atelier ? 20 : 22)
                .padding(.vertical, style == .material ? 14 : 12)
                .background {
                    shape.fill(fill)
                        .overlay(shape.fill(Color.white.opacity(hovering && isEnabled ? 0.12 : 0)))
                        .overlay(shape.fill(Color.black.opacity(configuration.isPressed ? 0.15 : 0)))
                        .overlay {
                            if style == .clay {
                                shape.fill(Color.clear
                                    .shadow(.inner(color: .white.opacity(0.45), radius: 4, y: 3))
                                    .shadow(.inner(color: .black.opacity(0.2), radius: 4, y: -3)))
                            }
                        }
                }
                .shadow(color: style == .spatial ? Theme.end.opacity(isEnabled ? 0.45 : 0) : .clear, radius: 14)
                .shadow(color: style == .material ? Color.black.opacity(isEnabled ? 0.18 : 0) : .clear, radius: 4, y: 2)
                .shadow(color: style == .clay ? Theme.primaryButton.opacity(isEnabled ? 0.35 : 0) : .clear, radius: 10, x: 4, y: 6)
                .opacity(isEnabled ? 1 : 0.38)
                .contentShape(shape)
                .onHover { hovering = $0 }
                .motion(Motion.fast, value: hovering)
        }

        @ViewBuilder private func label(_ style: LookStyle) -> some View {
            if style == .atelier {
                configuration.label.font(.system(size: 11.5, weight: .semibold)).tracking(1.8).textCase(.uppercase)
            } else {
                configuration.label.font(.system(size: 14, weight: style == .clay ? .heavy : .semibold))
            }
        }
    }
}

/// A secondary action. Atelier: underlined spaced capitals. Material: an outlined pill.
/// Clay: a raised pill. Spatial: a frosted pill.
struct SecondaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Content(configuration: configuration) }

    private struct Content: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Group {
                switch Look.style {
                case .atelier:
                    configuration.label
                        .font(.system(size: 11.5, weight: .semibold)).tracking(1.8).textCase(.uppercase)
                        .foregroundStyle(hovering && isEnabled ? Look.muted : Look.ink)
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(hovering && isEnabled ? Look.muted : Look.ink).frame(height: 1)
                        }
                case .material:
                    configuration.label
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accentText)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(Theme.accentText.opacity(hovering && isEnabled ? 0.08 : 0)))
                        .overlay(Capsule().strokeBorder(Look.muted.opacity(0.7), lineWidth: 1))
                case .clay:
                    configuration.label
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Capsule().fill(hovering && isEnabled ? Look.background : Look.container))
                        .modifier(ClayShadow())
                case .spatial:
                    configuration.label
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Capsule().fill(Color.white.opacity(hovering && isEnabled ? 0.22 : 0.14)))
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.38)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .motion(Motion.fast, value: hovering)
        }
    }
}

/// The style's switch.
struct LookToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: { Switch(on: configuration.isOn) }
            .buttonStyle(.plain)
            .motion(Motion.fast, value: configuration.isOn)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }

    private struct Switch: View {
        var on: Bool

        var body: some View {
            switch Look.style {
            case .atelier:
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? Theme.primaryButton : Color.clear)
                        .overlay(Capsule().strokeBorder(on ? Color.clear : Look.ink, lineWidth: 1))
                        .frame(width: 32, height: 18)
                    Circle().fill(on ? Theme.end : Look.ink).frame(width: 12, height: 12).padding(.horizontal, 3)
                }
            case .material:
                // Material 3: outlined track and small handle off, filled track and big handle on.
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? Theme.primaryButton : Look.container)
                        .overlay(Capsule().strokeBorder(on ? Color.clear : Look.muted, lineWidth: 2))
                        .frame(width: 46, height: 28)
                    Circle().fill(on ? Theme.onPrimaryButton : Look.muted)
                        .frame(width: on ? 20 : 14, height: on ? 20 : 14)
                        .overlay { if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.primaryButton) } }
                        .padding(.horizontal, on ? 4 : 7)
                }
            case .clay:
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill((on ? Theme.end : Look.background)
                        .shadow(.inner(color: .black.opacity(0.18), radius: 3, x: 2, y: 2)))
                        .frame(width: 40, height: 24)
                    Circle().fill(Color.white).frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.18), radius: 2, x: 1, y: 1)
                        .padding(.horizontal, 3)
                }
            case .spatial:
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? Theme.end : Color.white.opacity(0.2)).frame(width: 42, height: 26)
                    Circle().fill(Color.white).frame(width: 22, height: 22).padding(.horizontal, 2)
                }
            }
        }
    }
}

// MARK: Rows and status

/// A settings line: label on the left, a control on the right, with a separator above.
struct SettingRow<Trailing: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            RowSeparator()
            HStack(alignment: .center, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Look.ink)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Look.muted) }
                }
                Spacer(minLength: Space.md)
                trailing()
            }
            .padding(.vertical, Look.isAtelier ? 11 : 12)
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

/// Fine diagonal hatching, used inside Atelier's drop zone.
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

/// Light / Dark / System. Spatial is always dark, so the choice waits until another style is picked.
struct ColorModePicker: View {
    @Bindable var settings: DroprrSettings

    var body: some View {
        Picker("Mode", selection: $settings.colorMode) {
            Text("Light").tag("light")
            Text("Dark").tag("dark")
            Text("System").tag("system")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(Look.forcesDark)
    }
}

/// The style picker for Settings: one tile per style with a tiny preview.
struct StylePicker: View {
    @Bindable var settings: DroprrSettings

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: Space.md)], spacing: Space.md) {
            ForEach(LookStyle.allCases) { style in
                let selected = style.rawValue == settings.style
                Button { Motion.perform { settings.style = style.rawValue } } label: {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        StyleSwatch(style: style).frame(height: 54)
                        Text(style.name).font(.system(size: 13, weight: selected ? .semibold : .regular))
                        Text(style.detail).font(.system(size: 10.5)).foregroundStyle(Look.muted).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Space.sm)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Theme.secondaryTint.opacity(Look.forcesDark ? 0.25 : 1) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected ? Theme.secondaryText : Look.hairline, lineWidth: selected ? 2 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(style.name) style")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// A small drawing of each style, using the current theme's colors.
private struct StyleSwatch: View {
    var style: LookStyle

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            switch style {
            case .material:
                RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0xF1F2EA))
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.secondaryTint).frame(width: 26, height: 18)
                    RoundedRectangle(cornerRadius: 6).fill(Theme.primaryButton).frame(width: 34, height: 18)
                }.padding(8)
            case .clay:
                RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xEFEAF9))
                HStack(spacing: 6) {
                    Capsule().fill(Color.white).frame(width: 26, height: 18).shadow(color: .purple.opacity(0.25), radius: 3, x: 2, y: 2)
                    Capsule().fill(Theme.primaryButton).frame(width: 34, height: 18).shadow(color: .black.opacity(0.2), radius: 3, x: 2, y: 2)
                }.padding(8)
            case .spatial:
                RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [Color(hex: 0x6F665A), Color(hex: 0x3B4249)], startPoint: .topLeading, endPoint: .bottomTrailing))
                HStack(spacing: 4) {
                    Capsule().fill(Color.white.opacity(0.25)).frame(width: 26, height: 18)
                    Capsule().fill(Theme.end).frame(width: 34, height: 18).shadow(color: Theme.end.opacity(0.6), radius: 5)
                }.padding(8)
            case .atelier:
                Rectangle().fill(Color(hex: 0xFBFAF6)).overlay(Rectangle().strokeBorder(Color(hex: 0xE6E1D6)))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aa").font(.system(size: 16, design: .serif)).foregroundStyle(Color(hex: 0x1C1B19))
                    Rectangle().fill(Theme.primaryButton).frame(width: 40, height: 12)
                }.padding(8)
            }
        }
        .accessibilityHidden(true)
    }
}

/// WCAG contrast helpers, matching the Windows app's LookDef.EnsureContrast step for step.
enum Contrast {
    /// Spatial's glass card over the room's lightest corner, flattened.
    static let spatialTile: UInt32 = 0x645E56

    /// `color` moved toward black or white in 4% steps until it has `ratio` contrast with `background`.
    static func ensure(_ color: UInt32, on background: UInt32, ratio: Double = 4.5) -> UInt32 {
        var c = rgb(color)
        let bg = rgb(background)
        let target: (Int, Int, Int) = luminance(bg) > 0.18 ? (0, 0, 0) : (255, 255, 255)
        var i = 0
        while i < 50 && contrast(c, bg) < ratio {
            c = (blend(c.0, target.0), blend(c.1, target.1), blend(c.2, target.2))
            i += 1
        }
        return UInt32(c.0) << 16 | UInt32(c.1) << 8 | UInt32(c.2)
    }

    private static func blend(_ a: Int, _ b: Int) -> Int { Int(Double(a) + Double(b - a) * 0.04) }
    private static func rgb(_ v: UInt32) -> (Int, Int, Int) { (Int(v >> 16 & 0xFF), Int(v >> 8 & 0xFF), Int(v & 0xFF)) }

    private static func luminance(_ c: (Int, Int, Int)) -> Double {
        func channel(_ v: Int) -> Double {
            let x = Double(v) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
    }

    private static func contrast(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

#if os(iOS)
extension View {
    /// A Done button above the keyboard, since the number pad has no return key.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { dismissKeyboard() }.fontWeight(.semibold)
            }
        }
    }
}

/// Ends editing in whatever field has the keyboard (extensions can't reach UIApplication.shared, so it's looked up).
@MainActor
func dismissKeyboard() {
    let app = UIApplication.value(forKey: "sharedApplication") as? UIApplication
    app?.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
#endif

#if os(iOS)
import UIKit

extension Look {
    /// The style's display font for navigation titles too (Received, Settings and every sheet), so each screen's
    /// title matches the Send screen's.
    static func applyNavigationFonts() {
        func font(_ size: CGFloat) -> UIFont {
            let weight: UIFont.Weight
            var design: UIFontDescriptor.SystemDesign = .default
            switch style {
            case .material: weight = .regular
            case .clay: weight = .heavy; design = .rounded
            case .spatial: weight = .bold
            case .atelier: weight = .regular; design = .serif
            }
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: size) } ?? base
        }
        let large: [NSAttributedString.Key: Any] = [.font: font(34)]
        let small: [NSAttributedString.Key: Any] = [.font: font(17)]
        let proxy = UINavigationBar.appearance()
        proxy.largeTitleTextAttributes = large
        proxy.titleTextAttributes = small
        // Bars already on screen don't follow the proxy: update them in place.
        func visit(_ view: UIView) {
            if let bar = view as? UINavigationBar {
                bar.largeTitleTextAttributes = large
                bar.titleTextAttributes = small
            }
            view.subviews.forEach(visit)
        }
        let app = UIApplication.value(forKey: "sharedApplication") as? UIApplication
        for case let scene as UIWindowScene in app?.connectedScenes ?? [] {
            scene.windows.forEach(visit)
        }
    }
}
#endif
