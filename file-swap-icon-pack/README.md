# Droprr icons

The Droprr logo (a document with two transfer arrows), as raster art.

| Path | What it is | Used by |
| --- | --- | --- |
| `brand/logo-transparent-1024.png` | The original logo, transparent, 1024 px | `apple/scripts/generate_theme_logos.swift`, which recolors it for each theme |
| `themes/<theme id>/logo-1024.png` | The logo in a theme's colors, transparent | Windows: tray, title bar, and taskbar icons, the shortcuts' icons, and (Graphite & Lime) the exe's icon |
| `themes/<theme id>/app-icon-1024.png` | The full-bleed app icon: the page fills the square, with the arrows and fold unchanged | iPhone app icons |
| `themes/<theme id>/menubar.png`, `menubar@2x.png` | Small menu bar versions | Mac menu bar |
| `themes/sage/mac-icon-1024.png` | The full-bleed icon on the macOS rounded plate | Mac app icon |

The theme folders are generated: run `apple/scripts/generate_theme_logos.swift` after changing the logo or a theme's colors in `design-system/droprr/tokens.json`, then `python3 scripts/make-app-icons.py` (needs numpy, scipy, and Pillow). The second script builds the app icons and copies them into the iPhone and Mac asset catalogs and `web/icon.png` and `site/icon.png`. Windows builds its multi-size `.ico` files from `logo-1024.png` at build time (`scripts/make-app-icon.ps1`) and at run time.

The earlier platform exports (Windows `.ico` and PNG sets, monochrome tray art, web favicons, and Mac `.icns`) were removed once nothing used them; they're in git history.
