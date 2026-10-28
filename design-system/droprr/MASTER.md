# Droprr design system

The single source of truth for how Droprr looks on Windows, Mac, and iPhone. Platform code (`src/` for Windows, `apple/` for Mac and iPhone) should take its colors, type, spacing, and corner radii from here. Machine-readable values are in [`tokens.json`](tokens.json).

Page-specific overrides go in `pages/<page>.md` and win over this file for that page only.

## Principles

1. **Native first, brand second.** Each app should feel built in to its OS. Let the platform supply surfaces and materials (Mica on Windows, window and popover materials on the Mac, grouped backgrounds on iPhone), system text colors, and standard controls. The brand shows up through the accent and the gradient, in a few deliberate places.
2. **Same roles, platform-native values.** Windows, Mac, and iPhone match by *role* (an accent button, a card, a caption), not by identical pixel values. A card is 8 px on Windows and 12 pt on Apple because that is what each OS does.
3. **Soft and rounded.** Rounded corners everywhere and no hard-cornered classic menus or boxes. Soft tinted fills instead of heavy borders.
4. **Calm motion.** Short, subtle transitions that explain state changes, never decoration.

Style direction: *Minimalism and Swiss style* (clean, functional, high contrast, grid-based), from the ui-ux-pro-max design-system search. Its web-specific suggestions (Inter, a teal palette) were replaced with Droprr's icon colors and each platform's system font.

## Color

### Brand

| Token | Value | Use |
|---|---|---|
| `brand.violet` | `#5C21F7` | Accent color on every platform: primary buttons, selection, links, focus, accent icons. White text on it is 7.0:1. |
| `brand.coral` | `#FF5E5C` | Second gradient stop and progress bars. **Never text on a light background** (3.0:1 on white). |
| `brand.gradient` | `#5C21F7` → `#FF5E5C`, top-leading to bottom-trailing (135°) | Logo badge, primary button fill on Apple, filled device glyphs, success check. Small surfaces only. |

The Windows code currently uses `#591FFA`. It should move to `#5C21F7` so all three apps match exactly. The difference is barely visible, but one value is easier to keep in sync.

### Derived accent values

| Token | Light | Dark | Use |
|---|---|---|---|
| `accent.text` | `#5C21F7` (6.5:1 on `#F7F6FB`) | `#A98BFF` (6.4:1 on `#1C1B22`) | Accent-colored text and icons on plain backgrounds |
| `accent.tint` | violet at 12% | violet at 20% | Unfilled glyph circles, selected rows, soft chips |
| `accent.hover` | white overlay 18% on accent | same | Hover on filled accent buttons |
| `accent.pressed` | black overlay 15% on accent | same | Pressed state on filled accent buttons |

### Neutrals and semantic colors

Use the platform's own values. Don't hard-code grays.

| Role | Windows (WPF UI resource) | Apple (SwiftUI) |
|---|---|---|
| Primary text | `TextFillColorPrimaryBrush` | `.primary` |
| Secondary text | `TextFillColorSecondaryBrush` | `.secondary` |
| Card fill | `CardBackgroundFillColorDefaultBrush` | `.background.secondary` |
| Card / divider stroke | `CardStrokeColorDefaultBrush` | `Color.primary.opacity(0.08)` |
| Hover fill (plain) | `SubtleFillColorSecondaryBrush` | `Color.primary.opacity(0.06–0.09)` |
| Success | `SystemFillColorSuccessBrush` | `.green` |
| Error | `SystemFillColorCriticalBrush` | `.red` |
| QR code plate | White in both themes | White in both themes |

## Bento themes

Droprr's look is the **Bento Grid**: the window or screen is a light-gray (or charcoal) surface, and everything sits on rounded tiles of mixed sizes with a 12-pt gap. There are six color themes. The user picks one in Settings (Appearance); **Graphite & Lime** (`graphiteLime`) is the default. Every theme has a light and a dark variant that follows the OS appearance. Exact values for every role are in [`tokens.json`](tokens.json) under `themes`.

