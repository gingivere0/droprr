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
    /// A browser's or phone's code: "ios" when the host is an iPhone (docs/PROTOCOL.md, "Phones as hosts").
    var kind: String?

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

    var isBrowser: Bool { platform == "web" }

    /// A computer's packed one code, whose name, id, and full fingerprint come from the /pair answer. Older JSON
    /// codes always carry the id.
    var isPackedComputer: Bool { join != nil && !isBrowser && id == nil }

    /// Packed app details for a browser or iPhone host (docs/PROTOCOL.md, "App details"): the name, cut to 32 UTF-8
    /// bytes on a character boundary.
    static func namedAppDetails(platform: UInt8, name: String) -> String {
        var bytes: [UInt8] = []
        for character in name {
            let utf8 = Array(String(character).utf8)
            if bytes.count + utf8.count > 32 { break }
            bytes += utf8
        }
        return Data([2, platform, 0] + bytes).base64URL
    }

    /// Packed app details for a computer: the LAN certificate fingerprint's first 16 bytes, the Tailscale IPv4
    /// address, the HTTP port when it isn't the default (HTTPS is that + 1), and up to four LAN IPv4 addresses.
    static func computerAppDetails(platform: UInt8, fingerprint: String?, tailscale: String?, port: Int,
                                   lan: [String]) -> String {
        var bytes: [UInt8] = [2, platform, 0]
        var flags: UInt8 = 0
        func ipv4(_ text: String) -> [UInt8]? {
            let parts = text.split(separator: ".").compactMap { UInt8($0) }
            return parts.count == 4 && text.split(separator: ".").count == 4 ? parts : nil
        }
        if let fingerprint, fingerprint.count >= 32 {
            var hex = Substring(fingerprint.prefix(32))
            var prefix: [UInt8] = []
            while !hex.isEmpty, let byte = UInt8(hex.prefix(2), radix: 16) { prefix.append(byte); hex = hex.dropFirst(2) }
            if prefix.count == 16 { flags |= 1; bytes += prefix }
        }
        if let tailscale, let address = ipv4(tailscale) { flags |= 2; bytes += address }
        if port != DroprrDefaults.port { flags |= 4; bytes += [UInt8(port >> 8 & 0xFF), UInt8(port & 0xFF)] }
        bytes[2] = flags
        bytes += lan.map(hostPart).compactMap(ipv4).prefix(4).flatMap { $0 }
        return Data(bytes).base64URL
    }

    /// A packed code's app details (docs/PROTOCOL.md, "App details"), in the shape of the older JSON ones: format 2,
    /// a platform, flags, then the fields the flags name and LAN IPv4 addresses (computers) or a name (browsers and
    /// iPhones).
    private static func appDetails(_ data: Data) -> [String: Any]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == 2 else { return nil }
        let platform = bytes[1], flags = bytes[2]
        var i = 3
        func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard i + n <= bytes.count else { return nil }
            defer { i += n }
            return bytes[i..<(i + n)]
        }
        func ipv4(_ b: ArraySlice<UInt8>) -> String { b.map(String.init).joined(separator: ".") }
        var app: [String: Any] = ["v": 1]
        switch platform {
        case 1, 2:
            app["p"] = platform == 1 ? "windows" : "macos"
            app["n"] = platform == 1 ? "your PC" : "your Mac"
            if flags & 1 != 0 {
                guard let fp = take(16) else { return nil }
                app["f"] = fp.map { String(format: "%02x", $0) }.joined()
            }
            if flags & 2 != 0 {
                guard let address = take(4) else { return nil }
                app["h"] = ipv4(address)
            }
            var port = DroprrDefaults.port
            if flags & 4 != 0 {
                guard let p = take(2) else { return nil }
                port = Int(p[p.startIndex]) << 8 | Int(p[p.startIndex + 1])
            }
            app["port"] = port
            var lan: [String] = []
            while let address = take(4) { lan.append("\(ipv4(address)):\(port + 1)") }
            app["l"] = lan
        case 3, 4:
            app["p"] = "web"
            if platform == 4 { app["k"] = "ios" }
            if let name = String(bytes: bytes[i...], encoding: .utf8), !name.isEmpty { app["n"] = name }
        default:
            return nil
        }
        return app
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
        guard let data = Data(base64URL: parts[3]), let first = data.first else { return .failure(.notDroprr) }
        let app: [String: Any]
        if first == UInt8(ascii: "{") {
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.notDroprr) }
            app = json
        } else if first == 2 {
            guard let packed = appDetails(data) else { return .failure(.notDroprr) }
            app = packed
        } else {
            return .failure(.newerVersion)
        }
        if let v = app["v"] as? Int, v > version { return .failure(.newerVersion) }
        let secret = parts[1]
        guard secret.count >= 16, secret.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return .failure(.notDroprr)
        }
        // A browser's own code (docs/PROTOCOL.md, "Browsers as hosts"): joined as a WebRTC guest, never /pair.
        // The room goes in id and the browser's DTLS fingerprint (base64url) in fp.
        if app["p"] as? String == "web" {
            let room = parts[0], dtls = parts[2]
            // The room and key are 22 characters in current codes (their first 22), 43 in older ones.
            let base64url = { (text: String) in
                (text.count == 22 || text.count == 43) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
            }
            guard base64url(room), base64url(dtls) else { return .failure(.notDroprr) }
            let name = (app["n"] as? String).map(PairRequest.displayName).flatMap { $0.isEmpty ? nil : $0 } ?? "Browser"
            var info = PairingInfo(name: name, host: "", port: DroprrDefaults.port, token: "", platform: "web",
                                   id: room, fp: dtls, join: secret)
            info.kind = app["k"] as? String
            return .success(info)
        }
        let lan = (app["l"] as? [String] ?? []).filter { !$0.isEmpty }
        let tailscale = (app["h"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let dns = (app["d"] as? String).flatMap { $0.isEmpty ? nil : $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        // A packed code carries the fingerprint's first 16 bytes (32 hex characters): a pin prefix, replaced by the
        // full fingerprint from the /pair answer.
        let fp = (app["f"] as? String).flatMap { $0.count == 64 || $0.count == 32 ? $0.lowercased() : nil }
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
