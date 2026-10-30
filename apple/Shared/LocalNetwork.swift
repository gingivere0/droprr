import CryptoKit
import Foundation
import Network
import Observation
import Security

enum Bonjour {
    static let serviceType = "_droprr._tcp"
}

/// This device's own LAN addresses, for the `lan` fields in /ping, /pair and the pairing QR code.
enum LocalAddresses {
    /// Private IPv4 (10/8, 172.16/12, 192.168/16) and non-Tailscale ULA IPv6 addresses as "host:port".
    static func lan(port: Int) -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                let b = withUnsafeBytes(of: addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }) { Array($0) }
                guard b[0] == 10 || (b[0] == 172 && (b[1] & 0xf0) == 16) || (b[0] == 192 && b[1] == 168) else { continue }
                getnameinfo(addr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                result.append("\(String(cString: host)):\(port)")
            case AF_INET6:
                let b = withUnsafeBytes(of: addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }) { Array($0) }
                // fd00::/8 except Tailscale's fd7a:115c:a1e0::/48 (that's the Tailscale path).
                guard b[0] == 0xfd, !(b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c) else { continue }
                getnameinfo(addr, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                result.append("[\(String(cString: host))]:\(port)")
            default:
                continue
            }
        }
        return Array(Set(result)).sorted()
    }
}

/// A Droprr device advertising on this network.
struct NearbyDevice: Identifiable, Equatable {
    var id: String          // its device id (TXT "id")
    var name: String
    var platform: String
    var fingerprint: String
    var port: Int
    var endpoint: NWEndpoint

    static func == (a: NearbyDevice, b: NearbyDevice) -> Bool {
        a.id == b.id && a.name == b.name && a.fingerprint == b.fingerprint && a.port == b.port
    }
}

/// Browses for `_droprr._tcp`. Discovery never grants trust: it only records the LAN addresses of
/// paired peers whose advertised id and fingerprint match what's pinned, and lists the rest for pairing.
@Observable
@MainActor
final class LANDiscovery {
    static let shared = LANDiscovery()

    /// Devices advertising right now, other than this one.
    private(set) var nearby: [NearbyDevice] = []

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var refresh: Timer?
    @ObservationIgnored private let settings = DroprrSettings.shared

    func start() {
        guard browser == nil, settings.localNetwork else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Bonjour.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        // A network change can fail the browser; start a new one shortly instead of going quiet.
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard case .failed = state else { return }
            Task { @MainActor in
                guard let self, let browser, self.browser === browser else { return }
                self.stop()
                try? await Task.sleep(for: .seconds(3))
                self.start()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        // While a peer keeps advertising, keep its LAN address fresh (sends use it for 2 minutes).
        refresh = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.resolveKnown() }
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        refresh?.invalidate()
        refresh = nil
        nearby = []
    }

    /// True when a paired peer is advertising right now (for example, the iPhone with Droprr open).
    func isAdvertising(_ peer: Peer) -> Bool {
        guard let id = peer.deviceID else { return false }
        return nearby.contains { $0.id == id && $0.fingerprint == peer.fingerprint }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var found: [NearbyDevice] = []
        for result in results {
            guard case .bonjour(let txt) = result.metadata, let id = txt["id"], id != settings.deviceID,
                  let fp = txt["fp"]?.lowercased(), fp.count == 64 else { continue }
            var name = txt["name"] ?? ""
            if name.isEmpty, case .service(let serviceName, _, _, _) = result.endpoint { name = serviceName }
            found.append(NearbyDevice(id: id, name: name, platform: txt["platform"] ?? "",
                                      fingerprint: fp, port: Int(txt["port"] ?? "") ?? settings.tlsPort, endpoint: result.endpoint))
        }
        found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if found != nearby { nearby = found }
        resolveKnown()
    }

