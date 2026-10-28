# File Swap icon pack

File Swap is a descriptive label for this logo concept, not an assigned app name.

## Use these first

| Purpose | File | Sizes |
| --- | --- | --- |
| Windows executable, shortcuts, taskbar | windows/app.ico | Embedded 16, 20, 24, 32, 40, 48, 64, 128, 256 px |
| Windows notification tray | windows/tray/black.ico or white.ico | Embedded 16 through 64 px; PNG alternatives included |
| Mac app / Dock | macos/app.icns | 16 through 1024 px representations |
| Mac Xcode app icon | macos/AppIcon.appiconset | 1x / 2x catalog |
| Mac menu bar | macos/menu-bar/TrayTemplate.png and TrayTemplate@2x.png | 18 and 36 px |
| iPhone / App Store | ios/AppIcon.appiconset | Opaque 1024 px source, system applies corner mask |
| Website favicon | web/favicon.ico | 16, 32, 48 px |
| Website / PWA | web/icon-192.png and icon-512.png | Transparent PNG |
| Add to Home Screen | web/apple-touch-icon.png | Opaque 180 px |
| Marketing / in-app branding | brand/logo-transparent-1024.png | Transparent 1024 px |
| Monochrome branding | brand/logo-black-1024.png or logo-white-1024.png | Transparent 1024 px |

## Integration notes

- Windows: choose black tray artwork for light backgrounds and white for dark backgrounds. Select the PNG matching the actual rendered pixel size / display scaling, or let the native icon loader select a representation from the ICO.
- macOS: mark the menu bar image as a template (`NSImage.isTemplate = true`; Electron: `nativeImage.setTemplateImage(true)`). The system uses its alpha mask to adapt to the menu bar appearance. Keep the 1x and @2x files together.
- Xcode: copy the relevant AppIcon.appiconset folder into your platform's Assets.xcassets, selecting it as the app icon. The iOS catalog uses the single-size source workflow; optional older iPhone sizes are in ios/optional-sizes.
- iPhone: the background is deliberately opaque. Do not add rounded outer corners to the source image; the OS supplies them.
- Web: replace YOUR_APP_NAME in site.webmanifest and set its start_url to your app's route. Link favicon.ico, apple-touch-icon.png, and site.webmanifest from your HTML head.
- All dimensions refer to pixels. Small tray versions use simplified monochrome artwork, with the same document and transfer-arrow motif.

## Scope

This is a raster asset pack based on the approved second concept, including a separately generated monochrome adaptation. It contains PNG, ICO and ICNS, not editable vector paths. Enlarging beyond the 1024 px master does not add detail. Native layered Icon Composer assets, platform-specific Store screenshots, installer artwork and an MSIX manifest are not included; these depend on the app's build and publishing setup. The flat assets are ready to integrate into conventional app icon workflows.

## Reference guidance

- Apple asset catalogs: https://developer.apple.com/documentation/xcode/configuring-your-app-icon
- Apple app icon design: https://developer.apple.com/design/human-interface-guidelines/app-icons
- Windows icon resources: https://learn.microsoft.com/en-us/windows/win32/menurc/about-icons

The preview shows the actual supplied assets and small tray sizes on light and dark backgrounds.
