import SwiftUI
import UIKit

@main
struct DroprrPhoneApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS can't keep a listener alive in the background, so receive only while open.
            if phase == .active { model.startReceiving() } else if phase == .background { model.stopReceiving() }
        }
    }
}

@Observable
@MainActor
final class PhoneModel {
    let settings = DroprrSettings.shared
    var status = "Not receiving"
    var received: [ReceivedItem] = []
    var lastSendResult: String?
    var sending = false

    @ObservationIgnored private var receiver: DroprrReceiver!

    /// Visible in the Files app under On My iPhone › Droprr.
    static var inbox: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Received")
    }

    init() {
        receiver = DroprrReceiver(settings: settings, inbox: Self.inbox)
        receiver.onStateChange = { [weak self] in self?.status = $0 }
        receiver.onItem = { [weak self] in self?.handle($0) }
        Notifier.shared.requestPermission()
    }

    func startReceiving() { receiver.start() }

    func stopReceiving() {
        receiver.stop()
        status = "Not receiving"
    }

    private func handle(_ item: ReceivedItem) {
        switch item.kind {
        case .text(let text): Clipboard.copy(text: text)
        case .url(let url): Clipboard.copy(url: url)
        case .file: break
        }
        received.insert(item, at: 0)
        Notifier.shared.notify(item)
    }

    func send(_ payload: SendPayload, to peer: Peer) async {
        settings.lastPeerID = peer.id
        sending = true
        defer { sending = false }
        lastSendResult = "Sending \(payload.label) to \(peer.name)…"
        do {
            try await payload.send(with: DroprrClient(peer: peer, token: settings.token))
            lastSendResult = "Sent \(payload.label) to \(peer.name)."
        } catch {
            lastSendResult = "Couldn't send to \(peer.name): \(error.localizedDescription)"
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
