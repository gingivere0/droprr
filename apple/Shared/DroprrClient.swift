import Foundation
import UniformTypeIdentifiers

struct PingInfo: Codable {
    var name: String
    var version: String
    var platform: String
}

enum DroprrError: LocalizedError {
    case noToken
    case badPeer
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .noToken: return "Set the pairing token in Settings first."
        case .badPeer: return "That device's address isn't valid."
        case .server(let code, let message): return "The device answered \(code): \(message)"
        }
    }
}

/// Sends to another Droprr device. See docs/PROTOCOL.md.
struct DroprrClient {
    var peer: Peer
    var token: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config)
    }()

    func ping() async throws -> PingInfo {
        var request = try makeRequest(path: "/ping", method: "GET")
        request.timeoutInterval = 5
        let (data, response) = try await Self.session.data(for: request)
        try check(response, data)
        return try JSONDecoder().decode(PingInfo.self, from: data)
    }

    func send(text: String) async throws {
        try await sendJSON(type: "text", content: text)
    }

    func send(url: URL) async throws {
        try await sendJSON(type: "url", content: url.absoluteString)
    }

    func send(files: [URL]) async throws {
        guard !files.isEmpty else { return }
        let boundary = "droprr-\(UUID().uuidString)"
        let body = try Self.writeMultipart(files: files, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: body) }

        var request = try makeRequest(path: "/send", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await Self.session.upload(for: request, fromFile: body)
        try check(response, data)
    }

    private func sendJSON(type: String, content: String) async throws {
        var request = try makeRequest(path: "/send", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["type": type, "content": content])
        let (data, response) = try await Self.session.data(for: request)
        try check(response, data)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard !token.isEmpty else { throw DroprrError.noToken }
        guard let base = peer.baseURL, let url = URL(string: path, relativeTo: base) else { throw DroprrError.badPeer }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? String(data: data, encoding: .utf8) ?? ""
            throw DroprrError.server(http.statusCode, message)
        }
    }

    /// Streams the files into a temporary multipart body so large files never sit in memory.
    private static func writeMultipart(files: [URL], boundary: String) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("droprr-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }

        for file in files {
            let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
            let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n"
            try handle.write(contentsOf: Data(header.utf8))

            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
            try handle.write(contentsOf: Data("\r\n".utf8))
        }
        try handle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
        return out
    }
}