| ID | Name | Light accent / secondary | Dark accent / secondary |
| --- | --- | --- | --- |
| `graphiteLime` | Graphite & Lime | `#1F2024` / `#A3E635` | `#E9EAEE` / `#A3E635` |
| `sunset` | Sunset | `#E8590C` / `#7048E8` | `#FF7A30` / `#9B7BFF` |
| `cherry` | Cherry | `#D6293E` / `#0F9D8F` | `#F0475A` / `#2DD4BF` |
| `roseGold` | Rose Gold | `#C2577A` / `#C9973A` | `#E07A9C` / `#E0B25A` |
| `sage` | Sage | `#6B8F71` / `#C8704A` | `#8FB596` / `#E08A63` |
| `oliveMustard` | Olive & Mustard | `#5E6B2B` / `#D9A520` | `#A3B25A` / `#E8B93A` |

### Roles

| Role | Use |
| --- | --- |
| `surface` | Window or screen background behind the tiles. |
| `tile` | Every tile: device cards, the drop area, settings sections, list rows. |
| `border` | Hairline tile outline and dividers. |
| `accent` / `onAccent` | The **selected** tile (selected device, selected action), toggles, the app glyph tile. Text and icons on it use `onAccent`. |
| `accentTint` / `accentText` | Unselected icon wells (rounded squares behind glyphs), links, small accent text. |
| `secondary`, `secondaryTint`, `secondaryText` | One contrasting tile per screen: the message/text tile and "N waiting" badges. Icon well filled with `secondary`. |
| `primaryButton` / `onPrimaryButton` | The main action (Send, Pair a Phone): near-black in light mode, the accent in dark mode. |
| `textPrimary`, `textSecondary` | Text on `surface` and `tile`. Platforms may use their native label colors if they match. |
| `successFill`, `successText` (under `bento`) | The "Sent" status tile. |

### Layout

- **Send screen:** title row; "Send to" device tiles in a row (selected one filled with `accent`); below, a large drop tile on the left and the `secondary` message tile on the right; status tile; bottom bar with a secondary button on the left and the primary Send button on the right.
- **Settings:** a "This device" hero tile (name, status chips, Pair a Phone), then Devices, Receiving, Token and **Appearance** tiles. Appearance shows six swatches (accent + secondary dots) with the current one ringed.
- **Phone Send:** device chips; an action grid with Photos as a tall tile and Clipboard and Files stacked beside it; text tile; status tile; full-width primary Send button above the tab bar.
- Tiles have no drop shadow beyond a 1-px `border` (light) and no gradients. The brand violet/coral gradient remains only in the app icon and logo.

## Typography

System fonts only: **Segoe UI Variable** on Windows (WPF UI's default) and **SF Pro** on Apple. No bundled or web fonts.

| Role | Windows (px, weight) | Mac / iPhone (text style) | Use |
|---|---|---|---|
| Title | 28, SemiBold | `.title2` (iPhone `.largeTitle` via navigation title) | Window or screen title |
| Subtitle | 20, SemiBold | `.title3.weight(.semibold)` | Pair window heading, result headline |
| Body strong | 14, SemiBold | `.headline` | Device names, section headers |
| Body | 14, Regular | `.body` / `.callout` | Default text |
| Caption | 12, Regular, secondary color | `.caption` / `.caption2`, secondary | Hints, timestamps, metadata |
| Mono | Cascadia Mono 12 | `.caption.monospaced()` | Addresses, ports, codes |

Windows sizes stay on Fluent's ramp (12, 14, 20, 28). Replace one-off sizes (13, 15, 16, 24) with the nearest role. On iPhone, always use text styles so Dynamic Type works. Never use fixed point sizes for text.

## Spacing

A 4-point grid. Use only these steps: **4, 8, 12, 16, 24, 32**.

| Token | Value | Typical use |
|---|---|---|
| `space.xs` | 4 | Icon to label, tight stacks |
| `space.sm` | 8 | Between related controls, list row inner gaps |
| `space.md` | 12 | Card inner padding (compact), row padding |
| `space.lg` | 16 | Card padding, gap between cards, Mac panel padding |
| `space.xl` | 24 | Windows window padding, section gaps |
| `space.xxl` | 32 | Large empty-state padding |

On iPhone, use the system layout margins for screen edges instead of fixed values.

## Corner radius

| Role | Windows | Mac | iPhone | Examples |
|---|---|---|---|---|
| Small control | 4 (WPF UI default) | 6 | system | Icon buttons, chips |
| Button | 4 (WPF UI default) | 7 | system (capsule or rounded) | Send, Pair, Settings buttons |
| List row / hover | 4 | 8 | system list | Recent items, device rows |
| Card | 8 | 12 | 12 | Drop zone, device tiles, panels |
| Feature surface | 12 | 14 | 14 | QR plate, large device cards |

Apple shapes always use `style: .continuous`. Windows windows keep the OS's own rounded corners (don't draw custom chrome).

