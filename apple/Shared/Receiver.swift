import CryptoKit
import Foundation
import Network

/// What a desktop's outbox exposes to the receiver for the /inbox endpoints.
protocol OutboxServing: AnyObject {
    /// JSON-ready items, oldest first: for the peer with `peerID` when the request used that peer's
    /// device token, otherwise for the named phone (main token). May register an unknown phone as a peer.
    func list(for deviceName: String?, peerID: UUID?, from remoteHost: String?) -> [[String: Any]]
    /// With a `peerID`, only that peer's items are visible.
    func file(id: String, peerID: UUID?) -> (url: URL, name: String, mimeType: String)?
    func remove(id: String, peerID: UUID?) -> Bool
    /// Queues already-received items for the phone peer with this id (Mac share extension hand-off).
    func enqueue(_ items: [ReceivedItem], forPeerID id: String) throws
}

/// A device introducing itself after scanning this desktop's pairing code (POST /pair).
struct PairRequest {
    var name: String
    var platform: String
    var host: String   // empty for phones
    var port: Int
    /// The token the caller minted for this desktop to use when calling it (computers only).
    var token: String?
    /// The device token this desktop minted for the caller, to accept from it.
    var acceptToken: String
    // Protocol 2, when the caller sends them.
    var deviceID: String?
    var fingerprint: String?
    var tlsPort: Int?
    var lan: [String]?
    /// Set when the caller authenticated with a device token: update that peer rather than adding one.
    var existingPeerID: UUID?
    /// LAN pairing (/pair/request): always a new entry, never matched by name.
    var viaLAN = false
}

extension PairRequest {
    /// A peer-supplied name, safe to show: no control or bidi-override characters, at most 64 characters.
    static func displayName(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !(0x202A...0x202E).contains(scalar.value) && !(0x2066...0x2069).contains(scalar.value)
                && scalar.value != 0x200E && scalar.value != 0x200F && scalar.value != 0x061C
        }
        return String(String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
    }
}

/// A device asking to pair over the LAN (POST /pair/request), waiting for the person to confirm.
struct LANPairRequest {
    var name: String
    var platform: String
    /// The six digits both screens show.
    var code: String
}

struct ReceivedItem: Identifiable {
    enum Kind {
        case file(URL)
        case text(String)
        case url(URL)
    }

    var id = UUID()
    let kind: Kind
    var date = Date()

    var title: String {
        switch kind {
        case .file(let url): return url.lastPathComponent
        case .text(let text): return text.count > 60 ? String(text.prefix(60)) + "…" : text
        case .url(let url): return url.absoluteString
        }
    }
}

/// Implements the receiving half of docs/PROTOCOL.md on top of HTTPServer.
final class DroprrReceiver {
    private let server = HTTPServer()
    /// Protocol 2: HTTPS on the HTTP port + 1, for the LAN (and optionally Tailscale).
    private var secureServer: HTTPServer?
    /// Browser access over Wi-Fi: HTTPS on the HTTP port + 2, without a client certificate (desktops only).
    private var browserServer: HTTPServer?
    /// The "Open in a browser" code; nil (iPhone) turns Browser access off.
    var browserAccess: BrowserAccess?
    /// Saves a browser that used the code as a new "web" peer and returns its name. Called on the main queue.
    var addBrowser: ((PairRequest) -> String)?
    /// A browser signed itself out. Called on the main queue with its peer id.
    var onBrowserRemoved: ((UUID) -> Void)?
    /// This device's MagicDNS name, if Tailscale has one: a Host a browser may use.
    private var magicDNS: String?
    private let settings: DroprrSettings
    private let inbox: URL

    /// Called on the main queue for every item received.
    var onItem: (ReceivedItem) -> Void = { _ in }
    var onStateChange: (String) -> Void = { _ in }
    /// Desktops serve the phone inbox from this; nil (iPhone) means /inbox is 404.
    var outbox: OutboxServing?
    /// Desktops handle POST /pair with this. Called on the main queue.
    var onPair: ((PairRequest) -> Void)?
    /// Asks the person to confirm a LAN pairing; true to accept. Called on the main queue.
    /// The receiver answers 408 itself if this hasn't returned after 60 seconds.
    var onPairRequest: ((LANPairRequest) async -> Bool)?

    init(settings: DroprrSettings, inbox: URL) {
        self.settings = settings
        self.inbox = inbox
        server.precheck = { [weak self] request in self?.precheck(request) }
        server.bodyLimit = Self.bodyLimit
        server.saveDirectory = inbox
        server.handler = { [weak self] request in
            await self?.handle(request) ?? .json(503, ["ok": false, "error": "shutting down"])
        }
        server.onStateChange = { state in DispatchQueue.main.async { self.onStateChange(state) } }
    }

    func start() {
        do {
            try server.start(port: settings.port)
        } catch {
            onStateChange("Couldn't listen on port \(settings.port): \(error.localizedDescription)")
        }
        startSecure()
    }

    func stop() {
        server.stop()
        secureServer?.stop()
        secureServer = nil
        browserServer?.stop()
        browserServer = nil
        settings.secureListening = false
    }

