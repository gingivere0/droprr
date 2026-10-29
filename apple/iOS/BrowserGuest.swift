import UIKit
import UniformTypeIdentifiers
import WebKit

/// Browsers as hosts (docs/PROTOCOL.md): talks to browsers that showed their own code, as a WebRTC guest. The
/// shared site/rtc.js and guest/guest.js run in a hidden web view, served from this app's own scheme (so the page
/// can fetch files to send from it); this class turns its messages into joins, sends and received items.
/// Connections only last while both the app and the browser's page are open.
@MainActor
final class BrowserGuest: NSObject, WKScriptMessageHandler {
    static let shared = BrowserGuest()
    static let scheme = "droprr-guest"

    struct Welcome {
        var name: String
        var token: String
    }

    enum GuestError: LocalizedError {
        case failed(String)
        case denied(String)

        var errorDescription: String? {
            switch self {
            case .denied(let reason): return reason.isEmpty ? "The browser didn't accept this iPhone." : "The browser didn't accept this iPhone (\(reason))."
            case .failed("offline"): return "That browser's page isn't open. Open it and try again."
            case .failed("wrong key"): return "That isn't the browser whose code you scanned. Scan its code again."
            case .failed("refused"): return "The browser refused this iPhone. Scan its code again."
            case .failed(let reason): return "Couldn't reach the browser (\(reason)). Both need to be online."
            }
        }
    }

    /// An item a browser sent: text or a link, or a file saved to a temporary location.
    var onReceive: (_ room: String, _ item: ReceivedItem) -> Void = { _, _ in }
    /// A browser's connection ended (its page closed or the network dropped).
    var onClosed: (_ room: String) -> Void = { _ in }
    var onProgress: (Double) -> Void = { _ in }

    private var webView: WKWebView?
    private var ready = false
    private var waitingForReady: [CheckedContinuation<Void, Never>] = []
    private var joins: [String: CheckedContinuation<Welcome, Error>] = [:]
    private var sends: [String: CheckedContinuation<Void, Error>] = [:]
    private(set) var connected: Set<String> = []
    private let files = OutgoingFiles()
    private var incoming: [String: (url: URL, handle: FileHandle, name: String, room: String)] = [:]

    /// This phone's id toward browsers (16 random bytes, base64url), the same for every browser.
    private var guestID: String {
        if let id = UserDefaults.standard.string(forKey: "browserGuestID"), id.count == 22 { return id }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let id = Data(bytes).base64URL
        UserDefaults.standard.set(id, forKey: "browserGuestID")
        return id
    }

    private func start() {
        guard webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(files, forURLScheme: Self.scheme)
        config.userContentController.add(WeakHandler(self), name: "droprr")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        // In the window (invisible), so iOS keeps the page running while the app is open.
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.addSubview(webView)
        self.webView = webView
        if let url = URL(string: "\(Self.scheme)://app/guest.html") { webView.load(URLRequest(url: url)) }
    }

    private func whenReady() async {
        start()
        if ready { return }
        await withCheckedContinuation { waitingForReady.append($0) }
    }

    private func call(_ function: String, _ arguments: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.droprrGuest.\(function)(...\(json))")
    }

    /// Connects to a browser's room: with the secret from its code, or later with the token it gave this phone.
    func join(room: String, fingerprint: String, secret: String?, token: String?, name: String) async throws -> Welcome {
        await whenReady()
        joins[room]?.resume(throwing: GuestError.failed("replaced"))
        return try await withCheckedThrowingContinuation { continuation in
            joins[room] = continuation
            var options: [String: Any] = ["relay": DroprrWeb.relay, "room": room, "fp": fingerprint, "id": guestID, "name": name]
            if let secret { options["secret"] = secret } else if let token { options["token"] = token }
            call("connect", [options])
        }
    }

