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
