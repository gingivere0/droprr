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
    /// Which saved peer this pairing applies to.
    var target: PairTarget = .match
}

/// Which saved peer a pairing applies to (the same choices as PairTarget in the Windows app).
enum PairTarget: Equatable {
    /// The main token (QR pairing): the peer with the same device id, else the same name, else a new one.
    case match
    /// A confirmed pairing with a device not paired before (a LAN code, the one code, or a browser): a new peer.
    case new
    /// The peer whose device token authenticated the request: it may fill in an id or pin it doesn't have yet
    /// (a protocol 1 pairing upgrading), never replace them. Not news to the person.
    case update(UUID)
    /// The device pairing again with the person's consent: the same peer, with fresh tokens and its current id and pin.
    case repair(UUID)

    /// Whether the pairing may replace the peer's device id and pinned certificate.
    var replacesIdentity: Bool { if case .update = self { return false } else { return true } }
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
    let server = HTTPServer()
    /// Protocol 2: HTTPS on the HTTP port + 1, for the LAN (and optionally Tailscale).
    var secureServer: HTTPServer?
    /// Browser access over Wi-Fi: HTTPS on the HTTP port + 2, without a client certificate (desktops only).
    var browserServer: HTTPServer?
    /// The "Open in a browser" code; nil (iPhone) turns Browser access off.
    var browserAccess: BrowserAccess?
    /// Saves a browser that used the code as a new "web" peer and returns its name. Called on the main queue.
    var addBrowser: ((PairRequest) -> String)?
    /// A browser signed itself out. Called on the main queue with its peer id.
    var onBrowserRemoved: ((UUID) -> Void)?
    /// Browser access over the internet: the hidden host page's files (/host/…) and its /api bridge, on the
    /// plain listener over loopback only. The handler checks the page's own cookie, Host and Origin.
    var hostBridge: ((HTTPServer.Request) async -> HTTPServer.Response)?
    /// This device's MagicDNS name, if Tailscale has one: a Host a browser may use.
    var magicDNS: String?
    let settings: DroprrSettings
    let inbox: URL

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
    var bonjourService: NWListener.Service? {
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

    func precheck(_ request: HTTPServer.Request) -> HTTPServer.Response? {
        // Browser access: the page and its sign-in need no token; the browser port serves nothing else
        // except the endpoints a browser's cookie works on.
        if Self.isWebPath(request) { return browserAccess == nil ? .json(404, ["ok": false, "error": "not found"]) : nil }
        if request.path.hasPrefix("/host/") || request.path.hasPrefix("/api/") {
            return hostBridge != nil && !request.secure && Self.isLoopback(request.remoteHost) ? nil : .json(404, ["ok": false, "error": "not found"])
        }
        if request.browserPort && !Self.cookieAllowed(request) { return .json(404, ["ok": false, "error": "not found"]) }
        // LAN pairing is the one request without a token, and only over HTTPS.
        if request.method == "POST", ["request", "confirm"].contains(Route(request).segments.dropFirst().first ?? ""),
           Route(request).segments.count == 2, Route(request).segments.first == "pair" {
            return request.secure && onPairRequest != nil ? nil : .json(404, ["ok": false, "error": "not found"])
        }
        // The one code: POST /pair may use the open join secret instead of a token (docs/PROTOCOL.md, "One code").
        if isJoin(request) { return onPair == nil ? .json(404, ["ok": false, "error": "not found"]) : nil }
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
    struct Route {
        var segments: [String]
        var query: [String: String] = [:]

        init(_ request: HTTPServer.Request) {
            let components = URLComponents(string: request.path)
                ?? URLComponents(string: request.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            segments = (components?.path ?? request.path).split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
            for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        }
    }

    /// POST /pair with the open join secret and no Authorization header.
    func isJoin(_ request: HTTPServer.Request) -> Bool {
        let route = Route(request)
        return request.method == "POST" && route.segments == ["pair"] && request.header("authorization") == nil
            && browserAccess?.isSecret(request.header("x-droprr-join")) == true
    }

    /// Which token authorized the request: the main token or a paired device's token.
    func authorization(_ request: HTTPServer.Request) -> DroprrSettings.Authorization? {
        if let token = cookieToken(request) { return settings.authorize(token) }
        let header = (request.header("authorization") ?? "").trimmingCharacters(in: .whitespaces)
        guard header.lowercased().hasPrefix("bearer ") else { return nil }
        return settings.authorize(String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces))
    }

    func handleInbox(_ request: HTTPServer.Request, _ route: Route, _ outbox: OutboxServing) -> HTTPServer.Response {
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

    func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        let route = Route(request)
        if Self.isWebPath(request) { return await handleWeb(request, route as Any) }
        if request.path.hasPrefix("/host/") || request.path.hasPrefix("/api/"), let hostBridge {
            return await hostBridge(request)
        }
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
            return handlePair(request, onPair: onPair)
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
    func responseFields(token: String) -> [String: Any] {
        var fields: [String: Any] = ["ok": true, "name": settings.deviceName, "token": token]
        fields.merge(settings.ownIdentityFields) { a, _ in a }
        if let host = PairingInfo.tailscaleAddress() { fields["host"] = host }
        return fields
    }

    static func isLoopback(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "::1" || host.hasPrefix("127.") || host.hasPrefix("::ffff:127.")
    }

    // LAN pairing state (ReceiverPairing.swift).
    let pairLock = NSLock()
    var pairSession: PairSession?
    var pairStrikes: [String: [Date]] = [:]
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
