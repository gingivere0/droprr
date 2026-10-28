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
                .tint(Theme.start)
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
        withAnimation {
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
        withAnimation { history[i].isNew = false }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [entry.id.uuidString])
        trimAndSave()
    }

    func markAllSeen() {
        let ids = newItems.map(\.id.uuidString)
        withAnimation { for i in history.indices { history[i].isNew = false } }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        trimAndSave()
    }

    func delete(_ entry: HistoryEntry) {
        withAnimation { history.removeAll { $0.id == entry.id } }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [entry.id.uuidString])
        trimAndSave()
    }

    func clearHistory() {
        withAnimation { history.removeAll { !$0.isNew } }
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
        case "url": kind = URL(string: value).map { .url($0) } ?? .text(value)
        default: kind = .text(value)
        }
        return ReceivedItem(id: id, kind: kind, date: date)
    }

    /// Files deleted in the Files app drop out of the list.
    var isAvailable: Bool {
        type != "file" || FileManager.default.fileExists(atPath: PhoneModel.inbox.appendingPathComponent(value).path)
    }
}