    /// Resolves each paired, matching device to an address and records it on the peer.
    private func resolveKnown() {
        for device in nearby {
            guard let peer = settings.peers.first(where: { $0.deviceID == device.id }),
                  peer.fingerprint == device.fingerprint else { continue }
            Self.resolve(device.endpoint) { [weak self] host in
                guard let self, let host else { return }
                let address = host.contains(":") ? "[\(host)]:\(device.port)" : "\(host):\(device.port)"
                guard let i = self.settings.peers.firstIndex(where: { $0.id == peer.id }) else { return }
                self.settings.peers[i].lan = [address]
                self.settings.peers[i].lanSeen = Date()
                self.settings.peers[i].tlsPort = device.port
            }
        }
    }

    /// The numeric address behind a Bonjour service, found by opening (then closing) a TCP connection.
    nonisolated static func resolve(_ endpoint: NWEndpoint, completion: @escaping @MainActor (String?) -> Void) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4   // IPv4 avoids link-local IPv6 scope ids in URLs
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        var done = false
        let finish: (String?) -> Void = { host in
            guard !done else { return }
            done = true
            connection.cancel()
            Task { @MainActor in completion(host) }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
                    finish("\(host)".components(separatedBy: "%").first)
                } else {
                    finish(nil)
                }
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(nil) }
    }
}

/// Pairing with a device that discovery found (POST /pair/request): no QR code and no token shown.
/// Both screens show the same six digits; the other device's person confirms.
enum LANPairing {
    enum Failure: LocalizedError {
        case unreachable, declined, timedOut, busy, identityMismatch, needsUpdate(String), other(String)
        var errorDescription: String? {
            switch self {
            case .unreachable: return "Couldn't reach it on this Wi-Fi."
            case .declined: return "It declined."
            case .timedOut: return "Nobody answered on the other device."
            case .busy: return "It's busy with another pairing. Try again in a few minutes."
            case .needsUpdate(let name): return "Update Droprr on \(name), then pair again."
            case .identityMismatch: return "Identity mismatch: the device that answered isn't the one advertised on this Wi-Fi."
            case .other(let message): return message
            }
        }
    }