    /// Sends items to a connected browser, one after another; each finishes once the browser saved it.
    func send(_ payload: SendPayload, to room: String) async throws {
        var items: [[String: Any]] = []
        switch payload {
        case .text(let text): items.append(["kind": "text", "content": text])
        case .url(let url): items.append(["kind": "url", "content": url.absoluteString])
        case .files(let urls):
            for url in urls {
                let id = files.add(url)
                items.append(["kind": "file", "out": id, "name": url.lastPathComponent, "type": UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"])
            }
        }
        for var item in items {
            let req = UUID().uuidString
            item["req"] = req
            defer { if let out = item["out"] as? String { files.remove(out) } }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sends[req] = continuation
                call("send", [room, item])
            }
        }
    }

    func disconnect(_ room: String) {
        connected.remove(room)
        call("disconnect", [room])
    }

    // MARK: Messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["t"] as? String else { return }
        let room = body["room"] as? String ?? ""
        switch type {
        case "ready":
            ready = true
            waitingForReady.forEach { $0.resume() }
            waitingForReady = []
        case "welcome":
            connected.insert(room)
            joins.removeValue(forKey: room)?.resume(returning: Welcome(name: body["name"] as? String ?? "", token: body["token"] as? String ?? ""))
        case "denied":
            connected.remove(room)
            joins.removeValue(forKey: room)?.resume(throwing: GuestError.denied(body["e"] as? String ?? ""))
        case "failed":
            connected.remove(room)
            joins.removeValue(forKey: room)?.resume(throwing: GuestError.failed(body["e"] as? String ?? ""))
        case "closed":
            connected.remove(room)
            joins.removeValue(forKey: room)?.resume(throwing: GuestError.failed("closed"))
            onClosed(room)
        case "sent":
            guard let req = body["req"] as? String, let continuation = sends.removeValue(forKey: req) else { return }
            if let error = body["e"] as? String { continuation.resume(throwing: GuestError.failed(error)) } else { continuation.resume() }
        case "progress":
            if body["direction"] as? String == "out", let done = body["done"] as? Double, let total = body["total"] as? Double, total > 0 {
                onProgress(done / total)
            }
        case "text":
            let content = body["content"] as? String ?? ""
            if body["kind"] as? String == "url", let url = URL(string: content), Links.isWeb(url) {
                onReceive(room, ReceivedItem(kind: .url(url)))
            } else {
                onReceive(room, ReceivedItem(kind: .text(content)))
            }
        case "fileStart":
            guard let key = body["key"] as? String else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("droprr-browser-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            incoming[key] = (url, handle, body["name"] as? String ?? "File", room)
        case "filePart":
            guard let key = body["key"] as? String, let part = incoming[key], let text = body["data"] as? String,
                  let data = Data(base64Encoded: text) else { return }
            part.handle.write(data)
        case "fileEnd":
            guard let key = body["key"] as? String, let part = incoming.removeValue(forKey: key) else { return }
            try? part.handle.close()
            // The name rides along in the temporary file's name; the model moves it into Received.
            let named = part.url.deletingLastPathComponent().appendingPathComponent("droprr-browser-\(UUID().uuidString)")
                .appendingPathComponent(part.name.isEmpty ? "File" : (part.name as NSString).lastPathComponent)
            try? FileManager.default.createDirectory(at: named.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? FileManager.default.moveItem(at: part.url, to: named)) != nil {
                onReceive(part.room, ReceivedItem(kind: .file(named)))
            }
        default:
            break
        }
    }
}

/// Serves the guest page from the app bundle (guest/) and files being sent (out/<id>) on droprr-guest://app.
private final class OutgoingFiles: NSObject, WKURLSchemeHandler {
    private let lock = NSLock()
    private var files: [String: URL] = [:]

    func add(_ url: URL) -> String {
        let id = UUID().uuidString
        lock.withLock { files[id] = url }
        return id
    }

    func remove(_ id: String) {
        lock.withLock { files[id] = nil }
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let path = task.request.url?.path ?? ""
        let types = ["guest.html": "text/html", "guest.js": "text/javascript", "rtc.js": "text/javascript"]
        var data: Data?
        var type = "application/octet-stream"
        if path.hasPrefix("/out/") {
            let id = String(path.dropFirst(5)).removingPercentEncoding ?? ""
            if let url = lock.withLock({ files[id] }) {
                let scoped = url.startAccessingSecurityScopedResource()
                data = try? Data(contentsOf: url, options: .mappedIfSafe)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        } else {
            let name = (path as NSString).lastPathComponent
            if let mime = types[name], let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "guest") {
                data = try? Data(contentsOf: url)
                type = mime
            }
        }
        guard let data, let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": type, "Content-Length": String(data.count)]) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// The content controller keeps its handlers alive; this breaks the cycle with the shared guest.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
