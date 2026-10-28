import AppKit
import SwiftUI

/// The menu bar popover: status, one tile per device, recent items, and shortcuts.
struct PanelView: View {
    @Bindable var model: MacModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if model.settings.peers.isEmpty {
                emptyDevices
            } else {
                sectionTitle("Send to")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(model.settings.peers) { peer in
                        DeviceTile(peer: peer, waiting: model.waiting(for: peer),
                                   onClipboard: { Task { await model.sendClipboard(to: peer) } },
                                   onFiles: { model.chooseFiles(for: peer) },
                                   onClearWaiting: { model.clearWaiting(for: peer) })
                    }
                }
            }

            SendStatusView(message: model.lastSendResult, progress: model.progress)

            if !model.recent.isEmpty {
                sectionTitle("Received")
                VStack(spacing: 2) {
                    ForEach(model.recent) { item in
                        RecentRow(item: item) { model.open(item) }
                    }
                }
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
        .animation(.default, value: model.lastSendResult)
    }

    /// Clicking the logo and status opens the Send window, or closes it if it's already open.
    private var header: some View {
        Button {
            if sendWindowIsOpen {
                dismissWindow(id: "send")
            } else {
                openWindow(id: "send")
                bringToFront()
            }
        } label: {
            HStack(spacing: 10) {
                LogoBadge(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Droprr").font(.headline)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.isListening ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(model.isListening ? "Ready to receive" : model.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HoverButtonStyle(.plain))
        .hoverHint("Open or close the Send window")
    }

    private var sendWindowIsOpen: Bool {
        NSApp.windows.contains { $0.isVisible && ($0.identifier?.rawValue.hasPrefix("send") == true || $0.title == "Send with Droprr") }
    }

    private var emptyDevices: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(Theme.gradient)
            Text("Add your other devices in Settings to start sending.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Settings…", action: showSettings)
                .buttonStyle(HoverButtonStyle(.prominent))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            FooterButton(symbol: "square.and.arrow.up", help: "Open the Send window to drop files or type text") {
                openWindow(id: "send")
                bringToFront()
            }
            FooterButton(symbol: "folder", help: "Open the Droprr folder in Downloads") {
                try? FileManager.default.createDirectory(at: MacModel.inbox, withIntermediateDirectories: true)
                NSWorkspace.shared.open(MacModel.inbox)
            }
            FooterButton(symbol: "qrcode", help: "Pair a phone by scanning a QR code") {
                openWindow(id: "pair")
                bringToFront()
            }
            FooterButton(symbol: "gearshape", help: "Settings: devices, pairing token, launch at login", action: showSettings)
            Spacer()
            FooterButton(symbol: "power", help: "Quit Droprr") { NSApp.terminate(nil) }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }

    private func showSettings() {
        openSettings()
        bringToFront()
    }
}

private struct DeviceTile: View {
    var peer: Peer
    var waiting: Int
    var onClipboard: () -> Void
    var onFiles: () -> Void
    var onClearWaiting: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                GlyphCircle(symbol: Theme.symbol(for: peer), size: 30, filled: hovering)
                Spacer()
                if waiting > 0 {
                    WaitingBadge(count: waiting, peerName: peer.name, onClear: onClearWaiting)
                }
            }
            Text(peer.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                TileAction(symbol: "doc.on.clipboard", label: "Clipboard", action: onClipboard)
                TileAction(symbol: "doc.badge.plus", label: "Files", action: onFiles)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering ? AnyShapeStyle(Theme.start.opacity(0.07)) : AnyShapeStyle(.background.secondary))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.quaternary), lineWidth: 1))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // Clicking anywhere outside the two buttons chooses files to send.
        .onTapGesture(perform: onFiles)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// "3 waiting ×": clicking clears the items queued for a phone.
struct WaitingBadge: View {
    var count: Int
    var peerName: String
    var onClear: () -> Void

    var body: some View {
        Button(action: onClear) {
            HStack(spacing: 3) {
                Text("\(count) waiting")
                Image(systemName: "xmark.circle.fill").opacity(0.7)
            }
            .font(.caption2.weight(.medium))
        }
        .buttonStyle(HoverButtonStyle(.bordered, compact: true))
        .hoverHint("Clear the \(count) item\(count == 1 ? "" : "s") waiting for \(peerName)")
    }
}

private struct TileAction: View {
    var symbol: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity, minHeight: 22)
        }
        .buttonStyle(HoverButtonStyle(.bordered, compact: true))
        .hoverHint(label == "Clipboard" ? "Send what's on the clipboard" : "Choose files to send")
    }
}

private struct RecentRow: View {
    var item: ReceivedItem
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                GlyphCircle(symbol: Theme.symbol(for: item), size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.callout).lineLimit(1)
                    Text(item.subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverHint(hintText)
    }

    private var hintText: String {
        switch item.kind {
        case .file: return "Show in Finder"
        case .url: return "Open the link"
        case .text: return "Copy the text again"
        }
    }
}

private struct FooterButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 24)
                .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .hoverHint(help)
        .onHover { hovering = $0 }
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
