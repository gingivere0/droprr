# QR code style

Every Droprr QR code (a computer's **Pair a phone** code, an iPhone's and a browser's **Show QR code**) is drawn the same way on Windows, Mac, iPhone, and the website. The reference implementation is [`site/qrstyle.js`](../../site/qrstyle.js); the Windows and Apple renderers are ports of it and must stay in step.

## Encoding

- Error correction **Q** (25%), byte mode, the smallest version that fits. With the [short code](../../docs/PROTOCOL.md#one-code) that is version 10, 57 × 57 modules, for a computer.
- The mask is whatever the encoder picks. The style is tuned to scan with any of the eight masks.

## Drawing

Coordinates are in modules, `n` × `n`, with the module at row `r`, column `c` centered on `(c + 0.5, r + 0.5)`.

- **Plate:** white (`qrPlate`), with a quiet zone of at least 3 modules, whatever the light or dark mode.
- **Eyes** (the three 7 × 7 finder patterns): a rounded square of 7 modules with corner radius 2.4, a white rounded square of 5 with radius 1.6, and a rounded square of 3 with radius 1.0, in the **outer** color. Finder modules are never drawn as dots.
- **Dots:** every other dark module is a circle 0.95 modules across, centered on the module.
- **Outline:** the shape in [`qr-outline.json`](qr-outline.json) (points in units of its longest side, centered), scaled so its longest side is `0.8 × n` and centered on the code, then moved `0.07 × n` to the right (about 4 modules at 57 × 57). Most of the shape's area is on its left, so this puts its visual center near the code's center. A dark module whose center is inside the outline is drawn in the **inner** color, and one outside in the **outer** color.
- **Gap:** a dark module whose center is less than **0.5** modules from the outline's edge is left out, so a white line traces the shape, unless it's a **function module**: the finder patterns with their separators and format information (the 9 × 9, 9 × 8, and 8 × 9 corners), the timing row and column 6, the version information (versions 7 and up), and the 5 × 5 alignment patterns. Those are always drawn.

## Colors

From the current theme's **light** palette, in both light and dark mode, since the plate is always white:

| Role | Value |
| --- | --- |
| Outer (eyes and dots outside the outline) | `accent` |
| Inner (dots inside the outline) | `textPrimary`, or `secondaryText` when `accent` is nearly black (relative luminance under 0.05, as with Graphite & Lime) |

With the default Sage theme that's `#557A5C` outside and `#15131C` inside.

## Why these numbers

Dots 0.9 modules across scanned as well as square modules in those tests, but 0.8 failed about one time in five, so keep them at 0.9 or larger.

At error correction Q, leaving out the modules on a 1-module-wide line (about 60 to 90 dark modules out of 1,500) decoded as reliably as the plain code in tests with several decoders, all eight masks, and simulated camera blur and noise. A 1.4-module line failed about twice as often, so keep the gap at 0.5 unless you move to error correction H.
