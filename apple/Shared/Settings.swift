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
    /// The token this device sends to that peer (from pairing or entered by hand). Stored in the Keychain.
    /// Without one the peer is "not paired" and can't be sent to; this device's main token is never sent.
    var token: String?
    /// The device token this device minted for that peer in POST /pair and accepts from it. Keychain too.
    var acceptToken: String?

    var isPaired: Bool { isPhone || !(token ?? "").isEmpty }

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

/// Local, per-device settings. Never committed. Names, ports and peers live in UserDefaults
/// (the shared app group so the share extensions can read them); every token lives in the Keychain.
@Observable
final class DroprrSettings {
    static let shared = DroprrSettings()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tokens: TokenStore
    @ObservationIgnored private let authLock = NSLock()
    @ObservationIgnored private var authSnapshot = AuthSnapshot()

    /// This device's main token: in its pairing QR code and accepted from anyone who has it (e.g. Shortcuts).
    var token: String { didSet { tokens.set(token, for: "main"); refreshAuth() } }
    var deviceName: String { didSet { defaults.set(deviceName, forKey: "deviceName") } }
    var port: Int { didSet { defaults.set(port, forKey: "port") } }
    var peers: [Peer] { didSet { savePeers(old: oldValue) } }
    var lastPeerID: UUID? { didSet { defaults.set(lastPeerID?.uuidString, forKey: "lastPeerID") } }
    /// Copy every received item (text, links, images and files) to the clipboard. Off by default.
    var autoCopy: Bool { didSet { defaults.set(autoCopy, forKey: "autoCopy") } }
    /// The Bento color theme's ID (see ThemePalette). Graphite & Lime by default.
    var theme: String { didSet { defaults.set(theme, forKey: "theme") } }
    /// Mac: the window style (see LookStyle). Material You by default.
    var style: String { didSet { defaults.set(style, forKey: "style") } }
    /// Mac: copy received text and links to the clipboard. On by default.
    var copyTextAndLinks: Bool { didSet { defaults.set(copyTextAndLinks, forKey: "copyTextAndLinks") } }
    /// "system", "light" or "dark". Spatial is always dark regardless.
    var colorMode: String { didSet { defaults.set(colorMode, forKey: "colorMode") } }
    /// Not saved: a device whose token Settings should open for editing ("Missing Token").
    var tokenRequest: UUID?

