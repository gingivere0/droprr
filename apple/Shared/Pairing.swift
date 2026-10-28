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

    static let version = 1

    var url: URL? {
        // Strict RFC 3986 encoding: only unreserved characters stay literal (see "Pairing QR" in PROTOCOL.md).
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value }
        var fields = [("v", String(Self.version)), ("name", name), ("host", host), ("port", String(port)), ("token", token)]
        if let platform { fields.append(("platform", platform)) }
        if let dns { fields.append(("dns", dns)) }
        return URL(string: "droprr://pair?" + fields.map { "\($0)=\(encode($1))" }.joined(separator: "&"))
    }

    init(name: String, host: String, port: Int, token: String, platform: String?, dns: String? = nil) {
        self.name = name
        self.host = host
        self.port = port
        self.token = token
        self.platform = platform
        self.dns = dns
    }

    enum ParseError: Error { case notDroprr, newerVersion }

    init?(string: String) {
        guard case .success(let info) = Self.parse(string) else { return nil }
        self = info
    }

    static func parse(_ string: String) -> Result<PairingInfo, ParseError> {
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
                                    dns: dns))
    }

    /// Where to connect: the MagicDNS name when known, since the IP can change.
    var connectHost: String { dns ?? host }

    /// Codes may only point inside the tailnet: 100.64.0.0/10, fd7a:115c:a1e0::/48,
    /// a *.ts.net name, or a single-label MagicDNS name.
    var pointsInsideTailnet: Bool {
        [host, dns ?? ""].filter { !$0.isEmpty }.allSatisfy(Self.isTailscaleHost)
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

    var peer: Peer {
        Peer(name: name, host: connectHost, port: port, platform: platform, remoteName: name, token: token)
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
            addresses.contains { peer.host.caseInsensitiveCompare($0) == .orderedSame } || peer.matches(deviceName: pairing.name)
        }) {
            peers[i].name = pairing.name
            peers[i].host = pairing.connectHost
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
        return peer
    }
}

extension DroprrSettings {
    /// After a computer is added (or its token changed) by hand: introduce this device with POST /pair
    /// so both sides switch to per-device tokens. Computers also mint a token for the other side to use
    /// when calling back; phones don't, since nothing can call a phone. If the other device is too old
    /// for /pair, the hand-entered token simply keeps being used.
    @MainActor
    func exchangeTokens(with peer: Peer) async {
        guard !peer.isPhone, let token = peer.token, !token.isEmpty else { return }
        let isComputer = DroprrSettings.platform != "ios"
        let minted = isComputer ? DroprrSettings.generateToken() : nil
        do {
            let result = try await DroprrClient(peer: peer).pair(
                name: deviceName, platform: DroprrSettings.platform,
                host: isComputer ? PairingInfo.tailscaleAddress() : nil,
                port: isComputer ? port : nil, token: minted)
            guard let i = peers.firstIndex(where: { $0.id == peer.id }) else { return }
            if let newToken = result.token { peers[i].token = newToken }
            if let minted { peers[i].acceptToken = minted }
            peers[i].remoteName = result.name
        } catch {
            // Keep the hand-entered token; the next Test shows whether it works.
        }
    }
}
