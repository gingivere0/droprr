import SwiftUI
import UIKit
import UserNotifications

@main
struct DroprrPhoneApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .tint(Look.accentText)
                // Scanning the pairing QR code with the Camera app opens droprr://pair?…
                .onOpenURL { url in model.pair(with: url.absoluteString, confirm: true) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Desktops always queue items for a phone, so collect them each time the app comes forward.
            if phase == .active { Task { await model.collectInbox() } }
        }
    }
}

@Observable
@MainActor
final class PhoneModel {
    let settings = DroprrSettings.shared
    var history: [HistoryEntry] = []
    var lastSendResult: String?
    var progress: Double?
    var sending = false
    var collecting = false
    var lastCollect: String?

    /// Visible in the Files app under On My iPhone › Droprr.
    nonisolated static var inbox: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Received")
    }

    private static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("history.json")
    }

    static let historyLimit = 30

    init() {
        if let data = try? Data(contentsOf: Self.historyURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = saved.filter(\.isAvailable)
        }
    }

    var newItems: [HistoryEntry] { history.filter(\.isNew) }
    var seenItems: [HistoryEntry] { history.filter { !$0.isNew } }

    private func record(_ item: ReceivedItem, from source: String?) {
        if settings.autoCopy { Clipboard.copy(item) }
        Motion.perform {
            history.insert(HistoryEntry(item, source: source), at: 0)
            trimAndSave()
        }
        // No notification here: items only arrive while the app is open, and the New list shows them.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    /// Tapping an item: copy text and links, then move it out of New and clear its notification.
    func use(_ entry: HistoryEntry) {
        switch entry.item.kind {
        case .text(let text): Clipboard.copy(text: text)
        case .url(let url): Clipboard.copy(url: url)
        case .file: break
        }
        markSeen(entry)
    }

    func markSeen(_ entry: HistoryEntry) {
        guard let i = history.firstIndex(where: { $0.id == entry.id }), history[i].isNew else { return }
        Motion.perform { history[i].isNew = false }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [entry.id.uuidString])
        trimAndSave()
    }

    func markAllSeen() {
        let ids = newItems.map(\.id.uuidString)
        Motion.perform { for i in history.indices { history[i].isNew = false } }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        trimAndSave()
    }

    func delete(_ entry: HistoryEntry) {
        Motion.perform { history.removeAll { $0.id == entry.id } }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [entry.id.uuidString])
        trimAndSave()
    }

    func clearHistory() {
        Motion.perform { history.removeAll { !$0.isNew } }
        trimAndSave()
    }

    /// Keeps every new item plus the most recent seen ones. Received files stay in the Files app.
    private func trimAndSave() {
        var seen = 0
        history = history.filter { entry in
            if entry.isNew { return true }
            seen += 1
            return seen <= Self.historyLimit
        }
        try? FileManager.default.createDirectory(at: Self.historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: Self.historyURL, options: .atomic) }
    }

    // MARK: Pairing

    enum PairingStatus: Equatable {
        case working(String)
        case success(String)
        case failure(String)
    }

    /// Shown as a card over the app while and after a QR code is scanned.
    var pairingStatus: PairingStatus?

    /// A pairing link opened from outside the app (Camera, Safari, Messages), waiting for the user to confirm.
    var pendingPairing: PairingInfo?

    /// Peer that a pairing code would replace, if any.
    func existingPeer(for info: PairingInfo) -> Peer? {
        let addresses = [info.host, info.dns].compactMap { $0 }.filter { !$0.isEmpty }
        return settings.peers.first { peer in
            addresses.contains { peer.host.caseInsensitiveCompare($0) == .orderedSame } || peer.matches(deviceName: info.name)
        }
    }

    /// Handles a scanned or opened pairing code. Links opened from outside the app are never applied
    /// directly: they wait in `pendingPairing` until the user taps Pair.
    func pair(with code: String, confirm: Bool = false) {
        let info: PairingInfo
        switch PairingInfo.parse(code) {
        case .success(let parsed): info = parsed
        case .failure(.newerVersion):
            pairingStatus = .failure("This pairing code is from a newer version of Droprr. Update the app on this iPhone and try again.")
            return
        case .failure:
            pairingStatus = .failure("That isn't a Droprr pairing code.")
            return
        }
        guard info.pointsInsideTailnet else {
            pairingStatus = .failure("This code points outside your Tailscale network, so Droprr won't use it.")
            return
        }
        if confirm {
            pendingPairing = info
        } else {
            completePairing(info)
        }
    }

    func completePairing(_ info: PairingInfo) {
        pendingPairing = nil
        var peer = settings.apply(info)
        pairingStatus = .working("Pairing with \(peer.name)")
        Task {
            do {
                // Pair both ways with the QR code's token; the desktop answers with a device token
                // just for this phone, which replaces the QR token from now on.
                let result = try await DroprrClient(peer: peer).pair(name: settings.deviceName, platform: DroprrSettings.platform)
                if let token = result.token, let i = settings.peers.firstIndex(where: { $0.id == peer.id }) {
                    settings.peers[i].token = token
                    peer = settings.peers[i]
                }
                let ping = try await DroprrClient(peer: peer).ping()
                if let i = settings.peers.firstIndex(where: { $0.id == peer.id }) {
                    settings.peers[i].platform = ping.platform
                    settings.peers[i].remoteName = ping.name
                }
                pairingStatus = .success("Paired with \(ping.name)")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    if case .success = pairingStatus { pairingStatus = nil }
                }
                await collectInbox()
            } catch {
                pairingStatus = .failure("Added \(peer.name), but it didn't answer: \(error.localizedDescription) Check that Tailscale is on for both devices.")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    // MARK: Inbox

    /// Pulls items each desktop is holding for this phone (GET /inbox), then acknowledges them.
    func collectInbox() async {
        let desktops = settings.peers.filter { !$0.isPhone }
        guard !collecting, !desktops.isEmpty else { return }
        collecting = true
        defer { collecting = false }
        var count = 0
        var reached = 0
        for peer in desktops {
            let client = DroprrClient(peer: peer)
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
                        // Only http(s) is a link; anything else is kept as text.
                        if let url = URL(string: entry.content ?? ""), Links.isWeb(url) {
                            item = ReceivedItem(kind: .url(url))
                        } else {
                            item = ReceivedItem(kind: .text(entry.content ?? ""))
                        }
                    default:
                        item = ReceivedItem(kind: .text(entry.content ?? ""))
                    }
                    try await client.acknowledge(entry)
                    record(item, from: peer.name)
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

    /// Sends everything staged on the Send tab, in order. Returns true if all of it arrived.
    @discardableResult
    func send(_ payloads: [SendPayload], to peer: Peer) async -> Bool {
        guard !payloads.isEmpty else { return false }
        settings.lastPeerID = peer.id
        sending = true
        progress = nil
        defer { sending = false; progress = nil }
        let label = payloads.map(\.label).joined(separator: ", ")
        lastSendResult = "Sending \(label) to \(peer.name)…"
        do {
            let client = DroprrClient(peer: peer)
            for payload in payloads {
                try await payload.send(with: client) { [weak self] in self?.progress = $0 }
            }
            lastSendResult = "Sent \(label) to \(peer.name)."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return true
        } catch {
            lastSendResult = "Couldn't send to \(peer.name): \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
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

/// One received item in the Received tab. Files are stored by name, since the app's
/// container path changes between installs.
struct HistoryEntry: Codable, Identifiable {
    var id: UUID
    var date: Date
    var source: String?
    var isNew: Bool
    var type: String      // file, text, url
    var value: String     // file name, text, or link

    init(_ item: ReceivedItem, source: String?) {
        id = item.id
        date = item.date
        self.source = source
        isNew = true
        switch item.kind {
        case .file(let url): type = "file"; value = url.lastPathComponent
        case .text(let text): type = "text"; value = text
        case .url(let url): type = "url"; value = url.absoluteString
        }
    }

    var item: ReceivedItem {
        let kind: ReceivedItem.Kind
        switch type {
        case "file": kind = .file(PhoneModel.inbox.appendingPathComponent(value))
        case "url": kind = URL(string: value).flatMap { Links.isWeb($0) ? .url($0) : nil } ?? .text(value)
        default: kind = .text(value)
        }
        return ReceivedItem(id: id, kind: kind, date: date)
    }

    /// Files deleted in the Files app drop out of the list.
    var isAvailable: Bool {
        type != "file" || FileManager.default.fileExists(atPath: PhoneModel.inbox.appendingPathComponent(value).path)
    }
}
