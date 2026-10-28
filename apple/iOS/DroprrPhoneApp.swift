import SwiftUI
import UIKit

@main
struct DroprrPhoneApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .tint(Theme.start)
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS can't keep a listener alive in the background, so receive only while open,
            // and collect anything the desktops queued for us each time the app comes forward.
            if phase == .active {
                model.startReceiving()
                Task { await model.collectInbox() }
            } else if phase == .background {
                model.stopReceiving()
            }
        }
    }
}

@Observable
@MainActor
final class PhoneModel {
    let settings = DroprrSettings.shared
    var status = "Not receiving"
    var isListening = false
    var received: [ReceivedItem] = []
    var lastSendResult: String?
    var progress: Double?
    var sending = false
    var collecting = false
    var lastCollect: String?

    @ObservationIgnored private var receiver: DroprrReceiver!

    /// Visible in the Files app under On My iPhone › Droprr.
    static var inbox: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Received")
    }

    init() {
        receiver = DroprrReceiver(settings: settings, inbox: Self.inbox)
        receiver.onStateChange = { [weak self] state in
            self?.status = state
            self?.isListening = state.hasPrefix("Listening")
        }
        receiver.onItem = { [weak self] in self?.handle($0) }
        Notifier.shared.requestPermission()
    }

    func startReceiving() { receiver.start() }

    func stopReceiving() {
        receiver.stop()
        isListening = false
        status = "Not receiving"
    }

    private func handle(_ item: ReceivedItem, from source: String? = nil) {
        switch item.kind {
        case .text(let text): Clipboard.copy(text: text)
        case .url(let url): Clipboard.copy(url: url)
        case .file: break
        }
        withAnimation { received.insert(item, at: 0) }
        Notifier.shared.notify(item, from: source)
    }

    // MARK: Inbox

    /// Pulls items each desktop is holding for this phone (GET /inbox), then acknowledges them.
    func collectInbox() async {
        let desktops = settings.peers.filter { !$0.isPhone }
        guard !collecting, !desktops.isEmpty, !settings.token.isEmpty else { return }
        collecting = true
        defer { collecting = false }
        var count = 0
        var reached = 0
        for peer in desktops {
            let client = DroprrClient(peer: peer, token: settings.token)
            guard let items = try? await client.inbox(for: settings.deviceName) else { continue }
            reached += 1
            for entry in items {
                do {
                    let item: ReceivedItem
                    switch entry.type {
                    case "file":
                        let temp = try await client.download(entry)
                        let dest = Self.uniqueDestination(for: entry.name)
                        try FileManager.default.moveItem(at: temp, to: dest)
                        item = ReceivedItem(kind: .file(dest))
                    case "url":
                        guard let url = URL(string: entry.content ?? "") else { continue }
                        item = ReceivedItem(kind: .url(url))
                    default:
                        item = ReceivedItem(kind: .text(entry.content ?? ""))
                    }
                    try await client.acknowledge(entry)
                    handle(item, from: peer.name)
                    count += 1
                } catch {
                    continue   // left in the outbox; we'll try again next time
                }
            }
        }
        if reached == 0 {
            lastCollect = "Couldn't reach your computers. Are you on Tailscale?"
        } else {
            lastCollect = count == 0 ? "Up to date" : "Collected \(count) item\(count == 1 ? "" : "s")"
        }
    }

    private static func uniqueDestination(for rawName: String) -> URL {
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let name = (rawName as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "_")
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = inbox.appendingPathComponent(name.isEmpty ? "Droprr item" : name)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = inbox.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: Sending

    func send(_ payload: SendPayload, to peer: Peer) async {
        settings.lastPeerID = peer.id
        sending = true
        progress = nil
        defer { sending = false; progress = nil }
        lastSendResult = "Sending \(payload.label) to \(peer.name)…"
        do {
            try await payload.send(with: DroprrClient(peer: peer, token: settings.token)) { [weak self] in self?.progress = $0 }
            lastSendResult = "Sent \(payload.label) to \(peer.name)."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            lastSendResult = "Couldn't send to \(peer.name): \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    /// Whatever is on the clipboard right now, or nil if it's empty.
    func clipboardPayload() -> SendPayload? {
        let pb = UIPasteboard.general
        if let url = pb.url, !url.isFileURL { return .url(url) }
        if let text = pb.string { return .text(text) }
        if let image = pb.image, let png = image.pngData() {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard.png")
            try? png.write(to: file)
            return .files([file])
        }
        return nil
    }
}
