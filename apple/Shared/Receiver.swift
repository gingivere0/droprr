import Foundation
import UniformTypeIdentifiers

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
        switch (request.method, request.path) {
        case ("GET", "/ping"), ("POST", "/send"): return nil
        default: return .json(404, ["ok": false, "error": "not found"])
        }
    }

    private func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        if request.path == "/ping" {
            return .json(200, ["name": settings.deviceName, "version": DroprrDefaults.version, "platform": DroprrSettings.platform])
        }
        do {
            let items = try receive(request)
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

    private func receive(_ request: HTTPServer.Request) throws -> [ReceivedItem] {
        let contentType = request.header("content-type") ?? ""
        let mime = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard let bodyFile = request.bodyFile else { throw Failure(400, "empty body") }

        switch mime {
        case "application/json", "multipart/form-data":
            break
        case "application/x-www-form-urlencoded":
            return try receiveForm(bodyFile)
        case "text/plain":
            return [try textItem(type: "text", content: String(decoding: try Data(contentsOf: bodyFile), as: UTF8.self))]
        default:
            // Lenient input: any other body is a raw file (iOS Shortcuts "File" request bodies).
            let ext = UTType(mimeType: mime)?.preferredFilenameExtension
            var filename = request.header("x-droprr-filename")?.removingPercentEncoding
                ?? request.header("content-disposition").flatMap { Self.parameter("filename", in: $0) }
                ?? ""
            if filename.isEmpty {
                filename = "Droprr \(Self.stamp())" + (ext.map { ".\($0)" } ?? "")
            } else if (filename as NSString).pathExtension.isEmpty, let ext {
                filename += ".\(ext)"
            }
            let dest = uniqueDestination(for: filename)
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
            return [try textItem(type: type, content: object["content"] as? String ?? "")]
        }

        guard let boundary = Self.parameter("boundary", in: contentType) else { throw Failure(400, "missing multipart boundary") }
        return try receiveMultipart(bodyFile, boundary: boundary)
    }

    private func receiveForm(_ bodyFile: URL) throws -> [ReceivedItem] {
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: try Data(contentsOf: bodyFile), as: UTF8.self)
            .replacingOccurrences(of: "+", with: "%20")
        var fields: [String: String] = [:]
        for item in components.queryItems ?? [] { fields[item.name] = item.value ?? "" }
        var items: [ReceivedItem] = []
        if let content = fields["content"] { items.append(try textItem(type: fields["type"] == "url" ? "url" : "text", content: content)) }
        if let text = fields["text"] { items.append(try textItem(type: "text", content: text)) }
        if let url = fields["url"] { items.append(try textItem(type: "url", content: url)) }
        return items
    }

    private func receiveMultipart(_ bodyFile: URL, boundary: String) throws -> [ReceivedItem] {
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
            if let filename = Self.parameter("filename", in: disposition) {
                let dest = uniqueDestination(for: filename.isEmpty ? "Droprr \(Self.stamp())" : filename)
                try body.write(to: dest)
                items.append(ReceivedItem(kind: .file(dest)))
            } else if let field = Self.parameter("name", in: disposition), field == "text" || field == "url" {
                items.append(try textItem(type: field, content: String(decoding: body, as: UTF8.self)))
            }
        }
        return items
    }

    /// Validates a text or url item and saves a copy next to received files, as the protocol asks.
    private func textItem(type: String, content: String) throws -> ReceivedItem {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure(400, "empty content") }
        if type == "url" {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.contains(where: \.isNewline), let url = URL(string: trimmed),
                  let scheme = url.scheme, !scheme.isEmpty else { throw Failure(400, "invalid URL") }
            let plist: [String: Any] = ["URL": url.absoluteString]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: uniqueDestination(for: "Link \(Self.stamp()).webloc"))
            return ReceivedItem(kind: .url(url))
        }
        try Data(content.utf8).write(to: uniqueDestination(for: "Text \(Self.stamp()).txt"))
        return ReceivedItem(kind: .text(content))
    }

    // MARK: - Helpers

    private func uniqueDestination(for rawName: String) -> URL {
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
