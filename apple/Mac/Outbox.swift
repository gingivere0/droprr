import Foundation
import UniformTypeIdentifiers

/// Items waiting for a phone to collect them via /inbox (see "Inbox" in docs/PROTOCOL.md).
/// Stored in ~/Library/Application Support/Droprr/Outbox so they survive restarts.
final class Outbox: OutboxServing {
    struct Item: Codable {
        var id: String
        var peerID: UUID
        var type: String          // file, text, url
        var name: String
        var size: Int
        var content: String?
        var created: Date
    }

    static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    private let settings: DroprrSettings
    private let root: URL
    private let lock = NSLock()
    private var items: [Item] = []

    /// Called on the main queue whenever the queue changes.
    var onChange: () -> Void = {}

    init(settings: DroprrSettings) {
        self.settings = settings
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "Droprr")/Outbox")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder.iso.decode([Item].self, from: data) {
            items = decoded
        }
        purgeExpired()
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private func fileURL(_ id: String) -> URL { root.appendingPathComponent(id) }

    // MARK: Queueing (main app)

    func enqueue(_ payload: SendPayload, for peer: Peer) throws {
        var new: [Item] = []
        switch payload {
        case .text(let text):
            new.append(Item(id: UUID().uuidString.lowercased(), peerID: peer.id, type: "text", name: "Text",
                            size: text.utf8.count, content: text, created: Date()))
        case .url(let url):
            new.append(Item(id: UUID().uuidString.lowercased(), peerID: peer.id, type: "url", name: "Link",
                            size: url.absoluteString.utf8.count, content: url.absoluteString, created: Date()))
        case .files(let files):
            for file in files {
                let id = UUID().uuidString.lowercased()
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: file, to: fileURL(id))
                let size = (try? fileURL(id).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                new.append(Item(id: id, peerID: peer.id, type: "file", name: file.lastPathComponent,
                                size: size, content: nil, created: Date()))
            }
        }
        mutate { $0 += new }
    }

    func enqueue(_ received: [ReceivedItem], forPeerID id: String) throws {
        let peer = DispatchQueue.main.sync { settings.peers.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame } }
        guard let peer else { throw CocoaError(.fileNoSuchFile) }
        for item in received {
            switch item.kind {
            case .file(let url): try enqueue(.files([url]), for: peer)
            case .text(let text): try enqueue(.text(text), for: peer)
            case .url(let url): try enqueue(.url(url), for: peer)
            }
        }
    }

    func count(for peer: Peer) -> Int {
        lock.withLock { items.filter { $0.peerID == peer.id }.count }
    }

    func clear(for peer: Peer) {
        let ids = lock.withLock { items.filter { $0.peerID == peer.id }.map(\.id) }
        ids.forEach { _ = remove(id: $0, peerID: nil) }
    }

    // MARK: OutboxServing (receiver queue)

    func list(for deviceName: String?, peerID: UUID?, from remoteHost: String?) -> [[String: Any]] {
        purgeExpired()
        let peer = DispatchQueue.main.sync { () -> Peer? in
            // A device token picks the queue; ?for= is ignored.
            if let peerID { return settings.peers.first { $0.id == peerID } }
            guard let deviceName else { return nil }
            if let known = settings.peers.first(where: { $0.matches(deviceName: deviceName) }) {
                if !known.isPhone, let i = settings.peers.firstIndex(where: { $0.id == known.id }) {
                    settings.peers[i].platform = "ios"   // it's polling, so it's a phone
                }
                return known
            }
            // First check-in from an unknown phone: register it so the Mac can send to it.
            let added = Peer(name: deviceName, host: remoteHost ?? "", platform: "ios", remoteName: deviceName)
            settings.peers.append(added)
            return added
        }
        guard let peer else { return [] }
        let formatter = ISO8601DateFormatter()
        return lock.withLock {
            items.filter { $0.peerID == peer.id }
                .sorted { $0.created < $1.created }
                .map { item in
                    var json: [String: Any] = ["id": item.id, "type": item.type, "name": item.name,
                                               "size": item.size, "created": formatter.string(from: item.created)]
                    if let content = item.content { json["content"] = content }
                    return json
                }
        }
    }

    func file(id: String, peerID: UUID?) -> (url: URL, name: String, mimeType: String)? {
        purgeExpired()
        guard let item = lock.withLock({ items.first { $0.id == id && (peerID == nil || $0.peerID == peerID) } }) else { return nil }
        if let content = item.content {
            // Text and links download as plain text, so a shortcut can fetch every type the same way.
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("droprr-out-\(id).txt")
            try? Data(content.utf8).write(to: temp)
            return (temp, item.name, "text/plain; charset=utf-8")
        }
        let ext = (item.name as NSString).pathExtension.lowercased()
        let mime = ext == "bin" ? "application/octet-stream"
            : UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        return (fileURL(id), item.name, mime)
    }

    func remove(id: String, peerID: UUID?) -> Bool {
        purgeExpired()
        var found = false
        let matches: (Item) -> Bool = { $0.id == id && (peerID == nil || $0.peerID == peerID) }
        mutate { items in
            found = items.contains(where: matches)
            items.removeAll(where: matches)
        }
        if found { try? FileManager.default.removeItem(at: fileURL(id)) }
        return found
    }

    // MARK: Storage

    private func purgeExpired() {
        let cutoff = Date().addingTimeInterval(-Self.lifetime)
        var expired: [Item] = []
        mutate { items in
            expired = items.filter { $0.created < cutoff }
            items.removeAll { $0.created < cutoff }
        }
        expired.forEach { try? FileManager.default.removeItem(at: fileURL($0.id)) }
    }

    private func mutate(_ change: (inout [Item]) -> Void) {
        let changed: Bool = lock.withLock {
            let before = items.map(\.id)
            change(&items)
            guard items.map(\.id) != before else { return false }
            if let data = try? JSONEncoder.iso.encode(items) { try? data.write(to: indexURL, options: .atomic) }
            return true
        }
        if changed { DispatchQueue.main.async(execute: onChange) }
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

private extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}