    /// 64 KB for pairing, 16 MB for bodies read whole (JSON, forms, plain text); files are streamed and only
    /// limited by free space.
    static func bodyLimit(_ request: HTTPServer.Request) -> Int {
        if Route(request).segments.first == "pair" { return 64 << 10 }
        if Route(request).segments.first == "web" { return 4 << 10 }
        let mime = (request.header("content-type") ?? "").split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        // The same rule receive() uses: only a non-empty name makes it a file.
        let suppliedName = request.header("x-droprr-filename").map { $0.removingPercentEncoding ?? $0 }
            ?? request.header("content-disposition").flatMap(Self.filename(in:)) ?? ""
        let named = !suppliedName.isEmpty
        if mime == "application/json" || mime == "application/x-www-form-urlencoded" || (mime == "text/plain" && !named) {
            return 16 << 20
        }
        return Int.max
    }

    /// Starts or stops the HTTPS listener and its Bonjour advertisement to match the Local network setting.
    func startSecure() {
        secureServer?.stop()
        secureServer = nil
        browserServer?.stop()
        browserServer = nil
        settings.secureListening = false
        if browserAccess != nil { lookUpMagicDNS() }
        guard settings.localNetwork, let identity = settings.identity?.tlsIdentity else { return }
        if browserAccess != nil {
            let browser = HTTPServer(policy: .lan, identity: identity, browserOnly: true)
            browser.precheck = server.precheck
            browser.handler = server.handler
            browser.bodyLimit = server.bodyLimit
            browser.saveDirectory = inbox
            do {
                try browser.start(port: settings.port + 2)
                browserServer = browser
            } catch {
                NSLog("Droprr: browser listener failed: %@", String(describing: error))
            }
        }
        let secure = HTTPServer(policy: .lan, identity: identity)
        secure.precheck = server.precheck
        secure.handler = server.handler
        secure.bodyLimit = server.bodyLimit
        secure.saveDirectory = inbox
        do {
            try secure.start(port: settings.tlsPort, service: bonjourService)
            secureServer = secure
            settings.secureListening = true
        } catch {
            NSLog("Droprr: HTTPS listener failed: %@", String(describing: error))
        }
    }

    /// Re-advertises after the device name changes.
    func refreshAdvertisement() {
        secureServer?.advertise(bonjourService)
    }

    /// `_droprr._tcp`, named after this device, with the protocol 2 TXT record.
    private var bonjourService: NWListener.Service? {
        guard let fp = settings.identity?.fingerprint else { return nil }
        var txt = NWTXTRecord()
        txt["v"] = "2"
        txt["id"] = settings.deviceID
        txt["name"] = settings.deviceName
        txt["platform"] = DroprrSettings.platform
        txt["port"] = String(settings.tlsPort)
        txt["fp"] = fp
        return NWListener.Service(name: settings.deviceName, type: Bonjour.serviceType, txtRecord: txt)
    }


    // MARK: - Routing

    private func precheck(_ request: HTTPServer.Request) -> HTTPServer.Response? {
        // Browser access: the page and its sign-in need no token; the browser port serves nothing else
        // except the endpoints a browser's cookie works on.
        if Self.isWebPath(request) { return browserAccess == nil ? .json(404, ["ok": false, "error": "not found"]) : nil }
        if request.browserPort && !Self.cookieAllowed(request) { return .json(404, ["ok": false, "error": "not found"]) }
        // LAN pairing is the one request without a token, and only over HTTPS.
        if request.method == "POST", ["request", "confirm"].contains(Route(request).segments.dropFirst().first ?? ""),
           Route(request).segments.count == 2, Route(request).segments.first == "pair" {
            return request.secure && onPairRequest != nil ? nil : .json(404, ["ok": false, "error": "not found"])
        }
        guard let auth = authorization(request) else {
            return .json(401, ["ok": false, "error": "unauthorized"])
        }
        // A browser's token works only where its cookie would: never /pair or anything else.
        if case .device = auth, isBrowserRequest(request), !Self.cookieAllowed(request) {
            return .json(401, ["ok": false, "error": "unauthorized"])
        }
        let route = Route(request)
        switch (request.method, route.segments.first) {
        case ("GET", "ping") where route.segments.count == 1,
             ("POST", "send") where route.segments.count == 1:
            return nil
        case ("POST", "pair") where route.segments.count == 1:
            return onPair == nil ? .json(404, ["ok": false, "error": "not found"]) : nil
        case ("POST", "outbox") where route.segments.count == 2:
            // Loopback-only hand-off from the Mac share extension: queue for a phone peer.
            return outbox != nil && Self.isLoopback(request.remoteHost) ? nil : .json(404, ["ok": false, "error": "not found"])
        case ("GET", "inbox"):
            return outbox == nil ? .json(404, ["ok": false, "error": "not found"]) : nil
        case ("DELETE", "inbox") where route.segments.count == 2:
            return outbox == nil ? .json(404, ["ok": false, "error": "not found"]) : nil
        default:
            return .json(404, ["ok": false, "error": "not found"])
        }
    }

