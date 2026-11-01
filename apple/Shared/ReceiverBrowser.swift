import CryptoKit
import Foundation
import Network

// MARK: - Browser access (docs/PROTOCOL.md, "Browser access")

extension DroprrReceiver {
    static let webCookie = "droprr"
    static let webFiles: [String: (file: String, type: String)] = [
        "/web": ("index.html", "text/html; charset=utf-8"),
        "/web/": ("index.html", "text/html; charset=utf-8"),
        "/web/app.js": ("app.js", "text/javascript; charset=utf-8"),
        "/web/common.js": ("common.js", "text/javascript; charset=utf-8"),
        "/web/app.css": ("app.css", "text/css; charset=utf-8"),
        "/web/icon.png": ("icon.png", "image/png"),
    ]
    /// Media a browser may show in place; never SVG or HTML, which could run script on this origin.
    static let inlineTypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif",
                                           "video/mp4", "video/quicktime", "video/x-m4v"]

    static func path(_ request: HTTPServer.Request) -> String {
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
    func isFromPage(_ request: HTTPServer.Request) -> Bool {
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
    func cookieToken(_ request: HTTPServer.Request) -> String? {
        guard browserAccess != nil, request.header("authorization") == nil,
              let header = request.header("cookie"), Self.cookieAllowed(request) || Self.isWebPath(request) else { return nil }
        let value = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(Self.webCookie + "=") }.map { String($0.dropFirst(Self.webCookie.count + 1)) }
        guard let value, !value.isEmpty, settings.isBrowserToken(value), isFromPage(request) else { return nil }
        return value
    }

    /// Whether a request authenticated as a browser (its cookie, or a browser token sent as a bearer).
    func isBrowserRequest(_ request: HTTPServer.Request) -> Bool {
        if cookieToken(request) != nil { return true }
        let header = (request.header("authorization") ?? "").trimmingCharacters(in: .whitespaces)
        return header.lowercased().hasPrefix("bearer ")
            && settings.isBrowserToken(String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces))
    }

    func browserPeer(_ token: String) -> Peer? {
        guard case .device(let id) = settings.authorize(token) else { return nil }
        return DispatchQueue.main.sync { settings.peers.first { $0.id == id && $0.isBrowser } }
    }

    func lookUpMagicDNS() {
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

    func handleWeb(_ request: HTTPServer.Request, _ route: Any) async -> HTTPServer.Response {
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
    func webSession(_ request: HTTPServer.Request) -> HTTPServer.Response {
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
                                   token: nil, acceptToken: token, target: .new))
        }
        var response = HTTPServer.Response.json(200, ["ok": true, "name": settings.deviceName, "device": saved])
        response.headers["Set-Cookie"] = Self.cookie(token, secure: request.secure)
        return response
    }
}
