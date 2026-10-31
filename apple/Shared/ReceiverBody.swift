import CryptoKit
import Foundation
import Network

// Reading what a POST /send carries (docs/PROTOCOL.md, "POST /send"): multipart, JSON, forms, plain text, and raw
// files, saved into the inbox.
extension DroprrReceiver {
    struct Failure: Error {
        let status: Int
        let message: String
        init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    }

    func receive(_ request: HTTPServer.Request, into dir: URL) throws -> [ReceivedItem] {
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

    func receiveForm(_ bodyFile: URL, into dir: URL) throws -> [ReceivedItem] {
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

    func receiveMultipart(_ bodyFile: URL, boundary: String, into dir: URL) throws -> [ReceivedItem] {
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
    func classify(_ value: String, into dir: URL) throws -> ReceivedItem {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: { $0.isWhitespace }), let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
            return try textItem(type: "url", content: trimmed, into: dir)
        }
        return try textItem(type: "text", content: value, into: dir)
    }

    /// Validates a text or url item and saves a copy next to received files, as the protocol asks.
    func textItem(type: String, content: String, into dir: URL) throws -> ReceivedItem {
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

    /// Saves under a free name, never overwriting: if another transfer takes the name first, the next
    /// " (n)" is tried.
    func saveUnique(_ name: String, in dir: URL, _ write: (URL) throws -> Void) throws -> URL {
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

    func uniqueDestination(for rawName: String, in inbox: URL) -> URL {
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

    static let rawExtensions = [
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
    static func fallbackName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return "Droprr \(f.string(from: Date()))"
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }
}