    /// Path segments and query items of a request target.
    private struct Route {
        var segments: [String]
        var query: [String: String] = [:]

        init(_ request: HTTPServer.Request) {
            let components = URLComponents(string: request.path)
                ?? URLComponents(string: request.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            segments = (components?.path ?? request.path).split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
            for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
    }

    /// Which token authorized the request: the main token or a paired device's token.
    private func authorization(_ request: HTTPServer.Request) -> DroprrSettings.Authorization? {
        if let token = cookieToken(request) { return settings.authorize(token) }
        let header = (request.header("authorization") ?? "").trimmingCharacters(in: .whitespaces)
        guard header.lowercased().hasPrefix("bearer ") else { return nil }
        return settings.authorize(String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces))
    }

    private func handleInbox(_ request: HTTPServer.Request, _ route: Route, _ outbox: OutboxServing) -> HTTPServer.Response {
        let notFound = HTTPServer.Response.json(404, ["ok": false, "error": "not found"])
        // A device token scopes the inbox to that peer's queue and ignores ?for=.
        var peerID: UUID?
        if case .device(let id) = authorization(request) { peerID = id }
        if route.segments.count == 1 {
            guard request.method == "GET" else { return notFound }
            let name = route.query["for"].flatMap { $0.isEmpty ? nil : $0 }
            guard peerID != nil || name != nil else {
                return .json(400, ["ok": false, "error": "missing for=<device name>"])
            }
            let items = outbox.list(for: name, peerID: peerID, from: request.remoteHost)
            return .json(200, ["ok": true, "items": items])
        }
        let id = route.segments[1]
        if request.method == "DELETE" {
            return outbox.remove(id: id, peerID: peerID) ? .json(200, ["ok": true]) : notFound
        }
        guard let file = outbox.file(id: id, peerID: peerID) else { return notFound }
        var response = HTTPServer.Response(status: 200, body: Data(), contentType: file.mimeType)
        response.file = file.url
        if route.query["inline"] == "1", Self.inlineTypes.contains(file.mimeType.lowercased()) {
            // The page's View button: shown in place, sandboxed, and never as HTML or SVG.
            response.headers["Content-Security-Policy"] = "sandbox; default-src 'none'; img-src 'self'; media-src 'self'"
            response.headers["X-Content-Type-Options"] = "nosniff"
            return response
        }
        let ascii = file.name.unicodeScalars.allSatisfy { $0.isASCII && $0 != "\"" }
        let fallback = String(String.UnicodeScalarView((file.name.applyingTransform(.stripDiacritics, reverse: false) ?? file.name)
            .unicodeScalars.filter { $0.isASCII && $0 != "\"" }))
        var disposition = "attachment; filename=\"\(ascii ? file.name : (fallback.isEmpty ? "download" : fallback))\""
        if !ascii, let encoded = file.name.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) {
            disposition += "; filename*=UTF-8''\(encoded)"
        }
        response.headers["Content-Disposition"] = disposition
        return response
    }

