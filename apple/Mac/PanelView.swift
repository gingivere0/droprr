import AppKit
import SwiftUI

/// The menu bar popover: status, one tile per device, recent items, and shortcuts.
struct PanelView: View {
    @Bindable var model: MacModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            header
            Hairline()

            if model.settings.peers.isEmpty {
                emptyDevices
            } else {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Kicker("Send to")
                    VStack(spacing: 0) {
                        ForEach(model.settings.peers) { peer in
                            DeviceTile(peer: peer, waiting: model.waiting(for: peer),
                                       onClipboard: { Task { await model.sendClipboard(to: peer) } },
                                       onFiles: { model.chooseFiles(for: peer) },
                                       onClearWaiting: { model.clearWaiting(for: peer) },
                                       onMissingToken: {
                                           model.settings.tokenRequest = peer.id
                                           showSettings()
                                       })
                        }
                    }
                    .lookCard(list: true, padding: 8)
                }
            }

            SendStatusView(message: model.lastSendResult, progress: model.progress, onCancel: model.cancelSend)

            if !model.recent.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Kicker("Received")
                    VStack(spacing: 0) {
                        ForEach(model.recent) { item in
                            RecentRow(item: item, onOpen: { model.open(item) }, onRemove: { model.removeRecent(item) })
                        }
                    }
                    .lookCard(list: true, padding: 8)
                }
            }

            Hairline()
            footer
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(width: 340)
        .foregroundStyle(Look.ink)
        .lookRoot()
        .motion(Motion.standard, value: model.lastSendResult)
    }

    /// Clicking the name and status opens the Send window. If it's open but covered by another
    /// window, it comes to the front; only when it's already on top does a click close it.
    private var header: some View {
        Button {
            if let window = sendWindow, sendWindowIsOnTop(window) {
                dismissWindow(id: "send")
            } else {
                closeMenuBarPanel()
                openWindow(id: "send")
                bringToFront()
            }
        } label: {
            HStack(alignment: .center, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Droprr").font(Look.display(Look.isAtelier ? 24 : 20))
                    HStack(spacing: 7) {
                        StatusDot(on: model.isListening)
                        Text(model.isListening ? "Ready" : model.status)
                            .font(.system(size: 11))
                            .foregroundStyle(Look.muted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                LogoBadge(size: 30)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHint("Open or close the Send window")
    }

    private var sendWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && ($0.identifier?.rawValue.hasPrefix("send") == true || $0.title == "Send with Droprr") }
    }

    /// True when no other app's normal window sits above the Send window (front-to-back screen order).
    private func sendWindowIsOnTop(_ window: NSWindow) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return true }
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            if (info[kCGWindowNumber as String] as? Int) == window.windowNumber { return true }
            // Another app's window is in front of ours.
            if (info[kCGWindowOwnerPID as String] as? Int32) != me { return false }
        }
        return false
    }

    private var emptyDevices: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("No devices yet").font(Look.display(18))
            Text("Add your other devices in Settings to start sending.")
                .font(.system(size: 12))
                .foregroundStyle(Look.muted)
            Button("Open Settings", action: showSettings)
                .buttonStyle(PrimaryStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: Space.lg) {
            FooterButton(title: "Send", help: "Open the Send window (⌘N)", key: "n") {
                closeMenuBarPanel()
                openWindow(id: "send")
                bringToFront()
            }
            FooterButton(title: "Folder", help: "Open the Droprr folder in Downloads (⌘D)", key: "d") {
                try? FileManager.default.createDirectory(at: MacModel.inbox, withIntermediateDirectories: true)
                NSWorkspace.shared.open(MacModel.inbox)
            }
            FooterButton(title: "Pair", help: "Pair a phone or a browser with a QR code (⌘P)", key: "p") {
                closeMenuBarPanel()
                openWindow(id: "pair")
                bringToFront()
            }
            FooterButton(title: "Settings", help: "Settings (⌘,)", key: ",", action: showSettings)
            Spacer()
            FooterButton(title: "Quit", help: "Quit Droprr (⌘Q)", key: "q") { NSApp.terminate(nil) }
        }
    }

    private func showSettings() {
        closeMenuBarPanel()
        openSettings()
        bringToFront()
    }
}

