import AppKit
import SwiftUI

struct MenuContent: View {
    @Bindable var model: MacModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.status)
        if let result = model.lastSendResult {
            Text(result)
        }
        Divider()

        Button("Send…") {
            openWindow(id: "send")
            bringToFront()
        }
        .keyboardShortcut("n")

        Menu("Send Clipboard To") {
            if model.settings.peers.isEmpty {
                Text("Add a device in Settings")
            }
            ForEach(model.settings.peers) { peer in
                Button(peer.name) { Task { await model.send(clipboardTo: peer) } }
            }
        }

        Divider()
        if model.recent.isEmpty {
            Text("Nothing received yet")
        } else {
            Text("Received")
            ForEach(model.recent) { item in
                Button(item.title) { model.open(item) }
            }
        }
        Button("Open Droprr Folder") {
            try? FileManager.default.createDirectory(at: MacModel.inbox, withIntermediateDirectories: true)
            NSWorkspace.shared.open(MacModel.inbox)
        }

        Divider()
        Button("Settings…") {
            openSettings()
            bringToFront()
        }
        .keyboardShortcut(",")
        Button("Quit Droprr") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Menu bar apps aren't active when their menu is used, so new windows open behind the
/// frontmost app. Activate, then raise our windows once SwiftUI has created them.
@MainActor
func bringToFront() {
    NSApp.activate(ignoringOtherApps: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.isVisible && window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}
