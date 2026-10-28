#if DEBUG
import SwiftUI

/// Debug builds only: `DROPRR_SNAPSHOT=<dir>` renders the Send window and Settings to PNGs
/// so layout can be checked without a screen, then quits.
@MainActor
enum SnapshotSupport {
    static func runIfRequested(model: MacModel) {
        guard let dir = ProcessInfo.processInfo.environment["DROPRR_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .light ? "light" : "dark"
                render(SendView(model: model), to: "\(dir)/send-\(suffix).png", scheme: scheme)
                render(MacSettingsView(model: model).content.frame(width: 580).lookRoot(), to: "\(dir)/settings-\(suffix).png", scheme: scheme)
                render(PanelView(model: model), to: "\(dir)/panel-\(suffix).png", scheme: scheme)
            }
            NSApp.terminate(nil)
        }
    }

    private static func render<V: View>(_ view: V, to path: String, scheme: ColorScheme) {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96)))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
#endif
