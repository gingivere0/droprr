# Droprr icons

The Droprr logo (a document with two transfer arrows), as raster art.

| Path | What it is | Used by |
| --- | --- | --- |
| `brand/logo-transparent-1024.png` | The original logo, transparent, 1024 px | `apple/scripts/generate_theme_logos.swift`, which recolors it for each theme |
| `themes/<theme id>/logo-1024.png` | The logo in a theme's colors, transparent | Windows: tray, title bar, and taskbar icons, the shortcuts' icons, and (Graphite & Lime) the exe's icon |
| `themes/<theme id>/app-icon-1024.png` | The logo on an opaque background, for the iPhone home screen | iPhone app icons |
| `themes/<theme id>/menubar.png`, `menubar@2x.png` | Small menu bar versions | Mac menu bar |
| `themes/graphiteLime/mac-icon-1024.png` | The Mac app icon, on a rounded plate | Mac app icon |

The theme folders are generated: run `apple/scripts/generate_theme_logos.swift` after changing the logo or a theme's colors in `design-system/droprr/tokens.json`. Windows builds its multi-size `.ico` files from `logo-1024.png` at build time (`scripts/make-app-icon.ps1`) and at run time.

The earlier platform exports (Windows `.ico` and PNG sets, monochrome tray art, web favicons, and Mac `.icns`) were removed once nothing used them; they're in git history.
