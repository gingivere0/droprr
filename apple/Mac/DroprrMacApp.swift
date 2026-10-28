import AppKit
import SwiftUI

@main
struct DroprrMacApp: App {
    @State private var model = MacModel()

    var body: some Scene {
        MenuBarExtra("Droprr", systemImage: "paperplane.fill") {
            MenuContent(model: model)
        }

        Window("Send with Droprr", id: "send") {
            SendView(model: model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsForm(settings: model.settings)
                .frame(width: 460, height: 520)
                .onChange(of: model.settings.port) { model.restartIfNeeded() }
        }
    }
}

@Observable
@MainActor
final class MacModel {
    let settings = DroprrSettings.shared
    var status = "Starting…"
    var recent: [ReceivedItem] = []
    var lastSendResult: String?

    @ObservationIgnored private var receiver: DroprrReceiver!
    @ObservationIgnored private var listeningPort = 0

    static var inbox: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Droprr")
    }

    init() {
        receiver = DroprrReceiver(settings: settings, inbox: Self.inbox)
        receiver.onStateChange = { [weak self] in self?.status = $0 }
        receiver.onItem = { [weak self] in self?.received($0) }
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
        recent.insert(item, at: 0)
        recent = Array(recent.prefix(15))
        Notifier.shared.notify(item)
    }

    func open(_ item: ReceivedItem) {
        switch item.kind {
        case .file(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case .url(let url): NSWorkspace.shared.open(url)
        case .text(let text): Clipboard.copy(text: text)
        }
    }

    // MARK: Sending

    func send(clipboardTo peer: Peer) async {
        let pb = NSPasteboard.general
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            await send(files: files, to: peer)
        } else if let string = pb.string(forType: .string) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
                await run("link", to: peer) { try await $0.send(url: url) }
            } else {
                await run("text", to: peer) { try await $0.send(text: string) }
            }
        } else if let image = NSImage(pasteboard: pb), let png = image.pngData {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Clipboard \(UUID().uuidString.prefix(6)).png")
            try? png.write(to: file)
            await send(files: [file], to: peer)
        } else {
            lastSendResult = "The clipboard is empty."
        }
    }

    func send(text: String, to peer: Peer) async {
        await run("text", to: peer) { try await $0.send(text: text) }
    }

    func send(files: [URL], to peer: Peer) async {
        let label = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        await run(label, to: peer) { try await $0.send(files: files) }
    }

    private func run(_ label: String, to peer: Peer, _ action: (DroprrClient) async throws -> Void) async {
        settings.lastPeerID = peer.id
        lastSendResult = "Sending \(label) to \(peer.name)…"
        do {
            try await action(DroprrClient(peer: peer, token: settings.token))
            lastSendResult = "Sent \(label) to \(peer.name)."
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
