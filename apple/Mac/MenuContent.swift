import AppKit
import SwiftUI

struct MenuContent: View {
    @Bindable var model: MacModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.status)
        if let result = model.lastSendResult {
            Text(result)
        }
        Divider()

        Button("Send…") {
            openWindow(id: "send")
            NSApp.activate(ignoringOtherApps: true)
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
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")
        Button("Quit Droprr") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