    private func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        let route = Route(request)
        if Self.isWebPath(request) { return await handleWeb(request, route as Any) }
        if route.segments.first == "inbox", let outbox {
            return handleInbox(request, route, outbox)
        }
        if route.segments == ["pair", "request"] {
            return await handlePairRequest(request)
        }
        if route.segments == ["pair", "confirm"] {
            return await handlePairConfirm(request)
        }
        if route.segments.first == "pair", let onPair {
            guard let body = request.bodyFile, let data = try? Data(contentsOf: body),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .json(400, ["ok": false, "error": "expected a JSON body"])
            }
            guard let name = (json["name"] as? String).map(PairRequest.displayName), !name.isEmpty else {
                return .json(400, ["ok": false, "error": "missing name"])
            }
            guard let platform = (json["platform"] as? String)?.lowercased(), ["ios", "macos", "windows"].contains(platform) else {
                return .json(400, ["ok": false, "error": "platform must be ios, macos or windows"])
            }
            var host = (json["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if platform != "ios" && host.isEmpty {
                return .json(400, ["ok": false, "error": "computers must send host"])
            }
            // Plain HTTP only ever goes to Tailscale, so only keep a Tailscale host.
            if !PairingInfo.isTailscaleHost(host) { host = "" }
            var port = DroprrDefaults.port
            if let raw = json["port"], !(raw is NSNull) {
                guard let value = raw as? Int, (1...65535).contains(value) else {
                    return .json(400, ["ok": false, "error": "bad port"])
                }
                port = value
            }
            let callerToken = (json["token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let minted = DroprrSettings.generateToken()
            // Store before answering, so the caller's very next request with the new token is accepted.
            // Protocol 2 phones also mint a token, for direct sends while Droprr is open on them.
            var existing: UUID?
            if case .device(let id) = authorization(request) { existing = id }
            let pair = PairRequest(name: name, platform: platform, host: host, port: port,
                                   token: callerToken, acceptToken: minted,
                                   deviceID: Self.deviceID(json["id"]), fingerprint: Self.fingerprint(json["fp"]),
                                   tlsPort: json["tlsPort"] as? Int, lan: json["lan"] as? [String], existingPeerID: existing)
            DispatchQueue.main.sync { onPair(pair) }
            return .json(200, responseFields(token: minted))
        }
        if route.segments.first == "outbox", let outbox {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("droprr-fwd-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                let items = try receive(request, into: temp)
                guard !items.isEmpty else { throw Failure(400, "no items") }
                try outbox.enqueue(items, forPeerID: route.segments[1])
                return .json(200, ["ok": true, "received": items.count])
            } catch let failure as Failure {
                return .json(failure.status, ["ok": false, "error": failure.message])
            } catch {
                NSLog("Droprr receiver error: %@", String(describing: error))
                return .json(500, ["ok": false, "error": "receiver error"])
            }
        }
        if route.segments.first == "ping" {
            if let token = cookieToken(request), let peer = browserPeer(token) {
                // A browser: say which device it is, and keep its cookie alive for another 30 days.
                var response = HTTPServer.Response.json(200, ["name": settings.deviceName, "version": DroprrDefaults.version,
                                                              "platform": DroprrSettings.platform, "protocol": 2, "you": peer.name])
                response.headers["Set-Cookie"] = Self.cookie(token, secure: request.secure)
                return response
            }
            return .json(200, ["name": settings.deviceName, "version": DroprrDefaults.version,
                               "platform": DroprrSettings.platform, "protocol": 2].merging(settings.identityFields(includeLAN: false)) { a, _ in a })
        }
        do {
            let items = try receive(request, into: inbox)
            guard !items.isEmpty else { throw Failure(400, "no items") }
            for case .file(let url) in items.map(\.kind) { Links.quarantine(url) }
            let onItem = self.onItem
            DispatchQueue.main.async { items.forEach(onItem) }
            return .json(200, ["ok": true, "received": items.count])
        } catch let failure as Failure {
            return .json(failure.status, ["ok": false, "error": failure.message])
        } catch {
            NSLog("Droprr receiver error: %@", String(describing: error))
            return .json(500, ["ok": false, "error": "receiver error"])
        }
    }

    /// The /pair and /pair/request answer: this device's name, the minted token, its protocol 2 identity,
    /// and its Tailscale host so a device paired over the LAN still has a fallback.
    private func responseFields(token: String) -> [String: Any] {
        var fields: [String: Any] = ["ok": true, "name": settings.deviceName, "token": token]
        fields.merge(settings.ownIdentityFields) { a, _ in a }
        if let host = PairingInfo.tailscaleAddress() { fields["host"] = host }
        return fields
    }

    // MARK: - LAN pairing v2 (POST /pair/request, POST /pair/confirm)

    /// An open pairing: the requester's commitment and certificate, and this device's nonce.
    private struct PairSession {
        var id: String
        var requesterID: String
        var name: String
        var platform: String
        var commit: Data
        var clientFingerprint: String
        var nonceS: Data
        var created: Date
        var prompting = false
    }

    private let pairLock = NSLock()
    private var pairSession: PairSession?
    private var pairStrikes: [String: [Date]] = [:]

    /// A protocol device id: 26 lowercase base32 characters.
    private static func deviceID(_ value: Any?) -> String? {
        guard let text = (value as? String)?.lowercased(), text.count == 26,
              text.allSatisfy({ ("a"..."z").contains($0) || ("2"..."7").contains($0) }) else { return nil }
        return text
    }

    private static func fingerprint(_ value: Any?) -> String? {
        guard let text = (value as? String)?.lowercased(), text.count == 64, text.allSatisfy(\.isHexDigit) else { return nil }
        return text
    }

    /// The six digits both devices show: SHA-256 of "fpLow:fpHigh:nonceR:nonceS" (lowercase hex),
    /// first 4 bytes as a big-endian integer, modulo 1,000,000.
    static func pairingCode(fpA: String, fpB: String, nonceR: Data, nonceS: Data) -> String {
        let fps = [fpA.lowercased(), fpB.lowercased()].sorted()
        let text = "\(fps[0]):\(fps[1]):\(nonceR.hexString):\(nonceS.hexString)"
        let digest = Array(SHA256.hash(data: Data(text.utf8)))
        let value = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
        return String(format: "%06u", value % 1_000_000)
    }

    private func readJSON(_ request: HTTPServer.Request) -> [String: Any]? {
        guard let body = request.bodyFile, let data = try? Data(contentsOf: body) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Three declines, timeouts or wrong reveals from one address within 10 minutes: 429 for 10 minutes.
    private func isBlocked(_ address: String) -> Bool {
        pairLock.withLock {
            let now = Date()
            pairStrikes[address] = pairStrikes[address]?.filter { now.timeIntervalSince($0) < 600 }
            return (pairStrikes[address]?.count ?? 0) >= 3
        }
    }

    private func strike(_ address: String) {
        pairLock.withLock { pairStrikes[address, default: []].append(Date()) }
    }

    /// Step 1: the requester commits to its nonce; this device answers with its own right away.
    private func handlePairRequest(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        guard onPairRequest != nil, onPair != nil, settings.identity != nil else { return .json(404, ["ok": false, "error": "not found"]) }
        let address = request.remoteHost ?? ""
        guard let clientFP = request.clientFingerprint else {
            return .json(400, ["ok": false, "error": "a client certificate is required"])
        }
        guard let json = readJSON(request),
              let id = Self.deviceID(json["id"]),
              let name = (json["name"] as? String).map(PairRequest.displayName), !name.isEmpty,
              let platform = (json["platform"] as? String)?.lowercased(), ["ios", "macos", "windows"].contains(platform),
              let commitHex = (json["commit"] as? String)?.lowercased(), let commit = Data(hex: commitHex), commit.count == 32 else {
            return .json(400, ["ok": false, "error": "expected id, name, platform and commit"])
        }
        if let bodyFP = json["fp"] { guard Self.fingerprint(bodyFP) == clientFP else {
            return .json(400, ["ok": false, "error": "fp doesn't match the client certificate"])
        } }
        if isBlocked(address) { return .json(429, ["ok": false, "error": "try again later"]) }
        // Already paired (same id or certificate): LAN pairing never touches an existing peer.
        let known = await MainActor.run { [settings] in
            settings.peers.contains { $0.deviceID == id || $0.fingerprint == clientFP }
        }
        if known { return .json(409, ["ok": false, "error": "already paired; remove it on this device to pair again"]) }

        var nonceS = Data(count: 32)
        _ = nonceS.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let session = PairSession(id: UUID().uuidString.lowercased(), requesterID: id, name: name, platform: platform,
                                  commit: commit, clientFingerprint: clientFP, nonceS: nonceS, created: Date())
        let opened: Bool = pairLock.withLock {
            if let open = pairSession, open.prompting || Date().timeIntervalSince(open.created) < 30 { return false }
            pairSession = session
            return true
        }
        guard opened else { return .json(429, ["ok": false, "error": "another pairing is in progress"]) }
        return .json(200, ["ok": true, "session": session.id, "nonce": nonceS.hexString])
    }

    /// Step 2: the requester reveals its nonce; check it, ask the person, and pair on Pair.
    private func handlePairConfirm(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        guard let ask = onPairRequest, let onPair, let ownFP = settings.identity?.fingerprint else {
            return .json(404, ["ok": false, "error": "not found"])
        }
        let address = request.remoteHost ?? ""
        let notFound = HTTPServer.Response.json(404, ["ok": false, "error": "no such pairing"])
        guard let clientFP = request.clientFingerprint, let json = readJSON(request),
              let sessionID = json["session"] as? String else { return notFound }
        // The open session, from the same certificate, not expired and not already being asked about.
        let session: PairSession? = pairLock.withLock {
            guard var open = pairSession, open.id == sessionID, open.clientFingerprint == clientFP,
                  !open.prompting, Date().timeIntervalSince(open.created) < 30 else { return nil }
            open.prompting = true
            pairSession = open
            return open
        }
        guard let session else { return notFound }
        defer { pairLock.withLock { if pairSession?.id == session.id { pairSession = nil } } }

        guard let nonceHex = (json["nonce"] as? String)?.lowercased(), let nonceR = Data(hex: nonceHex), nonceR.count == 32,
              Data(SHA256.hash(data: nonceR)) == session.commit else {
            strike(address)
            return .json(400, ["ok": false, "error": "the nonce doesn't match the commitment"])
        }
        let code = Self.pairingCode(fpA: ownFP, fpB: session.clientFingerprint, nonceR: nonceR, nonceS: session.nonceS)
        let question = LANPairRequest(name: session.name, platform: session.platform, code: code)
        let answer: Bool? = await withTaskGroup(of: Bool?.self) { group in
            group.addTask { @MainActor in await ask(question) }
            group.addTask {
                try? await Task.sleep(for: .seconds(60))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard answer == true else {
            strike(address)
            return answer == nil ? .json(408, ["ok": false, "error": "timed out"]) : .json(403, ["ok": false, "error": "declined"])
        }
        let minted = DroprrSettings.generateToken()
        var port = DroprrDefaults.port
        if let value = json["port"] as? Int, (1...65535).contains(value) { port = value }
        let host = (json["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pair = PairRequest(name: session.name, platform: session.platform,
                               host: PairingInfo.isTailscaleHost(host) ? host : "",
                               port: port, token: (json["token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               acceptToken: minted, deviceID: session.requesterID, fingerprint: session.clientFingerprint,
                               tlsPort: json["tlsPort"] as? Int, lan: json["lan"] as? [String], viaLAN: true)
        await MainActor.run { onPair(pair) }
        return .json(200, responseFields(token: minted))
    }

    private struct Failure: Error {
        let status: Int
        let message: String
        init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    }

    private func receive(_ request: HTTPServer.Request, into dir: URL) throws -> [ReceivedItem] {
        let contentType = request.header("content-type") ?? ""
        let mime = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard let bodyFile = request.bodyFile else { throw Failure(400, "empty body") }

        switch mime {
        case "application/json", "multipart/form-data":
            break
        case "application/x-www-form-urlencoded":
            return try receiveForm(bodyFile, into: dir)
        default:
            let suppliedName = request.header("x-droprr-filename").map { $0.removingPercentEncoding ?? $0 }
                ?? request.header("content-disposition").flatMap(Self.filename(in:))
                ?? ""
            if mime == "text/plain" && suppliedName.isEmpty {
                return [try classify(String(decoding: try Data(contentsOf: bodyFile), as: UTF8.self), into: dir)]
            }
            // Lenient input: any other body is a raw file (iOS Shortcuts "File" request bodies).
            var filename = suppliedName.isEmpty ? Self.fallbackName() : suppliedName
            if (filename as NSString).pathExtension.isEmpty { filename += ".\(Self.rawExtensions[mime] ?? "bin")" }
            let dest = try saveUnique(filename, in: dir) { try FileManager.default.moveItem(at: bodyFile, to: $0) }
            Links.quarantine(dest)
            return [ReceivedItem(kind: .file(dest))]
        }

        if mime == "application/json" {
            let data = try Data(contentsOf: bodyFile)
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw Failure(400, "malformed JSON")
            }
            guard let type = object["type"] as? String, type == "text" || type == "url" else {
                throw Failure(400, "type must be \"text\" or \"url\"")
            }
            return [try textItem(type: type, content: object["content"] as? String ?? "", into: dir)]
        }

        guard let boundary = Self.parameter("boundary", in: contentType) else { throw Failure(400, "missing multipart boundary") }
        return try receiveMultipart(bodyFile, boundary: boundary, into: dir)
    }

    private func receiveForm(_ bodyFile: URL, into dir: URL) throws -> [ReceivedItem] {
        var fields: [String: String] = [:]
        for pair in String(decoding: try Data(contentsOf: bodyFile), as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                let spaced = s.replacingOccurrences(of: "+", with: " ")
                return spaced.removingPercentEncoding ?? spaced
            }
            let name = decode(kv[0])
            if fields[name] == nil { fields[name] = kv.count > 1 ? decode(kv[1]) : "" }
        }
        var items: [ReceivedItem] = []
        for name in ["url", "content", "text", "file"] {
            guard let value = fields[name], !value.isEmpty else { continue }
            items.append(name == "url" ? try textItem(type: "url", content: value, into: dir) : try classify(value, into: dir))
        }
        return items
    }

    private func receiveMultipart(_ bodyFile: URL, boundary: String, into dir: URL) throws -> [ReceivedItem] {
        let data = try Data(contentsOf: bodyFile, options: .alwaysMapped)
        let delimiter = Data("--\(boundary)".utf8)
        let nextDelimiter = Data("\r\n".utf8) + delimiter
        let headerEnd = Data("\r\n\r\n".utf8)

        guard var cursor = data.range(of: delimiter)?.upperBound else { throw Failure(400, "malformed multipart body") }
        var items: [ReceivedItem] = []

        while cursor + 2 <= data.endIndex, data[cursor..<cursor + 2] != Data("--".utf8) {
            cursor += 2   // CRLF after the delimiter
            guard let headEnd = data.range(of: headerEnd, in: cursor..<data.endIndex),
                  let next = data.range(of: nextDelimiter, in: headEnd.upperBound..<data.endIndex) else { break }
            let head = String(decoding: data[cursor..<headEnd.lowerBound], as: UTF8.self)
            let body = data[headEnd.upperBound..<next.lowerBound]
            cursor = next.upperBound

            var disposition = ""
            for line in head.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-disposition:") {
                disposition = line
            }
            if let filename = Self.filename(in: disposition) {
                guard !filename.isEmpty else { continue }   // filename="" isn't a file (as on Windows)
                let dest = try saveUnique(filename, in: dir) { try body.write(to: $0, options: .withoutOverwriting) }
                Links.quarantine(dest)   // right away, so an error in a later part can't leave it unmarked
                items.append(ReceivedItem(kind: .file(dest)))
            } else if !body.isEmpty {
                items.append(try classify(String(decoding: body, as: UTF8.self), into: dir))
            }
        }
        return items
    }

    /// Text, or a url item when the value is a single web URL (see "Lenient inputs" in PROTOCOL.md).
    private func classify(_ value: String, into dir: URL) throws -> ReceivedItem {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: { $0.isWhitespace }), let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
            return try textItem(type: "url", content: trimmed, into: dir)
        }
        return try textItem(type: "text", content: value, into: dir)
    }

    /// Validates a text or url item and saves a copy next to received files, as the protocol asks.
    private func textItem(type: String, content: String, into dir: URL) throws -> ReceivedItem {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure(400, "empty content") }
        if type == "url" {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.contains(where: \.isNewline), let url = URL(string: trimmed),
                  let scheme = url.scheme, !scheme.isEmpty else { throw Failure(400, "invalid URL") }
            // Links are http and https only; anything else (file:, javascript:) is kept as text.
            guard Links.isWeb(url) else { return try textItem(type: "text", content: content, into: dir) }
            let plist: [String: Any] = ["URL": url.absoluteString]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            Links.quarantine(try saveUnique("Link \(Self.stamp()).webloc", in: dir) { try data.write(to: $0, options: .withoutOverwriting) })
            return ReceivedItem(kind: .url(url))
        }
        Links.quarantine(try saveUnique("Text \(Self.stamp()).txt", in: dir) { try Data(content.utf8).write(to: $0, options: .withoutOverwriting) })
        return ReceivedItem(kind: .text(content))
    }

    // MARK: - Helpers

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "::1" || host.hasPrefix("127.") || host.hasPrefix("::ffff:127.")
    }

