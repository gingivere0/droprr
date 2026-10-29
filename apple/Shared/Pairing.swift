import Foundation
import Darwin

/// The pairing QR code: droprr://pair?v=1&name=…&host=…&port=…&token=…&platform=…
/// A desktop shows it; the iPhone scans it (in the app or with the Camera app) to get the token and address.
struct PairingInfo: Equatable {
    var name: String
    var host: String
    var port: Int
    var token: String
    var platform: String?
    /// The desktop's MagicDNS name, preferred for connecting because the IP can change.
    var dns: String?
    // Protocol 2 (optional; older apps ignore them): the desktop's id, certificate fingerprint and
    // LAN "host:port" addresses for HTTPS.
    var id: String?
    var fp: String?
    var lan: [String] = []
    /// The one code's join secret (docs/PROTOCOL.md, "One code"): pair with it in place of a token, which the code
    /// never carries.
    var join: String?

    static let version = 1

    var url: URL? {
        // Strict RFC 3986 encoding: only unreserved characters stay literal (see "Pairing QR" in PROTOCOL.md).
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value }
        var fields = [("v", String(Self.version)), ("name", name), ("host", host), ("port", String(port)), ("token", token)]
        if let platform { fields.append(("platform", platform)) }
        if let dns { fields.append(("dns", dns)) }
        if let id { fields.append(("id", id)) }
        if let fp { fields.append(("fp", fp)) }
        if !lan.isEmpty { fields.append(("lan", lan.joined(separator: ","))) }
        return URL(string: "droprr://pair?" + fields.map { "\($0)=\(encode($1))" }.joined(separator: "&"))
    }

    init(name: String, host: String, port: Int, token: String, platform: String?, dns: String? = nil,
         id: String? = nil, fp: String? = nil, lan: [String] = [], join: String? = nil) {
        self.join = join
        self.name = name
        self.host = host
        self.port = port
        self.token = token
        self.platform = platform
        self.dns = dns
        self.id = id
        self.fp = fp
        self.lan = lan
    }

    enum ParseError: Error { case notDroprr, newerVersion }

    init?(string: String) {
        guard case .success(let info) = Self.parse(string) else { return nil }
        self = info
    }

    static func parse(_ string: String) -> Result<PairingInfo, ParseError> {
        if let code = oneCodeFragment(string) { return parseOneCode(code) }
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "droprr", components.host?.lowercased() == "pair" else {
            return .failure(.notDroprr)
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }   // unknown params ignored
        if let v = query["v"].flatMap(Int.init), v > version { return .failure(.newerVersion) }
        let host = query["host"] ?? ""
        let dns = query["dns"].flatMap { $0.isEmpty ? nil : $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        guard !host.isEmpty || dns != nil, let token = query["token"], !token.isEmpty else { return .failure(.notDroprr) }
        return .success(PairingInfo(name: query["name"].flatMap { $0.isEmpty ? nil : $0 } ?? dns ?? host,
                                    host: host,
                                    port: query["port"].flatMap(Int.init) ?? DroprrDefaults.port,
                                    token: token,
                                    platform: query["platform"].flatMap { $0.isEmpty ? nil : $0 },
                                    dns: dns,
                                    id: query["id"].flatMap { $0.isEmpty ? nil : $0 },
                                    fp: query["fp"].flatMap { $0.count == 64 ? $0.lowercased() : nil },
                                    lan: (query["lan"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }))
    }

    /// Whether a scanned or opened string is one of Droprr's codes: the pairing QR, droprr://join, or the website's
    /// one code (any https link whose fragment is <room>.<secret>.<fp>.<app>).
    static func isCode(_ string: String) -> Bool {
        string.lowercased().hasPrefix("droprr://pair") || oneCodeFragment(string) != nil
    }

    /// "<room>.<secret>.<fp>.<app>" from droprr://join?code=… or from the website link's fragment.
    private static func oneCodeFragment(_ string: String) -> String? {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let scheme = components.scheme?.lowercased()
        let code: String?
        if scheme == "droprr", components.host?.lowercased() == "join" {
            code = components.queryItems?.first { $0.name == "code" }?.value
        } else if scheme == "https" {
            code = components.fragment.map { $0.removingPercentEncoding ?? $0 }
        } else {
            code = nil
        }
        guard let code, code.split(separator: ".", omittingEmptySubsequences: false).count == 4 else { return nil }
        return code
    }

    private static func parseOneCode(_ code: String) -> Result<PairingInfo, ParseError> {
        let parts = code.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let data = Data(base64URL: parts[3]),
              let app = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.notDroprr) }
        if let v = app["v"] as? Int, v > version { return .failure(.newerVersion) }
        let secret = parts[1]
        guard secret.count >= 16, secret.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return .failure(.notDroprr)
        }
        let lan = (app["l"] as? [String] ?? []).filter { !$0.isEmpty }
        let tailscale = (app["h"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let dns = (app["d"] as? String).flatMap { $0.isEmpty ? nil : $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        let fp = (app["f"] as? String).flatMap { $0.count == 64 ? $0.lowercased() : nil }
        // Over the LAN only, the first LAN address stands in for the host (HTTPS, pinned to fp).
        guard let host = tailscale ?? (fp != nil ? lan.first.map(hostPart) : nil) else { return .failure(.notDroprr) }
        let name = (app["n"] as? String).map(PairRequest.displayName).flatMap { $0.isEmpty ? nil : $0 } ?? dns ?? host
        return .success(PairingInfo(name: name, host: host, port: app["port"] as? Int ?? DroprrDefaults.port, token: "",
                                    platform: (app["p"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                    dns: tailscale == nil ? nil : dns,
                                    id: (app["id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                    fp: fp, lan: lan, join: secret))
    }

    /// Where to connect: the MagicDNS name when known, since the IP can change.
    var connectHost: String { dns ?? host }

    /// Codes may only point inside the tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48, a *.ts.net name or
    /// a single-label MagicDNS name) or, when they carry a fingerprint to pin, a private LAN address.
    var pointsInsideTailnet: Bool {
        [host, dns ?? ""].filter { !$0.isEmpty }.allSatisfy { Self.isTailscaleHost($0) || (fp != nil && Self.isPrivateLAN($0)) }
            && lan.allSatisfy { Self.isPrivateLAN(Self.hostPart($0)) }
    }

    /// 10/8, 172.16/12, 192.168/16, fd00::/8 or fe80::/10.
    static func isPrivateLAN(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return b[0] == 10 || (b[0] == 172 && (b[1] & 0xf0) == 16) || (b[0] == 192 && b[1] == 168)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            return b[0] == 0xfd || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80)
        }
        return false
    }

    /// "host" from "host:port" or "[v6]:port".
    static func hostPart(_ address: String) -> String {
        if address.hasPrefix("["), let end = address.firstIndex(of: "]") { return String(address[address.index(after: address.startIndex)..<end]) }
        return address.split(separator: ":").first.map(String.init) ?? address
    }

    static func isTailscaleHost(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let b = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return b[0] == 100 && (b[1] & 0xc0) == 64
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            return b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0
        }
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return name.hasSuffix(".ts.net") || !name.contains(".")
    }

    /// The Tailscale host to fall back on; empty when the code only reaches the desktop over the LAN.
    var tailnetHost: String { Self.isTailscaleHost(connectHost) ? connectHost : "" }

    var peer: Peer {
        var peer = Peer(name: name, host: tailnetHost, port: port, platform: platform, remoteName: name,
                        token: token.isEmpty ? nil : token)
        peer.deviceID = id
        peer.fingerprint = fp
        peer.tlsPort = port + 1
        if fp != nil {
            peer.lan = lan.isEmpty && Self.isPrivateLAN(connectHost) ? ["\(connectHost):\(port + 1)"] : lan
            peer.lanSeen = Date()
        }
        return peer
    }

    /// This device's Tailscale IPv4 address (100.64.0.0/10), if Tailscale is connected.
    static func tailscaleAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = pointer.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let b = withUnsafeBytes(of: ip) { Array($0) }   // network byte order
            if b[0] == 100 && (b[1] & 0xc0) == 64 {
                return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
            }
        }
        return nil
    }
}

extension DroprrSettings {
    /// Applies a scanned pairing code: add or update that desktop with its own token.
    /// Each desktop generates its own token, so it's stored per device and sent only to that device.
    @discardableResult
    func apply(_ pairing: PairingInfo) -> Peer {
        let addresses = [pairing.host, pairing.dns].compactMap { $0 }.filter { !$0.isEmpty }
        if let i = peers.firstIndex(where: { peer in
            (pairing.id != nil && peer.deviceID == pairing.id)
                || addresses.contains { peer.host.caseInsensitiveCompare($0) == .orderedSame } || peer.matches(deviceName: pairing.name)
        }) {
            let fresh = pairing.peer
            peers[i].name = pairing.name
            if !fresh.host.isEmpty { peers[i].host = fresh.host }
            // Pairing again is what replaces a pinned fingerprint.
            peers[i].deviceID = fresh.deviceID ?? peers[i].deviceID
            if let fp = fresh.fingerprint { peers[i].fingerprint = fp }
            if fresh.lan != nil { peers[i].lan = fresh.lan; peers[i].lanSeen = fresh.lanSeen; peers[i].tlsPort = fresh.tlsPort }
            peers[i].port = pairing.port
            peers[i].platform = pairing.platform ?? peers[i].platform
            peers[i].remoteName = pairing.name
            peers[i].token = pairing.token
            lastPeerID = peers[i].id
            return peers[i]
        }
        let peer = pairing.peer
        peers.append(peer)
        lastPeerID = peer.id
        mergeDuplicates()   // already known by its device id under another address
        return peers.first { $0.id == lastPeerID } ?? peer
    }
}

extension DroprrSettings {
    /// After a computer is added (or its token changed) by hand: introduce this device with POST /pair
    /// so both sides switch to per-device tokens. This device also mints a token for the other side to use
    /// when calling back (a phone only accepts it while Droprr is open on it). If the other device is too
    /// old for /pair, the hand-entered token simply keeps being used.
    @MainActor
    func exchangeTokens(with peer: Peer) async {
        guard !peer.isPhone, let token = peer.token, !token.isEmpty else { return }
        let isComputer = DroprrSettings.platform != "ios"
        let minted: String? = DroprrSettings.generateToken()
        do {
            let result = try await DroprrClient.connect(peer).client.pair(
                name: deviceName, platform: DroprrSettings.platform,
                host: isComputer ? PairingInfo.tailscaleAddress() : nil,
                port: isComputer ? port : nil, token: minted)
            guard let i = peers.firstIndex(where: { $0.id == peer.id }) else { return }
            if let newToken = result.token { peers[i].token = newToken }
            if let minted { peers[i].acceptToken = minted }
            peers[i].remoteName = result.name
            learn(peer.id, deviceID: result.deviceID, fingerprint: result.fingerprint, tlsPort: result.tlsPort,
                  lan: result.lan, host: result.host, replacePin: true)
        } catch {
            // Keep the hand-entered token; the next Test shows whether it works.
        }
    }
}
