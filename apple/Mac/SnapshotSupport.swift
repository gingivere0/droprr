#if DEBUG
import SwiftUI

/// Debug builds only: `DROPRR_SNAPSHOT=<dir>` renders the Send window, Settings, the panel and Pair a phone to PNGs
/// so layout can be checked without a screen, then quits.
@MainActor
enum SnapshotSupport {
    static func runIfRequested(model: MacModel) {
        dumpWindowsIfRequested()
        guard let dir = ProcessInfo.processInfo.environment["DROPRR_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {   // time for the host page, for the one code
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .light ? "light" : "dark"
                render(SendView(model: model), to: "\(dir)/send-\(suffix).png", scheme: scheme)
                render(MacSettingsView(model: model).content.frame(width: 580).lookRoot(), to: "\(dir)/settings-\(suffix).png", scheme: scheme)
                render(PanelView(model: model), to: "\(dir)/panel-\(suffix).png", scheme: scheme)
                render(PairView(model: model).lookRoot(), to: "\(dir)/pair-\(suffix).png", scheme: scheme)
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
extension SnapshotSupport {
    /// `DROPRR_WINDOW_DUMP=<file>` opens Settings, then writes each window's view tree
    /// (class, frame, opacity, layer color) so window chrome can be checked without a screen.
    static func dumpWindowsIfRequested() {
        guard let file = ProcessInfo.processInfo.environment["DROPRR_WINDOW_DUMP"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {   // time for the host page, for the one code
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            // Also open the menu bar popup, so its window shows up in the dump.
            func buttons(_ view: NSView) -> [NSStatusBarButton] {
                ((view as? NSStatusBarButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
            }
            for window in NSApp.windows {
                if let frame = window.contentView?.superview ?? window.contentView { buttons(frame).first?.performClick(nil) }
            }
        }
        if ProcessInfo.processInfo.environment["DROPRR_WINDOW_DUMP_CLOSE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { closeMenuBarPanel() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            var out = "key window: \(String(describing: NSApp.keyWindow.map { type(of: $0) }))\n"
            func walk(_ view: NSView, _ depth: Int) {
                let fx = (view as? NSVisualEffectView).map { " material=\($0.material.rawValue) blend=\($0.blendingMode.rawValue)" } ?? ""
                out += String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame) hidden=\(view.isHidden) opaque=\(view.isOpaque) alpha=\(view.alphaValue) layerBg=\(String(describing: view.layer?.backgroundColor))\(fx)\n"
                for sub in view.subviews { walk(sub, depth + 1) }
            }
            for window in NSApp.windows where window.isVisible {
                if let button = (window.contentView?.superview).flatMap({ view -> NSStatusBarButton? in
                    func find(_ v: NSView) -> NSStatusBarButton? { (v as? NSStatusBarButton) ?? v.subviews.lazy.compactMap(find).first }
                    return find(view)
                }) { out += "status button highlighted=\(button.isHighlighted) state=\(button.state.rawValue)\n" }
                out += "WINDOW \(type(of: window)) '\(window.title)' opaque=\(window.isOpaque) bg=\(String(describing: window.backgroundColor)) transparentTitle=\(window.titlebarAppearsTransparent) style=\(window.styleMask.rawValue) toolbar=\(String(describing: window.toolbar)) appearance=\(String(describing: window.appearance?.name))\n"
                if let frame = window.contentView?.superview { walk(frame, 1) }
            }
            try? out.write(toFile: file, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
#endif