    /// Saves under a free name, never overwriting: if another transfer takes the name first, the next
    /// " (n)" is tried.
    private func saveUnique(_ name: String, in dir: URL, _ write: (URL) throws -> Void) throws -> URL {
        for _ in 0..<20 {
            let dest = uniqueDestination(for: name, in: dir)
            do {
                try write(dest)
                return dest
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw Failure(500, "receiver error")
    }

    private func uniqueDestination(for rawName: String, in inbox: URL) -> URL {
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var name = (rawName as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        // No hidden files and no names made only of dots ("..", "..."): drop leading dots.
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Droprr \(Self.stamp())" }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = inbox.appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = inbox.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Reads `key="value"` or `key=value` out of a header value.
    static func parameter(_ key: String, in header: String) -> String? {
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == key else { continue }
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }

    private static let rawExtensions = [
        "image/jpeg": "jpg", "image/png": "png", "image/heic": "heic", "image/heif": "heif",
        "image/gif": "gif", "image/webp": "webp", "video/quicktime": "mov", "video/mp4": "mp4",
        "audio/mpeg": "mp3", "audio/mp4": "m4a", "application/pdf": "pdf", "application/zip": "zip",
        "text/plain": "txt",
    ]

    /// `filename*` (RFC 5987, e.g. UTF-8''My%20File.jpg) wins over `filename`.
    static func filename(in disposition: String) -> String? {
        if let extended = parameter("filename*", in: disposition) {
            let value = extended.components(separatedBy: "''").last ?? extended
            if let decoded = value.removingPercentEncoding, !decoded.isEmpty { return decoded }
        }
        return parameter("filename", in: disposition)
    }

    /// "Droprr yyyy-MM-dd HHmmss", without an extension.
    private static func fallbackName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return "Droprr \(f.string(from: Date()))"
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

}

extension Data {
    /// Lowercase hex.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

// MARK: - Browser access (docs/PROTOCOL.md, "Browser access")

extension DroprrReceiver {
    private static let webCookie = "droprr"
    private static let webFiles: [String: (file: String, type: String)] = [
        "/web": ("index.html", "text/html; charset=utf-8"),
        "/web/": ("index.html", "text/html; charset=utf-8"),
        "/web/app.js": ("app.js", "text/javascript; charset=utf-8"),
        "/web/app.css": ("app.css", "text/css; charset=utf-8"),
        "/web/icon.png": ("icon.png", "image/png"),
    ]
    /// Media a browser may show in place; never SVG or HTML, which could run script on this origin.
    static let inlineTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif",
                                           "video/mp4", "video/quicktime", "video/x-m4v"]

    private static func path(_ request: HTTPServer.Request) -> String {
        (request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path).lowercased()
    }

    /// GET of the page's files, and POST /web/session and /web/signout.
    static func isWebPath(_ request: HTTPServer.Request) -> Bool {
        let path = path(request)
        return (request.method == "GET" && webFiles[path] != nil)
            || (request.method == "POST" && (path == "/web/session" || path == "/web/signout"))
    }

    /// The endpoints a browser's cookie works on. Never /pair.
    static func cookieAllowed(_ request: HTTPServer.Request) -> Bool {
        let path = path(request)
        switch request.method {
        case "GET": return path == "/ping" || path == "/inbox" || path.hasPrefix("/inbox/")
        case "POST": return path == "/send"
        case "DELETE": return path.hasPrefix("/inbox/")
        default: return false
        }
    }

    static func cookie(_ token: String, secure: Bool) -> String {
        "\(webCookie)=\(token); Max-Age=2592000; Path=/; SameSite=Strict; HttpOnly" + (secure ? "; Secure" : "")
    }

    /// Requests from the page itself, on a host name this computer answers to: the Host is an IP address,
    /// localhost, this computer's name or its MagicDNS name (not a name someone else's DNS could point here); an
    /// Origin, when sent, is this same origin; and anything but a GET carries X-Droprr-Web (which another site can't
    /// add without a CORS preflight, and preflights are never answered).
    private func isFromPage(_ request: HTTPServer.Request) -> Bool {
        guard let hostHeader = request.header("host"), !hostHeader.isEmpty else { return false }
        var host = hostHeader
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<end])
        } else if let colon = host.lastIndex(of: ":"), host.filter({ $0 == ":" }).count == 1 {
            host = String(host[..<colon])
        }
        host = host.lowercased()
        var v4 = in_addr(), v6 = in6_addr()
        #if os(macOS)
        let computerName = Host.current().localizedName ?? ""
        #else
        let computerName = ""
        #endif
        let names = [ProcessInfo.processInfo.hostName, computerName]
            .map { $0.lowercased() }.flatMap { [$0, $0.components(separatedBy: ".").first ?? $0] }
            .map { $0.replacingOccurrences(of: " ", with: "-") }
        let known = inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 || host == "localhost"
            || names.contains(host)
            || (magicDNS.map { host == $0 || host == ($0.components(separatedBy: ".").first ?? $0) } ?? false)
        guard known else { return false }
        if let origin = request.header("origin"), !origin.isEmpty,
           origin.lowercased() != "\(request.secure ? "https" : "http")://\(hostHeader.lowercased())" { return false }
        return request.method == "GET" || request.header("x-droprr-web") == "1"
    }

    /// The cookie's token, when the request may use it in place of a bearer token.
    private func cookieToken(_ request: HTTPServer.Request) -> String? {
        guard browserAccess != nil, request.header("authorization") == nil,
              let header = request.header("cookie"), Self.cookieAllowed(request) || Self.isWebPath(request) else { return nil }
        let value = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(Self.webCookie + "=") }.map { String($0.dropFirst(Self.webCookie.count + 1)) }
        guard let value, !value.isEmpty, settings.isBrowserToken(value), isFromPage(request) else { return nil }
        return value
    }