    init() {
        let group = Bundle.main.object(forInfoDictionaryKey: "DroprrAppGroup") as? String
        let validGroup = group.flatMap { $0.isEmpty || $0.hasPrefix(".") ? nil : $0 }
        defaults = validGroup.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        tokens = TokenStore(accessGroup: validGroup, fallback: defaults)
        // Earlier Mac builds kept settings in the app's own defaults; carry them into the shared group once.
        if defaults !== UserDefaults.standard, defaults.string(forKey: "token") == nil, defaults.data(forKey: "peers") == nil,
           UserDefaults.standard.string(forKey: "token") != nil {
            for key in ["token", "deviceName", "port", "peers", "lastPeerID"] {
                if let value = UserDefaults.standard.object(forKey: key) { defaults.set(value, forKey: key) }
            }
        }

        #if DEBUG
        // Debug builds: DROPRR_SEED=<plist> preloads settings for simulator screenshots.
        if let seed = ProcessInfo.processInfo.environment["DROPRR_SEED"],
           let values = NSDictionary(contentsOfFile: seed) as? [String: Any] {
            for (key, value) in values {
                if key.hasPrefix("tokens."), let token = value as? String {
                    tokens.set(token, for: String(key.dropFirst("tokens.".count)))
                } else {
                    defaults.set(value, forKey: key)
                }
            }
        }
        #endif

        // Tokens: move any left in UserDefaults into the Keychain once, then delete them there.
        let legacyMain = defaults.string(forKey: "token")
        if let legacyMain, !legacyMain.isEmpty, tokens.get("main") == nil { tokens.set(legacyMain, for: "main") }
        let main = tokens.get("main") ?? ""
        token = main

        deviceName = defaults.string(forKey: "deviceName") ?? DroprrSettings.defaultDeviceName
        let storedPort = defaults.integer(forKey: "port")
        port = storedPort > 0 ? storedPort : DroprrDefaults.port
        var loaded = (defaults.data(forKey: "peers").flatMap { try? JSONDecoder().decode([Peer].self, from: $0) }) ?? []
        for i in loaded.indices {
            let id = loaded[i].id.uuidString
            if let legacy = loaded[i].token, !legacy.isEmpty, tokens.get("send." + id) == nil { tokens.set(legacy, for: "send." + id) }
            loaded[i].token = tokens.get("send." + id)
            loaded[i].acceptToken = tokens.get("accept." + id)
            // Before per-device tokens, a computer without its own token was sent this device's main token.
            // Keep those working by storing that token as the peer's own.
            if !loaded[i].isPhone, (loaded[i].token ?? "").isEmpty, !main.isEmpty, legacyMain != nil {
                loaded[i].token = main
                tokens.set(main, for: "send." + id)
            }
        }
        peers = loaded
        lastPeerID = defaults.string(forKey: "lastPeerID").flatMap(UUID.init(uuidString:))
        autoCopy = defaults.bool(forKey: "autoCopy")
        copyTextAndLinks = defaults.object(forKey: "copyTextAndLinks") as? Bool ?? true
        theme = defaults.string(forKey: "theme") ?? ThemePalette.defaultID
        style = defaults.string(forKey: "style") ?? "material"
        colorMode = defaults.string(forKey: "colorMode") ?? "system"

        if legacyMain != nil { defaults.removeObject(forKey: "token") }
        savePeers(old: [])   // rewrites the peer list without tokens
        refreshAuth()
    }

    var lastPeer: Peer? {
        peers.first { $0.id == lastPeerID } ?? peers.first
    }

    private func savePeers(old: [Peer]) {
        var stripped = peers
        for i in stripped.indices {
            stripped[i].token = nil
            stripped[i].acceptToken = nil
        }
        if let data = try? JSONEncoder().encode(stripped) { defaults.set(data, forKey: "peers") }
        for peer in peers {
            let id = peer.id.uuidString
            tokens.set(peer.token, for: "send." + id)
            tokens.set(peer.acceptToken, for: "accept." + id)
        }
        // A removed device's tokens are deleted, so its requests get 401.
        for gone in old where !peers.contains(where: { $0.id == gone.id }) {
            tokens.remove("send." + gone.id.uuidString)
            tokens.remove("accept." + gone.id.uuidString)
        }
        refreshAuth()
    }

    // MARK: Authorization (read from the receiver's queue)

    enum Authorization: Equatable {
        case main
        case device(UUID)
    }

    private struct AuthSnapshot {
        var main = ""
        var devices: [(token: String, id: UUID)] = []
    }

    private func refreshAuth() {
        let snapshot = AuthSnapshot(main: token,
                                    devices: peers.compactMap { peer in peer.acceptToken.flatMap { $0.isEmpty ? nil : ($0, peer.id) } })
        authLock.withLock { authSnapshot = snapshot }
    }

    var hasMainToken: Bool { authLock.withLock { !authSnapshot.main.isEmpty } }

    /// Which token, if any, a bearer value is: the main token or a paired device's token. Constant-time compares.
    func authorize(_ bearer: String) -> Authorization? {
        let snapshot = authLock.withLock { authSnapshot }
        var result: Authorization?
        if !snapshot.main.isEmpty, Self.constantTimeEqual(bearer, snapshot.main) { result = .main }
        for device in snapshot.devices where Self.constantTimeEqual(bearer, device.token) {
            result = result ?? .device(device.id)
        }
        return result
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// 32 random bytes, base64url without padding (the protocol's token format).
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
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
