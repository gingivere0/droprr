import SwiftUI

/// Six swatches for the Bento color themes; the current one is ringed. Used in Mac and iPhone Settings.
struct ThemePicker: View {
    @Bindable var settings: DroprrSettings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: Space.md)], spacing: Space.md) {
            ForEach(ThemePalette.all) { palette in
                let selected = palette.id == settings.theme
                let roles = scheme == .dark ? palette.dark : palette.light
                Button {
                    Motion.perform { settings.theme = palette.id }
                } label: {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        HStack(spacing: Space.xs) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(hex: roles.accent))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(Color(hex: roles.onAccent))
                                    }
                                }
                            Circle().fill(Color(hex: roles.secondary)).frame(width: 14, height: 14)
                        }
                        Text(palette.name)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .padding(Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: roles.tile), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color(hex: roles.accent) : Theme.stroke, lineWidth: selected ? 2 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(palette.name) theme")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