    /// Whether a request authenticated as a browser (its cookie, or a browser token sent as a bearer).
    private func isBrowserRequest(_ request: HTTPServer.Request) -> Bool {
        if cookieToken(request) != nil { return true }
        let header = (request.header("authorization") ?? "").trimmingCharacters(in: .whitespaces)
        return header.lowercased().hasPrefix("bearer ")
            && settings.isBrowserToken(String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces))
    }

    private func browserPeer(_ token: String) -> Peer? {
        guard case .device(let id) = settings.authorize(token) else { return nil }
        return DispatchQueue.main.sync { settings.peers.first { $0.id == id && $0.isBrowser } }
    }

    private func lookUpMagicDNS() {
        guard let address = PairingInfo.tailscaleAddress() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            inet_pton(AF_INET, address, &sin.sin_addr)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let found = withUnsafePointer(to: &sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            } == 0
            let name = String(cString: host).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if found, name.hasSuffix(".ts.net") { self?.magicDNS = name }
        }
    }

    fileprivate func handleWeb(_ request: HTTPServer.Request, _ route: Any) async -> HTTPServer.Response {
        let path = Self.path(request)
        if request.method == "GET", let file = Self.webFiles[path] {
            guard let url = Bundle.main.url(forResource: file.file, withExtension: nil, subdirectory: "web") else {
                return .json(404, ["ok": false, "error": "not found"])
            }
            var response = HTTPServer.Response(status: 200, body: Data(), contentType: file.type)
            response.file = url
            response.headers["Cache-Control"] = "no-cache"
            response.headers["X-Content-Type-Options"] = "nosniff"
            response.headers["Referrer-Policy"] = "no-referrer"
            response.headers["X-Frame-Options"] = "DENY"
            response.headers["Content-Security-Policy"] = "default-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; "
                + "frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'"
            return response
        }
        if path == "/web/session" { return webSession(request) }
        // Sign out: remove this browser's peer (and its queue) and clear the cookie.
        if let token = cookieToken(request), let peer = browserPeer(token), request.header("x-droprr-web") == "1" {
            let remove = onBrowserRemoved
            DispatchQueue.main.sync { remove?(peer.id) }
        }
        var response = HTTPServer.Response.json(200, ["ok": true])
        response.headers["Set-Cookie"] = "\(Self.webCookie)=; Max-Age=0; Path=/; SameSite=Strict; HttpOnly" + (request.secure ? "; Secure" : "")
        return response
    }

    /// { code, name }: on the right code, a new "web" peer with the cookie as its token.
    private func webSession(_ request: HTTPServer.Request) -> HTTPServer.Response {
        guard isFromPage(request), let access = browserAccess, let addBrowser else {
            return .json(403, ["ok": false, "error": "forbidden"])
        }
        guard let body = request.bodyFile, let data = try? Data(contentsOf: body), data.count <= 4096,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .json(400, ["ok": false, "error": "body must be JSON: {\"code\", \"name\"}"])
        }
        switch access.use(json["code"] as? String) {
        case .wrong: return .json(403, ["ok": false, "error": "wrong code"])
        case .closed: return .json(403, ["ok": false, "error": "no code is open: choose Open in a browser on the computer"])
        case .accepted: break
        }
        let name = PairRequest.displayName(json["name"] as? String ?? "")
        let token = DroprrSettings.generateToken()
        let saved = DispatchQueue.main.sync {
            addBrowser(PairRequest(name: name.isEmpty ? "Browser" : name, platform: "web", host: "", port: settings.port,
                                   token: nil, acceptToken: token, viaLAN: true))
        }
        var response = HTTPServer.Response.json(200, ["ok": true, "name": settings.deviceName, "device": saved])
        response.headers["Set-Cookie"] = Self.cookie(token, secure: request.secure)
        return response
    }
}