    /// Connects, shows `code` through `onCode` as soon as it's known, waits for the answer, and saves the peer.
    @MainActor
    static func pair(with device: NearbyDevice, settings: DroprrSettings = .shared,
                     onCode: @escaping (String) -> Void) async throws -> Peer {
        guard let ownFP = settings.identity?.fingerprint else { throw Failure.other("This device has no certificate yet.") }
        let host: String? = await withCheckedContinuation { done in LANDiscovery.resolve(device.endpoint) { done.resume(returning: $0) } }
        guard let host else { throw Failure.unreachable }
        let address = host.contains(":") ? "[\(host)]:\(device.port)" : "\(host):\(device.port)"

        // No pin yet: accept the certificate, but remember it. The six-digit code is what proves it.
        // It must at least present the certificate it advertises; the code then confirms it end to end.
        let capture = CapturedTrust(expected: device.fingerprint)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 75   // the other side waits up to 60 s for the person
        let session = URLSession(configuration: config, delegate: capture, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        capture.identity = settings.identity?.secIdentity

        func post(_ path: String, _ body: [String: Any]) async throws -> (Int, [String: Any]) {
            guard let url = URL(string: "https://\(address)\(path)") else { throw Failure.unreachable }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            do {
                let (data, response) = try await session.data(for: request)
                return ((response as? HTTPURLResponse)?.statusCode ?? 0,
                        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
            } catch {
                throw capture.mismatch ? Failure.identityMismatch : Failure.unreachable
            }
        }

        // An older Droprr answers 409 for a device it already has. If this device can already send to it, that's
        // connected; otherwise only an update there helps (newer versions pair again instead).
        func alreadyConnected() throws -> Peer {
            if let peer = settings.peers.first(where: {
                ($0.deviceID == device.id || $0.fingerprint == device.fingerprint) && !($0.token ?? "").isEmpty
            }) { return peer }
            throw Failure.needsUpdate(PairRequest.displayName(device.name))
        }

        // Step 1: commit to a random nonce before seeing the other device's (pairing v2).
        var nonceR = Data(count: 32)
        _ = nonceR.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let commit = Data(SHA256.hash(data: nonceR)).hexString
        let (first, opened) = try await post("/pair/request", ["id": settings.deviceID, "name": settings.deviceName,
                                                               "platform": DroprrSettings.platform, "commit": commit, "fp": ownFP])
        switch first {
        case 200: break
        case 409: return try alreadyConnected()
        case 429: throw Failure.busy
        default: throw Failure.other(opened["error"] as? String ?? "It answered \(first).")
        }
        guard let sessionID = opened["session"] as? String, let nonceS = (opened["nonce"] as? String).flatMap(Data.init(hex:)),
              nonceS.count == 32, let fpServer = capture.fingerprint else {
            throw Failure.other("It didn't start the pairing.")
        }
        onCode(DroprrReceiver.pairingCode(fpA: ownFP, fpB: fpServer, nonceR: nonceR, nonceS: nonceS))

        // Step 2: reveal the nonce with what this device offers, and wait for the person to answer there.
        let isComputer = DroprrSettings.platform != "ios"
        let minted = DroprrSettings.generateToken()
        var body: [String: Any] = ["session": sessionID, "nonce": nonceR.hexString, "token": minted,
                                   "tlsPort": settings.tlsPort, "lan": LocalAddresses.lan(port: settings.tlsPort)]
        if isComputer {
            if let tailscale = PairingInfo.tailscaleAddress() { body["host"] = tailscale }
            body["port"] = settings.port
        }
        let (status, json) = try await post("/pair/confirm", body)

        switch status {
        case 200: break
        case 403: throw Failure.declined
        case 408: throw Failure.timedOut
        case 429: throw Failure.busy
        case 409: return try alreadyConnected()
        default: throw Failure.other(json["error"] as? String ?? "It answered \(status).")
        }
        guard let token = (json["token"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw Failure.other("It answered without a token.")
        }

        let name = PairRequest.displayName(json["name"] as? String ?? device.name)
        // Only the device discovery found (its id or certificate); never a name match.
        // An id alone (from unauthenticated Bonjour data) only matches a peer with no pin yet; a pinned peer
        // must have this exact certificate. Otherwise it's a new entry, never an overwrite.
        let match = settings.peers.firstIndex { $0.fingerprint == fpServer }
            ?? settings.peers.firstIndex { $0.deviceID == device.id && $0.fingerprint == nil }
        let peerID: UUID
        if let i = match {
            settings.peers[i].remoteName = name
            settings.peers[i].platform = device.platform.isEmpty ? settings.peers[i].platform : device.platform
            settings.peers[i].token = token
            settings.peers[i].acceptToken = minted
            peerID = settings.peers[i].id
        } else {
            let peer = Peer(name: settings.uniqueName(name), host: "", platform: device.platform.isEmpty ? nil : device.platform,
                            remoteName: name, token: token, acceptToken: minted)
            settings.peers.append(peer)
            peerID = peer.id
        }
        var lan = json["lan"] as? [String] ?? []
        if lan.isEmpty { lan = [address] }
        settings.learn(peerID, deviceID: device.id, fingerprint: fpServer,
                       tlsPort: json["tlsPort"] as? Int ?? device.port, lan: lan, host: json["host"] as? String, replacePin: true)
        settings.lastPeerID = peerID
        if let peer = settings.peers.first(where: { $0.id == peerID || $0.fingerprint == fpServer }) { return peer }
        throw Failure.other("Paired, but the device entry couldn't be found.")
    }
}

/// Trusts any server certificate once, recording its fingerprint (LAN pairing only).
private final class CapturedTrust: NSObject, URLSessionDelegate {
    private(set) var fingerprint: String?
    private(set) var mismatch = false
    let expected: String
    var identity: SecIdentity?

    init(expected: String) {
        self.expected = expected.lowercased()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            // Present this device's certificate: the receiver takes the requester's identity from it.
            return completionHandler(identity == nil ? .performDefaultHandling : .useCredential,
                                     identity.map { URLCredential(identity: $0, certificates: nil, persistence: .forSession) })
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return completionHandler(.performDefaultHandling, nil)
        }
        let fp = DeviceIdentity.fingerprint(of: SecCertificateCopyData(leaf) as Data)
        guard fp == expected else {
            mismatch = true
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        fingerprint = fp
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
