import AppKit
import CryptoKit
import OSLog
import WebKit

/// Browser access over the internet (docs/PROTOCOL.md): runs the shared host page (host/host.html, host/host.js and
/// site/rtc.js, unchanged) hidden in a WKWebView. It keeps this Mac in its room on the relay and talks WebRTC to the
/// browsers that scanned its code. The page is served by this Mac's own loopback listener at
/// http://localhost:<port>/host/ (a secure context, so WebRTC and its stored certificate work), and reaches the app
/// through /api on the same origin, gated by a per-launch cookie only this web view holds.
@MainActor
final class BrowserHost: NSObject, WKNavigationDelegate {
    /// The live website and relay (docs/PROTOCOL.md).
    static let defaultRelay = "wss://droprr-relay.droprr-domain.workers.dev"
    static let defaultSite = "https://gingivere0.github.io/droprr/"

    private let settings: DroprrSettings
    private let access: BrowserAccess
    private let outbox: OutboxServing
    private var webView: WKWebView?
    private let gate: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }()
    private static let gateCookie = "droprr-host"

    /// The page's DTLS fingerprint (base64url), once it has reported it.
    private(set) var fingerprint: String?
    /// Device ids of the browsers connected right now.
    private(set) var online: [String] = []
    var onChange: () -> Void = {}
    /// A browser joined with the join secret (its peer name), for the window's "Connected" confirmation.
    var onBrowserJoined: (String) -> Void = { _ in }

    init(settings: DroprrSettings, access: BrowserAccess, outbox: OutboxServing) {
        self.settings = settings
        self.access = access
        self.outbox = outbox
    }

    static var relay: String {
        let custom = UserDefaults.standard.string(forKey: "browserRelay")?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? defaultRelay : String(custom.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    static var site: String {
        let custom = UserDefaults.standard.string(forKey: "browserSite")?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? defaultSite : custom
    }

    /// The room: base64url(SHA-256(host key)).
    var room: String {
        let key = Data(base64URL: settings.browserHostKey) ?? Data()
        return Data(SHA256.hash(data: key)).base64URL
    }

    /// What the Droprr app needs to pair from the one code (docs/PROTOCOL.md, "One code"), as base64url JSON.
    var appInfo: () -> String? = { nil }

    /// The one code, while the Pair a phone window is open and the page is ready:
    /// <site>#<room>.<secret>.<fp>.<app>.
    var joinLink: String? {
        guard let fingerprint, let secret = access.secret else { return nil }
        let app = appInfo().map { ".\($0)" } ?? ""
        return "\(Self.site)#\(room).\(secret).\(fingerprint)\(app)"
    }

    private var origin: String { "http://localhost:\(settings.port)" }

    func start() {
        hostLog.log("starting the host page on port \(self.settings.port, privacy: .public)")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // keeps the page's IndexedDB, and so its DTLS certificate
        // host.js listens for app messages on chrome.webview (WebView2's API); give it the same shape here.
        let shim = """
        (() => {
          const listeners = [];
          window.chrome = window.chrome || {};
          window.chrome.webview = {
            addEventListener(type, fn) { if (type === "message") listeners.push(fn); },
            removeEventListener(type, fn) { const i = listeners.indexOf(fn); if (i >= 0) listeners.splice(i, 1); },
          };
          window.__droprrPost = (message) => listeners.forEach((fn) => fn({ data: message }));
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // The page's console and errors go to the system log (host.js logs states, never secrets), so a page that
        // doesn't come up can be diagnosed with: log show --predicate 'subsystem == "droprr" AND category == "host"'
        config.userContentController.add(ConsoleLog(), name: "droprrConsole")
        config.userContentController.addUserScript(WKUserScript(source: """
        (() => {
          const post = (t) => window.webkit.messageHandlers.droprrConsole.postMessage(String(t).slice(0, 300));
          const log = console.log; console.log = (...a) => { log(...a); post(a.join(" ")); };
          window.addEventListener("error", (e) => post("error: " + e.message));
          window.addEventListener("unhandledrejection", (e) => post("rejection: " + (e.reason && (e.reason.stack || e.reason.message) || e.reason)));
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #if DEBUG
        config.userContentController.addUserScript(WKUserScript(source: """
        (() => {
          const post = (t) => window.webkit.messageHandlers.droprrConsole.postMessage(String(t));
          const PC = window.RTCPeerConnection;
          window.RTCPeerConnection = function (...args) {
            const pc = new PC(...args);
            pc.addEventListener("connectionstatechange", () => post("pc " + pc.connectionState));
            pc.addEventListener("iceconnectionstatechange", () => post("ice " + pc.iceConnectionState));
            return pc;
          };
          window.RTCPeerConnection.prototype = PC.prototype;
          window.RTCPeerConnection.generateCertificate = PC.generateCertificate;
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #endif
        // WebKit suspends pages nobody can see after a few seconds, which would cut this one off from the relay. These
        // switches (WebKit SPI, checked before use) keep it running.
        for key in ["pageVisibilityBasedProcessSuppressionEnabled", "hiddenPageDOMTimerThrottlingEnabled",
                    "hiddenPageDOMTimerThrottlingAutoIncreases"]
        where config.preferences.responds(to: NSSelectorFromString("_set\(key.prefix(1).uppercased() + key.dropFirst()):")) {
            config.preferences.setValue(false, forKey: key)
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10), configuration: config)
        if webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
            webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        }
        webView.navigationDelegate = self
        self.webView = webView
        // The gate: a session cookie (never saved to disk) for this origin, HttpOnly and SameSite=Strict.
        let cookie = HTTPCookie(properties: [
            .name: Self.gateCookie, .value: gate, .domain: "localhost", .path: "/",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE", .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict,
        ])
        let load = { [weak self] in
            guard let self, let url = URL(string: "\(self.origin)/host/host.html") else { return }
            webView.load(URLRequest(url: url))
            self.checkReady(webView)
        }
        if let cookie {
            config.websiteDataStore.httpCookieStore.setCookie(cookie) { load() }
        } else {
            load()
        }
    }

    /// The page reports ready within seconds. When it doesn't (the listener wasn't up yet at launch, or the page
    /// failed to start), load it again, so Pair a phone never stays on the fallback code.
    private func checkReady(_ webView: WKWebView, delay: TimeInterval = 10) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
            guard let self, let webView, webView === self.webView, self.fingerprint == nil else { return }
            hostLog.error("host page not ready; loading it again")
            webView.reload()
            if webView.url == nil, let url = URL(string: "\(self.origin)/host/host.html") { webView.load(URLRequest(url: url)) }
            self.checkReady(webView, delay: min(delay * 2, 120))
        }
    }

    func stop() {
        webView?.stopLoading()
        webView = nil
    }

    /// Tells the page to read its config again (a code opened or closed, or the relay changed).
    func configChanged() { post(["t": "config"]) }

    /// Tells the page something was queued, so it goes out now.
    func outboxChanged() { post(["t": "outbox"]) }

    private func post(_ message: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__droprrPost && window.__droprrPost(\(json))")
    }

    // Only this Mac's own page, never anything else.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.absoluteString.hasPrefix("\(origin)/host/") == true ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        hostLog.error("page didn't load: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        hostLog.error("page failed: \(error.localizedDescription, privacy: .public)")
    }

    /// The page crashed or was killed: load it again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hostLog.error("page process ended; loading it again")
        start()
    }

    // MARK: Requests from the page (on the receiver's queue)

    private static let files: [String: String] = [
        "/host/host.html": "text/html; charset=utf-8",
        "/host/host.js": "text/javascript; charset=utf-8",
        "/host/rtc.js": "text/javascript; charset=utf-8",
    ]

    nonisolated func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        let notFound = HTTPServer.Response.json(404, ["ok": false, "error": "not found"])
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        let port = await MainActor.run { settings.port }
        // Only the page itself: Host exactly localhost:<port> or 127.0.0.1:<port>, and its own Origin if sent.
        let host = (request.header("host") ?? "").lowercased()
        guard host == "localhost:\(port)" || host == "127.0.0.1:\(port)" else { return notFound }
        if let origin = request.header("origin"), !origin.isEmpty, origin.lowercased() != "http://localhost:\(port)" { return notFound }

        if request.method == "GET", let type = Self.files[path] {
            let name = (path as NSString).lastPathComponent
            guard let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "host") else { return notFound }
            var response = HTTPServer.Response(status: 200, body: Data(), contentType: type)
            response.file = url
            response.headers["Cache-Control"] = "no-store"
            response.headers["X-Content-Type-Options"] = "nosniff"
            return response
        }
        let cookies = (request.header("cookie") ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard cookies.contains("\(Self.gateCookie)=\(gate)") else { return .json(403, ["ok": false, "error": "forbidden"]) }
        return await api(request, path)
    }

    private nonisolated func json(_ request: HTTPServer.Request) -> [String: Any] {
        guard let file = request.bodyFile, let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private nonisolated func api(_ request: HTTPServer.Request, _ path: String) async -> HTTPServer.Response {
        switch (request.method, path) {
        case ("GET", "/api/config"):
            return await MainActor.run {
                .json(200, ["relay": Self.relay, "key": settings.browserHostKey, "name": settings.deviceName,
                            "secret": access.secret as Any? ?? NSNull()])
            }
        case ("POST", "/api/ready"):
            if let fp = json(request)["fp"] as? String, fp.count == 43 {
                await MainActor.run {
                    fingerprint = fp
                    hostLog.log("host page ready")
                    onChange()
                }
                #if DEBUG
                NSLog("Droprr test: host page ready, fp %@", fp)
                let link = await MainActor.run { joinLink ?? "" }
                NSLog("Droprr test: join link %@", link)
                #endif
            }
            return .json(200, ["ok": true])
        case ("POST", "/api/status"):
            let browsers = (json(request)["browsers"] as? [String]) ?? []
            await MainActor.run {
                online = browsers
                onChange()
            }
            return .json(200, ["ok": true])
        case ("POST", "/api/hello"):
            let body = json(request)
            return await MainActor.run { hello(id: body["id"] as? String ?? "", name: body["name"] as? String ?? "",
                                               secret: body["secret"] as? String, token: body["token"] as? String) }
        default:
            break
        }
        // /api/p/<peer>/send and /api/p/<peer>/inbox[/<id>]
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 4, parts[0] == "api", parts[1] == "p",
              let peer = await MainActor.run(body: { settings.peers.first { $0.isBrowser && $0.deviceID == parts[2] } }) else {
            return .json(404, ["ok": false, "error": "not found"])
        }
        if parts[3] == "send", parts.count == 4, request.method == "POST" {
            return await forwardSend(request, as: peer)
        }
        guard parts[3] == "inbox" else { return .json(404, ["ok": false, "error": "not found"]) }
        if parts.count == 4, request.method == "GET" {
            return .json(200, ["ok": true, "items": outbox.list(for: nil, peerID: peer.id, from: nil)])
        }
        guard parts.count == 5 else { return .json(404, ["ok": false, "error": "not found"]) }
        if request.method == "DELETE" {
            return outbox.remove(id: parts[4], peerID: peer.id) ? .json(200, ["ok": true]) : .json(404, ["ok": false, "error": "not found"])
        }
        guard request.method == "GET", let file = outbox.file(id: parts[4], peerID: peer.id) else {
            return .json(404, ["ok": false, "error": "not found"])
        }
        var response = HTTPServer.Response(status: 200, body: Data(), contentType: "application/octet-stream")
        response.file = file.url
        return response
    }

    /// A browser introduced itself over its data channel. With a token from an earlier visit it's the browser peer
    /// that token was given to; with the open join secret it's added (or, for a browser seen before, given a new
    /// token). Anything else is refused.
    private func hello(id: String, name: String, secret: String?, token: String?) -> HTTPServer.Response {
        guard id.count == 22, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return .json(200, ["ok": false, "error": "bad browser id"])
        }
        let existing = settings.peers.first { $0.isBrowser && $0.deviceID == id }
        if let token, !token.isEmpty, let accept = existing?.acceptToken, !accept.isEmpty,
           Array(token.utf8).count == Array(accept.utf8).count,
           zip(Array(token.utf8), Array(accept.utf8)).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 {
            return .json(200, ["ok": true, "peer": id, "token": accept])
        }
        guard access.isSecret(secret) else {
            return .json(200, ["ok": false, "error": existing == nil ? "scan the code on the computer" : "this browser was removed: scan the code again"])
        }
        let minted = DroprrSettings.generateToken()
        let clean = PairRequest.displayName(name)
        if let i = settings.peers.firstIndex(where: { $0.isBrowser && $0.deviceID == id }) {
            settings.peers[i].acceptToken = minted
        } else {
            var peer = Peer(name: settings.uniqueName(clean.isEmpty ? "Browser" : clean), host: "", platform: "web",
                            remoteName: clean, token: nil, acceptToken: minted)
            peer.deviceID = id
            settings.peers.append(peer)
        }
        if let saved = settings.peers.first(where: { $0.isBrowser && $0.deviceID == id }) { onBrowserJoined(saved.name) }
        return .json(200, ["ok": true, "peer": id, "token": minted])
    }

    /// An item from a browser goes through this Mac's own receiver over loopback, authenticated as that browser,
    /// so it's saved, announced and checked exactly like anything else that arrives.
    private nonisolated func forwardSend(_ request: HTTPServer.Request, as peer: Peer) async -> HTTPServer.Response {
        let port = await MainActor.run { settings.port }
        guard let token = peer.acceptToken, let url = URL(string: "http://127.0.0.1:\(port)/send") else {
            return .json(404, ["ok": false, "error": "not found"])
        }
        var forward = URLRequest(url: url)
        forward.httpMethod = "POST"
        forward.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let type = request.header("content-type") { forward.setValue(type, forHTTPHeaderField: "Content-Type") }
        if let name = request.header("x-droprr-filename") { forward.setValue(name, forHTTPHeaderField: "X-Droprr-Filename") }
        do {
            let (data, response): (Data, URLResponse)
            if let body = request.bodyFile {
                (data, response) = try await URLSession.shared.upload(for: forward, fromFile: body)
            } else {
                (data, response) = try await URLSession.shared.upload(for: forward, from: Data())
            }
            return HTTPServer.Response(status: (response as? HTTPURLResponse)?.statusCode ?? 500, body: data)
        } catch {
            return .json(500, ["ok": false, "error": "receiver error"])
        }
    }
}

private let hostLog = Logger(subsystem: "droprr", category: "host")

private final class ConsoleLog: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let text = String(describing: message.body)
        hostLog.log("page: \(text, privacy: .public)")
        #if DEBUG
        NSLog("Droprr host page: %@", text)
        #endif
    }
}
