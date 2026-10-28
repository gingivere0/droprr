import Foundation

/// What a desktop's outbox exposes to the receiver for the /inbox endpoints.
protocol OutboxServing: AnyObject {
    /// JSON-ready items for the named phone, oldest first. May register an unknown phone as a peer.
    func list(for deviceName: String, from remoteHost: String?) -> [[String: Any]]
    func file(id: String) -> (url: URL, name: String, mimeType: String)?
    func remove(id: String) -> Bool
    /// Queues already-received items for the phone peer with this id (Mac share extension hand-off).
    func enqueue(_ items: [ReceivedItem], forPeerID id: String) throws
}

struct ReceivedItem: Identifiable {
    enum Kind {
        case file(URL)
        case text(String)
        case url(URL)
    }

    let id = UUID()
    let kind: Kind
    let date = Date()

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
    private let settings: DroprrSettings
    private let inbox: URL

    /// Called on the main queue for every item received.
    var onItem: (ReceivedItem) -> Void = { _ in }
    var onStateChange: (String) -> Void = { _ in }
    /// Desktops serve the phone inbox from this; nil (iPhone) means /inbox is 404.
    var outbox: OutboxServing?

    init(settings: DroprrSettings, inbox: URL) {
        self.settings = settings
        self.inbox = inbox
        server.precheck = { [weak self] request in self?.precheck(request) }
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
    }

    func stop() { server.stop() }

    // MARK: - Routing

    private func precheck(_ request: HTTPServer.Request) -> HTTPServer.Response? {
        let token = settings.token
        guard !token.isEmpty else {
            return .json(503, ["ok": false, "error": "no pairing token set on this device"])
        }
        let auth = request.header("authorization") ?? ""
        guard auth.hasPrefix("Bearer "), constantTimeEqual(String(auth.dropFirst(7)), token) else {
            return .json(401, ["ok": false, "error": "unauthorized"])
        }
        let route = Route(request)
        switch (request.method, route.segments.first) {
        case ("GET", "ping") where route.segments.count == 1,
             ("POST", "send") where route.segments.count == 1:
            return nil
        case ("POST", "outbox") where route.segments.count == 2:
            // Loopback-only hand-off from the Mac share extension: queue for a phone peer.
            return outbox != nil && Self.isLoopback(request.remoteHost) ? nil : .json(404, ["ok": false, "error": "not found"])
        case ("GET", "inbox"), ("DELETE", "inbox") where route.segments.count == 2:
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

    private func handleInbox(_ request: HTTPServer.Request, _ route: Route, _ outbox: OutboxServing) -> HTTPServer.Response {
        let notFound = HTTPServer.Response.json(404, ["ok": false, "error": "not found"])
        if route.segments.count == 1 {
            guard request.method == "GET", let name = route.query["for"], !name.isEmpty else {
                return .json(400, ["ok": false, "error": "missing for=<device name>"])
            }
            let items = outbox.list(for: name, from: request.remoteHost)
            return .json(200, ["ok": true, "items": items])
        }
        let id = route.segments[1]
        if request.method == "DELETE" {
            return outbox.remove(id: id) ? .json(200, ["ok": true]) : notFound
        }
        guard let file = outbox.file(id: id) else { return notFound }
        var response = HTTPServer.Response(status: 200, body: Data(), contentType: file.mimeType)
        response.file = file.url
        let ascii = file.name.unicodeScalars.allSatisfy { $0.isASCII && $0 != "\"" }
        let fallback = String(String.UnicodeScalarView((file.name.applyingTransform(.stripDiacritics, reverse: false) ?? file.name)
            .unicodeScalars.filter { $0.isASCII && $0 != "\"" }))
        var disposition = "attachment; filename=\"\(ascii ? file.name : (fallback.isEmpty ? "download" : fallback))\""
        if !ascii, let encoded = file.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            disposition += "; filename*=UTF-8''\(encoded)"
        }
        response.headers["Content-Disposition"] = disposition
        return response
    }

    private func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        let route = Route(request)
        if route.segments.first == "inbox", let outbox {
            return handleInbox(request, route, outbox)
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
                return .json(500, ["ok": false, "error": error.localizedDescription])
            }
        }
        if route.segments.first == "ping" {
            return .json(200, ["name": settings.deviceName, "version": DroprrDefaults.version, "platform": DroprrSettings.platform])
        }
        do {
            let items = try receive(request, into: inbox)
            guard !items.isEmpty else { throw Failure(400, "no items") }
            let onItem = self.onItem
            DispatchQueue.main.async { items.forEach(onItem) }
            return .json(200, ["ok": true, "received": items.count])
        } catch let failure as Failure {
            return .json(failure.status, ["ok": false, "error": failure.message])
        } catch {
            return .json(500, ["ok": false, "error": error.localizedDescription])
        }
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
            let suppliedName = request.header("x-droprr-filename")?.removingPercentEncoding
                ?? request.header("content-disposition").flatMap(Self.filename(in:))
                ?? ""
            if mime == "text/plain" && suppliedName.isEmpty {
                return [try classify(String(decoding: try Data(contentsOf: bodyFile), as: UTF8.self), into: dir)]
            }
            // Lenient input: any other body is a raw file (iOS Shortcuts "File" request bodies).
            var filename = suppliedName.isEmpty ? Self.fallbackName() : suppliedName
            if (filename as NSString).pathExtension.isEmpty { filename += ".\(Self.rawExtensions[mime] ?? "bin")" }
            let dest = uniqueDestination(for: filename, in: dir)
            try FileManager.default.moveItem(at: bodyFile, to: dest)
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
                let dest = uniqueDestination(for: filename.isEmpty ? Self.fallbackName() + ".bin" : filename, in: dir)
                try body.write(to: dest)
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
            let plist: [String: Any] = ["URL": url.absoluteString]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: uniqueDestination(for: "Link \(Self.stamp()).webloc", in: dir))
            return ReceivedItem(kind: .url(url))
        }
        try Data(content.utf8).write(to: uniqueDestination(for: "Text \(Self.stamp()).txt", in: dir))
        return ReceivedItem(kind: .text(content))
    }

    // MARK: - Helpers

    private static func isLoopback(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "::1" || host.hasPrefix("127.") || host.hasPrefix("::ffff:127.")
    }

    private func uniqueDestination(for rawName: String, in inbox: URL) -> URL {
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var name = (rawName as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        if name.isEmpty || name.hasPrefix(".") { name = "Droprr \(Self.stamp())" + name }
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

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
