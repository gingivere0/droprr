import AppKit
import SwiftUI

/// Hides the window's title bar strip so the content (and its glow) runs to the top edge.
/// The close/minimize buttons stay; content leaves room for them.
struct SeamlessTitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        AppDelegate.hideTitleBar(window)
    }
}

extension View {
    /// Seamless title bar plus top room for the window buttons.
    func seamlessWindow() -> some View {
        self
            .padding(.top, Space.lg)
            // The theme surface fills the entire window, edge to edge, so no strip of the default
            // window color shows at the top or bottom.
            .background { Atelier.paper.ignoresSafeArea() }
            .background(SeamlessTitleBar().frame(width: 0, height: 0))
            .ignoresSafeArea(.container, edges: .top)
    }
}