/// A device line: click it to choose files; the icons send the clipboard or files.
private struct DeviceTile: View {
    var peer: Peer
    var waiting: Int
    var onClipboard: () -> Void
    var onFiles: () -> Void
    var onClearWaiting: () -> Void
    var onMissingToken: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            RowSeparator()
            HStack(spacing: Space.md) {
                Image(systemName: Theme.symbol(for: peer))
                    .font(.system(size: 13))
                    .foregroundStyle(hovering ? Look.ink : Look.muted)
                    .frame(width: 18)
                Text(peer.name).font(Look.name(16)).lineLimit(1).layoutPriority(1)
                if !peer.isPaired { MissingTokenButton(compact: true, action: onMissingToken) }
                if waiting > 0 {
                    WaitingBadge(count: waiting, peerName: peer.name, onClear: onClearWaiting)
                }
                Spacer(minLength: Space.sm)
                RowAction(symbol: "doc.on.clipboard", label: "Send what's on the clipboard", action: onClipboard)
                RowAction(symbol: "plus", label: "Choose files to send", action: onFiles)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, Space.xs)
        }
        .background(hovering ? Theme.secondaryTint.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        // Clicking anywhere outside the two buttons chooses files to send.
        .onTapGesture(perform: onFiles)
        .onHover { hovering = $0 }
        .motion(Motion.fast, value: hovering)
    }
}

/// "3 waiting ×": clicking clears the items queued for a phone.
struct WaitingBadge: View {
    var count: Int
    var peerName: String
    var onClear: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onClear) {
            HStack(spacing: 4) {
                Circle().fill(Theme.end).frame(width: 5, height: 5)
                Text("\(count) waiting")
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11))
            .foregroundStyle(hovering ? Look.ink : Look.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverHint("Clear the \(count) item\(count == 1 ? "" : "s") waiting for \(peerName)")
    }
}

/// A received item, like Chrome's downloads list: click the row to open it; the buttons copy it,
/// show it in Finder (files only) or remove it from the list (the file itself is kept).
private struct RecentRow: View {
    var item: ReceivedItem
    var onOpen: () -> Void
    var onRemove: () -> Void
    @State private var hovering = false

    private var file: URL? {
        if case .file(let url) = item.kind { return url }
        return nil
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            Button(action: onOpen) {
                HStack(spacing: Space.md) {
                    Image(systemName: Theme.symbol(for: item))
                        .font(.system(size: 13))
                        .foregroundStyle(Look.muted)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                        Text(item.subtitle).font(.system(size: 11)).foregroundStyle(Look.muted)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHint(openHint)

            RowAction(symbol: "doc.on.doc", label: "Copy") { Clipboard.copy(item) }
            if let file {
                RowAction(symbol: "folder", label: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
            }
            RowAction(symbol: "xmark", label: "Remove from list", action: onRemove)
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 8)
        .background(hovering ? Theme.secondaryTint.opacity(0.6) : .clear)
        .overlay(alignment: .top) { RowSeparator() }
        .onHover { hovering = $0 }
    }

    private var openHint: String {
        switch item.kind {
        case .file: return "Open"
        case .url: return "Open the link"
        case .text: return "Copy the text"
        }
    }
}

private struct RowAction: View {
    var symbol: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).frame(width: 18, height: 18)
        }
        .buttonStyle(HoverButtonStyle(.plain))
        .foregroundStyle(Look.muted)
        .accessibilityLabel(label)
        .hoverHint(label)
    }
}

/// A footer action as small spaced capitals.
private struct FooterButton: View {
    var title: String
    var help: String
    var key: KeyEquivalent
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(Look.isAtelier ? title.uppercased() : title)
                .font(.system(size: Look.isAtelier ? 10 : 12, weight: Look.isAtelier ? .semibold : .medium))
                .tracking(Look.isAtelier ? 1.5 : 0)
                .foregroundStyle(hovering ? Look.ink : Look.muted)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .keyboardShortcut(key)
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
        for window in NSApp.windows where window.isVisible && window.canBecomeKey && !isMenuBarPanel(window) {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

/// The menu bar popup's own window (SwiftUI's MenuBarExtra panel).
@MainActor
private func isMenuBarPanel(_ window: NSWindow) -> Bool {
    String(describing: type(of: window)).contains("MenuBarExtra")
}

/// Hides the menu bar popup, for buttons in it that open another window. Clicking the status item
/// again is what SwiftUI expects, so the icon stops looking pressed and the popup gives up focus.
@MainActor
func closeMenuBarPanel() {
    guard let panel = NSApp.windows.first(where: { isMenuBarPanel($0) && $0.isVisible }) else { return }
    func statusButton(_ view: NSView) -> NSStatusBarButton? {
        (view as? NSStatusBarButton) ?? view.subviews.lazy.compactMap(statusButton).first
    }
    let button = NSApp.windows.lazy.compactMap { window in
        String(describing: type(of: window)).contains("NSStatusBarWindow") ? (window.contentView?.superview).flatMap(statusButton) : nil
    }.first
    if let button {
        button.performClick(nil)
        button.highlight(false)
    }
    if panel.isVisible { panel.close() }
    panel.resignKey()
}
