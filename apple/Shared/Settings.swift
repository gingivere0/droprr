import Foundation
import Observation

enum DroprrDefaults {
    static let port = 53318
    static let version = "0.1.0"
}

/// Another device running Droprr, addressed by its Tailscale (MagicDNS) name or 100.x address.
struct Peer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = DroprrDefaults.port
    /// "windows", "macos" or "ios", learned from /ping or set by hand. Sends to "ios" peers are queued.
    var platform: String?
    /// The name the device reports in /ping, which it also uses for /inbox?for=.
    var remoteName: String?
    /// This device's own token, from its pairing QR code. When nil, the shared token in Settings is used.
    var token: String?

    var isPhone: Bool {
        get { platform == "ios" }
        set { platform = newValue ? "ios" : (platform == "ios" ? nil : platform) }
    }

    func matches(deviceName: String) -> Bool {
        [name, remoteName].contains { $0?.caseInsensitiveCompare(deviceName) == .orderedSame }
    }

    var baseURL: URL? {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        let bracketed = h.contains(":") && !h.hasPrefix("[") ? "[\(h)]" : h
        return URL(string: "http://\(bracketed):\(port)")
    }
}

/// Local, per-device settings. Never committed: they live in UserDefaults
/// (the shared app group container on iOS so the share extension can read them).
@Observable
final class DroprrSettings {
    static let shared = DroprrSettings()

    @ObservationIgnored private let defaults: UserDefaults

    var token: String { didSet { defaults.set(token, forKey: "token") } }
    var deviceName: String { didSet { defaults.set(deviceName, forKey: "deviceName") } }
    var port: Int { didSet { defaults.set(port, forKey: "port") } }
    var peers: [Peer] { didSet { savePeers() } }
    var lastPeerID: UUID? { didSet { defaults.set(lastPeerID?.uuidString, forKey: "lastPeerID") } }

    init() {
        let group = Bundle.main.object(forInfoDictionaryKey: "DroprrAppGroup") as? String
        defaults = group.flatMap { $0.isEmpty || $0.hasPrefix(".") ? nil : UserDefaults(suiteName: $0) } ?? .standard
        // Earlier Mac builds kept settings in the app's own defaults; carry them into the shared group once.
        if defaults !== UserDefaults.standard, defaults.string(forKey: "token") == nil,
           UserDefaults.standard.string(forKey: "token") != nil {
            for key in ["token", "deviceName", "port", "peers", "lastPeerID"] {
                if let value = UserDefaults.standard.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }

        token = defaults.string(forKey: "token") ?? ""
        deviceName = defaults.string(forKey: "deviceName") ?? DroprrSettings.defaultDeviceName
        let storedPort = defaults.integer(forKey: "port")
        port = storedPort > 0 ? storedPort : DroprrDefaults.port
        if let data = defaults.data(forKey: "peers"),
           let decoded = try? JSONDecoder().decode([Peer].self, from: data) {
            peers = decoded
        } else {
            peers = []
        }
        lastPeerID = defaults.string(forKey: "lastPeerID").flatMap(UUID.init(uuidString:))
    }

    var lastPeer: Peer? {
        peers.first { $0.id == lastPeerID } ?? peers.first
    }

    private func savePeers() {
        if let data = try? JSONEncoder().encode(peers) {
            defaults.set(data, forKey: "peers")
        }
    }

    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static var defaultDeviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "iPhone"
        #endif
    }

    static var platform: String {
        #if os(macOS)
        return "macos"
        #else
        return "ios"
        #endif
    }
}