## Iconography

- **App icon:** the colored icon from `file-swap-icon-pack/` everywhere, including the Windows tray and the Mac menu bar. Don't use the monochrome or template variants.
- **UI glyphs:** Fluent System Icons via WPF UI `SymbolIcon` on Windows, SF Symbols on Apple. No emoji as icons.
- **Shared meanings:**

| Meaning | Windows symbol | SF Symbol |
|---|---|---|
| iPhone | `Phone24` | `iphone` |
| Mac | `Laptop24` | `laptopcomputer` |
| Windows PC | `Desktop24` | `pc` |
| Text | `TextAlignLeft24` | `text.alignleft` |
| Link | `Link24` | `link` |
| Photo | `Image24` | `photo` |
| File | `Document24` | `doc` |
| Receive | `ArrowDownload24` | `arrow.down.circle` |
| Send | `Send24` | `paperplane` |
| Success | `CheckmarkCircle48` (filled) | `checkmark.circle.fill` |

Device glyphs sit in a circle: `accent.tint` fill with an accent glyph normally, gradient fill with a white glyph when selected or active.

## Motion

| Token | Value | Use |
|---|---|---|
| `motion.fast` | 120 ms, ease-out | Hover and press feedback |
| `motion.standard` | 200 ms, ease-out | Panels, rows appearing, status text |
| `motion.slow` | 300 ms, ease-out | Pairing success, large transitions |

Exits are faster than entrances. Animate opacity and transforms, not size. Respect Reduce Motion (Apple) and "Animation effects" off (Windows) by showing the final state immediately.

## Accessibility (must-haves)

- Text contrast at least 4.5:1, large text and icons at least 3:1. The accent values above already pass in both themes.
- Visible keyboard focus on Windows and Mac. Don't remove focus rings.
- Tap targets at least 44 × 44 pt on iPhone. Windows controls keep WPF UI's 32 px minimum height.
- Every icon-only button has an accessible name (`AutomationProperties.Name` on Windows, `.accessibilityLabel` on Apple).
- Don't use color alone to show state. Pair it with an icon or text.
- Support Windows high-contrast mode by using WPF UI theme resources rather than fixed colors.

## Anti-patterns

- Hard-cornered menus, boxes, or classic Win32-style controls.
- Coral text on light backgrounds, or the gradient on large backgrounds.
- Hard-coded grays or one-off hex colors in views. Use the tokens or platform resources.
- Monochrome tray or menu-bar icons.
- Confirmation dialogs for actions that are easy to undo, like clearing the waiting queue.
- Behavior that differs between platforms without a platform reason.

## Pre-delivery checklist

- [ ] Accent is `#5C21F7` (light) / `#A98BFF` for accent text in dark.
- [ ] Looks right in both light and dark mode.
- [ ] Only spacing steps 4, 8, 12, 16, 24, 32.
- [ ] Corner radii match the role table for the platform.
- [ ] Text uses the type roles (Fluent ramp on Windows, text styles on Apple).
- [ ] Hover and pressed states on every clickable element on Windows and Mac.
- [ ] Focus visible, accessible names on icon buttons, 44 pt targets on iPhone.
- [ ] Reduce Motion respected.
