import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

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
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("Pair a Phone", id: "pair") {
            PairView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
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
            let image = NSImage(named: "MenuBarIcon-\(Theme.palette.id)") ?? NSImage()
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No title bar strip on any Droprr window (Settings included): content runs to the top edge,
        // with just the window buttons in the corner.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didUpdateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { AppDelegate.hideTitleBar(window) }
            }
        }
    }

    @MainActor
    static func hideTitleBar(_ window: NSWindow) {
        guard window.styleMask.contains(.titled), !(window is NSPanel) else { return }
        window.backgroundColor = Look.windowColor
        window.isOpaque = !Look.forcesDark
        window.appearance = Look.forcesDark ? NSAppearance(named: .darkAqua) : nil
        applyGlass(window)
        if window.titlebarAppearsTransparent && window.titleVisibility == .hidden
            && window.styleMask.contains(.fullSizeContentView) && window.toolbar == nil { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.toolbar = nil
        window.isMovableByWindowBackground = true
        // Match the theme surface so nothing of the default window color peeks out at the edges.
        window.backgroundColor = Look.windowColor
    }

    /// Spatial: frosted glass behind the whole window, title bar strip included, so nothing
    /// behind the window shows through unblurred where the SwiftUI content doesn't reach.
    @MainActor
    private static func applyGlass(_ window: NSWindow) {
        let id = NSUserInterfaceItemIdentifier("droprr.glass")
        guard let content = window.contentView, let frame = content.superview else { return }
        let existing = frame.subviews.first { $0.identifier == id }
        // A see-through window still draws the title bar's own (light) material, even with a
        // transparent title bar; hide it so the glass shows through.
        func titlebarMaterials(in view: NSView) -> [NSVisualEffectView] {
            view.subviews.flatMap { sub -> [NSVisualEffectView] in
                (sub as? NSVisualEffectView).map { [$0] } ?? titlebarMaterials(in: sub)
            }
        }
        for container in frame.subviews where String(describing: type(of: container)).contains("Titlebar") {
            for material in titlebarMaterials(in: container) { material.isHidden = Look.forcesDark }
        }
        if Look.forcesDark {
            guard existing == nil else { return }
            let glass = NSVisualEffectView(frame: frame.bounds)
            glass.identifier = id
            glass.material = .hudWindow
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.autoresizingMask = [.width, .height]
            frame.addSubview(glass, positioned: .below, relativeTo: content)
        } else {
            existing?.removeFromSuperview()
        }
    }

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
        receiver.onPair = { [weak self] in self?.paired($0) }
        receiver.onStateChange = { [weak self] state in
            self?.status = state
            self?.isListening = state.hasPrefix("Listening")
        }
        receiver.onItem = { [weak self] in self?.received($0) }
        outbox.onChange = { [weak self] in self?.outboxVersion += 1 }
        Notifier.shared.onOpen = { url in
            if url.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { Links.open(url) }
        }
        Notifier.shared.requestPermission()
        restartIfNeeded()
        #if DEBUG
        SnapshotSupport.runIfRequested(model: self)
        #endif
    }

    /// Starts the receiver, or restarts it when the port setting changed.
    func restartIfNeeded() {
        guard settings.port != listeningPort else { return }
        listeningPort = settings.port
        receiver.start()
    }

    private func received(_ item: ReceivedItem) {
        // Like Windows: text and links are copied unless turned off; auto-copy adds files and images.
        switch item.kind {
        case .text, .url: if settings.copyTextAndLinks || settings.autoCopy { Clipboard.copy(item) }
        case .file: if settings.autoCopy { Clipboard.copy(item) }
        }
        Motion.perform { recent.insert(item, at: 0) }
        recent = Array(recent.prefix(8))
        Notifier.shared.notify(item)
    }

    /// The name of the last device that paired, so an open Pair window can confirm and close.
    var lastPaired: String?

    /// A device paired with this Mac (POST /pair): add it, or update the peer with that name.
    private func paired(_ request: PairRequest) {
        if let i = settings.peers.firstIndex(where: { $0.matches(deviceName: request.name) }) {
            settings.peers[i].platform = request.platform
            settings.peers[i].remoteName = request.name
            // Keep a host we already have for a known computer.
            if settings.peers[i].host.isEmpty { settings.peers[i].host = request.host }
            if request.platform != "ios" && settings.peers[i].host == request.host { settings.peers[i].port = request.port }
            // Re-pairing replaces the device token, so the old one stops working.
            settings.peers[i].acceptToken = request.acceptToken
            if request.platform == "ios" { settings.peers[i].token = nil }
            else if let token = request.token { settings.peers[i].token = token }
        } else {
            settings.peers.append(Peer(name: request.name, host: request.host, port: request.port,
                                       platform: request.platform, remoteName: request.name,
                                       token: request.token, acceptToken: request.acceptToken))
        }
        lastPaired = request.name
        lastSendResult = "\(request.name) paired."
        let content = UNMutableNotificationContent()
        content.title = "\(request.name) paired"
        content.body = request.platform == "ios"
            ? "Items you send to it wait here until Droprr opens on the phone."
            : "You can send to it now."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func open(_ item: ReceivedItem) {
        switch item.kind {
        case .file(let url): NSWorkspace.shared.open(url)   // quarantined, so macOS warns before risky files run
        case .url(let url): Links.open(url)
        case .text: Clipboard.copy(item)
        }
    }

    /// Removes an item from the Received list; the file itself stays in Downloads › Droprr.
    func removeRecent(_ item: ReceivedItem) {
        Motion.perform { recent.removeAll { $0.id == item.id } }
    }

    func waiting(for peer: Peer) -> Int {
        _ = outboxVersion
        return peer.isPhone ? outbox.count(for: peer) : 0
    }

    func clearWaiting(for peer: Peer) {
        outbox.clear(for: peer)
        lastSendResult = "Cleared the items waiting for \(peer.name)."
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
        let urls = pickFiles(prompt: "Send", message: "Choose files to send to \(peer.name)")
        guard !urls.isEmpty else { return }
        Task { await send(.files(urls), to: peer) }
    }

    /// Shows an open panel and returns the chosen files (empty if cancelled).
    func pickFiles(prompt: String = "Add", message: String = "Choose files to send") -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = prompt
        panel.message = message
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Sends several payloads in order, stopping at the first failure. Returns true if all arrived.
    @discardableResult
    func send(_ payloads: [SendPayload], to peer: Peer) async -> Bool {
        for payload in payloads {
            await send(payload, to: peer)
            if let result = lastSendResult, result.hasPrefix("Couldn't") { return false }
        }
        return true
    }

    func send(_ payload: SendPayload, to peer: Peer) async {
        settings.lastPeerID = peer.id
        // Phones can't receive in the background, so their items wait in the outbox.
        if peer.isPhone {
            do {
                try outbox.enqueue(payload, for: peer)
                lastSendResult = nil   // the tile's "waiting" badge already shows it
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
            let client = DroprrClient(peer: peer)
            try await payload.send(with: client) { [weak self] in self?.progress = $0 }
            lastSendResult = "Sent \(payload.label) to \(peer.name)."
        } catch {
            lastSendResult = "Couldn't send to \(peer.name): \(error.localizedDescription)"
        }
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
