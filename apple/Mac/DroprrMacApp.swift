import AppKit
import ServiceManagement
import SwiftUI

@main
struct DroprrMacApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = MacModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Send with Droprr", id: "send") {
            SendView(model: model)
        }
        .windowResizability(.contentSize)

        Window("Pair a Phone", id: "pair") {
            PairView(model: model)
        }
        .windowResizability(.contentSize)

        Settings {
            MacSettingsView(model: model)
                .onChange(of: model.settings.port) { model.restartIfNeeded() }
        }
    }
}

/// The menu bar icon. It's the one view that always exists, so it also captures `openWindow`
/// and opens the Send window when Droprr starts.
private struct MenuBarLabel: View {
    var model: MacModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Seth prefers the colored logo over a monochrome template icon.
        Image(nsImage: {
            let image = NSImage(named: "MenuBarIcon") ?? NSImage()
            image.isTemplate = false
            image.size = NSSize(width: 18, height: 18)
            return image
        }())
        .onAppear {
            guard model.showSendWindow == nil else { return }
            model.showSendWindow = {
                openWindow(id: "send")
                bringToFront()
            }
            model.showSendWindow?()
        }
    }
}

/// Opening Droprr again from Finder, Spotlight or the Dock while it's running shows the Send window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { MacModel.current?.showSendWindow?() }
        return false
    }
}

@Observable
@MainActor
final class MacModel {
    /// The running app's model, for the app delegate.
    static weak var current: MacModel?
    @ObservationIgnored var showSendWindow: (() -> Void)?

    let settings = DroprrSettings.shared
    var status = "Starting…"
    var isListening = false
    var recent: [ReceivedItem] = []
    var lastSendResult: String?
    var progress: Double?
    var isSending = false
    /// Bumped whenever the outbox changes so views re-read counts.
    var outboxVersion = 0

    @ObservationIgnored private var receiver: DroprrReceiver!
    @ObservationIgnored let outbox: Outbox
    @ObservationIgnored private var listeningPort = 0

    static var inbox: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Droprr")
    }

    init() {
        outbox = Outbox(settings: settings)
        defer { Self.current = self }
        receiver = DroprrReceiver(settings: settings, inbox: Self.inbox)
        receiver.outbox = outbox
        receiver.onStateChange = { [weak self] state in
            self?.status = state
            self?.isListening = state.hasPrefix("Listening")
        }
        receiver.onItem = { [weak self] in self?.received($0) }
        outbox.onChange = { [weak self] in self?.outboxVersion += 1 }
        Notifier.shared.onOpen = { url in
            if url.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
        }
        Notifier.shared.requestPermission()
        restartIfNeeded()
    }

    /// Starts the receiver, or restarts it when the port setting changed.
    func restartIfNeeded() {
        guard settings.port != listeningPort else { return }
        listeningPort = settings.port
        receiver.start()
    }

    private func received(_ item: ReceivedItem) {
        switch item.kind {
        case .text(let text): Clipboard.copy(text: text)
        case .url(let url): Clipboard.copy(url: url)
        case .file: break
        }
        withAnimation { recent.insert(item, at: 0) }
        recent = Array(recent.prefix(8))
        Notifier.shared.notify(item)
    }

    func open(_ item: ReceivedItem) {
        switch item.kind {
        case .file(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .url(let url): NSWorkspace.shared.open(url)
        case .text(let text): Clipboard.copy(text: text)
        }
    }

    func waiting(for peer: Peer) -> Int {
        _ = outboxVersion
        return peer.isPhone ? outbox.count(for: peer) : 0
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastSendResult = "Couldn't change Launch at Login: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Sending

    func clipboardPayload() -> SendPayload? {
        let pb = NSPasteboard.general
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            return .files(files)
        }
        if let string = pb.string(forType: .string), !string.isEmpty {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
                return .url(url)
            }
            return .text(string)
        }
        if let image = NSImage(pasteboard: pb), let png = image.pngData {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard \(UUID().uuidString.prefix(6)).png")
            try? png.write(to: file)
            return .files([file])
        }
        return nil
    }

    func sendClipboard(to peer: Peer) async {
        guard let payload = clipboardPayload() else {
            lastSendResult = "The clipboard is empty."
            return
        }
        await send(payload, to: peer)
    }

    func chooseFiles(for peer: Peer) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Send"
        panel.message = "Choose files to send to \(peer.name)"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        Task { await send(.files(panel.urls), to: peer) }
    }

    func send(_ payload: SendPayload, to peer: Peer) async {
        settings.lastPeerID = peer.id
        // Phones can't receive in the background, so their items wait in the outbox.
        if peer.isPhone {
            do {
                try outbox.enqueue(payload, for: peer)
                lastSendResult = "\(payload.label.capitalizedFirst) is waiting for \(peer.name). It arrives when Droprr opens there."
            } catch {
                lastSendResult = "Couldn't queue for \(peer.name): \(error.localizedDescription)"
            }
            return
        }
        isSending = true
        progress = nil
        lastSendResult = "Sending \(payload.label) to \(peer.name)…"
        defer { isSending = false; progress = nil }
        do {
            let client = DroprrClient(peer: peer, token: settings.token)
            try await payload.send(with: client) { [weak self] in self?.progress = $0 }
            lastSendResult = "Sent \(payload.label) to \(peer.name)."
        } catch {
            lastSendResult = "Couldn't send to \(peer.name): \(error.localizedDescription)"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
