import Foundation
import UniformTypeIdentifiers

struct PingInfo: Codable {
    var name: String
    var version: String
    var platform: String
    // Protocol 2
    var id: String?
    var fp: String?
    var tlsPort: Int?
    var proto: Int?

    enum CodingKeys: String, CodingKey {
        case name, version, platform, id, fp, tlsPort
        case proto = "protocol"
    }
}

enum DroprrError: LocalizedError {
    case notPaired
    case badPeer
    case server(Int, String)
    case identityChanged(String)

    var errorDescription: String? {
        switch self {
        case .notPaired: return "Not paired: scan its code or enter its token."
        case .badPeer: return "That device's address isn't valid."
        case .server(let code, let message): return "The device answered \(code): \(message)"
        case .identityChanged(let name): return "\(name)'s identity changed. Pair again."
        }
    }
}

/// Sends to another Droprr device. See docs/PROTOCOL.md.
struct DroprrClient {
    /// Requests carry `peer.token` only. This device's main token is never sent to another device.
    var peer: Peer
    /// "/send" normally; the Mac share extension uses "/outbox/<peer id>" on its own Mac to queue for a phone.
    var sendPath = "/send"

    enum Path: String {
        /// HTTPS to a LAN address, pinned to the peer's certificate (protocol 2).
        case lan
        /// Plain HTTP to the Tailscale host (protocol 1).
        case tailscale

        /// How a status message names it, as in "Sent to MacBook (Wi-Fi)".
        var label: String { self == .lan ? "Wi-Fi" : "Tailscale" }
    }

    /// The address requests go to; Tailscale unless `connect` found the peer on the LAN.
    private(set) var path = Path.tailscale
    private var lanBase: URL?

    init(peer: Peer, sendPath: String = "/send") {
        self.peer = peer
        self.sendPath = sendPath
    }

    /// Picks the path for a send: each fresh LAN address in turn over pinned HTTPS (about 1.5 s each),
    /// then Tailscale. Never both, so a body is never sent twice. Throws `identityChanged` only when the
    /// LAN answered with the wrong certificate and there's no Tailscale host to fall back to.
    static func connect(_ peer: Peer) async throws -> (client: DroprrClient, identityChanged: Bool) {
        var client = DroprrClient(peer: peer)
        guard let fp = peer.fingerprint, let token = peer.token, !token.isEmpty else { return (client, false) }
        var mismatch = false
        for base in peer.lanURLs {
            guard let url = URL(string: base.absoluteString + "/ping") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 1.5)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let trust = PinnedTrust(fingerprint: fp)
            let probe = URLSession(configuration: .ephemeral, delegate: trust, delegateQueue: nil)
            defer { probe.finishTasksAndInvalidate() }
            if let (_, response) = try? await probe.data(for: request),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                client.path = .lan
                client.lanBase = base
                return (client, false)
            }
            mismatch = mismatch || trust.mismatch
        }
        if mismatch && peer.baseURL == nil { throw DroprrError.identityChanged(peer.name) }
        return (client, mismatch)
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: config)
    }()

    /// One pinned HTTPS session per peer certificate.
    private static var pinnedSessions: [String: URLSession] = [:]
    private static let pinnedLock = NSLock()

    private var session: URLSession {
        guard path == .lan, let fp = peer.fingerprint else { return Self.session }
        return Self.pinnedLock.withLock {
            if let existing = Self.pinnedSessions[fp] { return existing }
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60 * 60
            let made = URLSession(configuration: config, delegate: PinnedTrust(fingerprint: fp), delegateQueue: nil)
            Self.pinnedSessions[fp] = made
            return made
        }
    }

    func ping() async throws -> PingInfo {
        var request = try makeRequest(path: "/ping", method: "GET")
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return try JSONDecoder().decode(PingInfo.self, from: data)
    }

    func send(text: String) async throws {
        try await sendJSON(type: "text", content: text)
    }

    func send(url: URL) async throws {
        try await sendJSON(type: "url", content: url.absoluteString)
    }

    func send(files: [URL], progress: ((Double) -> Void)? = nil) async throws {
        guard !files.isEmpty else { return }
        let boundary = "droprr-\(UUID().uuidString)"
        let body = try Self.writeMultipart(files: files, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: body) }

        var request = try makeRequest(path: sendPath, method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let delegate = progress.map(UploadProgress.init)
        let (data, response) = try await session.upload(for: request, fromFile: body, delegate: delegate)
        try check(response, data)
    }

    struct PairResult {
        var name: String
        /// The device token the desktop minted for this device; use it instead of the QR token from now on.
        var token: String?
        // Protocol 2: the desktop's identity, to pin.
        var deviceID: String?
        var fingerprint: String?
        var tlsPort: Int?
        var lan: [String]?
        /// The desktop's Tailscale host, for a fallback when paired over the LAN.
        var host: String?
    }

    /// Introduces this device to a desktop (POST /pair) so pairing works both ways.
    /// Computers pass their own address and a token they minted for that desktop; phones omit them.
    func pair(name: String, platform: String, host: String? = nil, port: Int? = nil, token: String? = nil) async throws -> PairResult {
        var request = try makeRequest(path: "/pair", method: "POST")
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["name": name, "platform": platform]
        if let host { body["host"] = host }
        if let port { body["port"] = port }
        if let token { body["token"] = token }
        body.merge(DroprrSettings.shared.ownIdentityFields) { a, _ in a }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return PairResult(name: json?["name"] as? String ?? peer.name,
                          token: (json?["token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                          deviceID: json?["id"] as? String, fingerprint: (json?["fp"] as? String)?.lowercased(),
                          tlsPort: json?["tlsPort"] as? Int, lan: json?["lan"] as? [String],
                          host: (json?["host"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: Inbox (phone pull, see docs/PROTOCOL.md)

    struct InboxItem: Decodable, Identifiable {
        var id: String
        var type: String
        var name: String
        var size: Int
        var content: String?
    }

    func inbox(for deviceName: String) async throws -> [InboxItem] {
        let name = deviceName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? deviceName
        var request = try makeRequest(path: "/inbox?for=\(name)", method: "GET")
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        struct Listing: Decodable { var items: [InboxItem] }
        return try JSONDecoder().decode(Listing.self, from: data).items
    }

    /// Downloads a file item to a temporary location; the caller moves it into place.
    func download(_ item: InboxItem) async throws -> URL {
        let request = try makeRequest(path: "/inbox/\(item.id)", method: "GET")
        let (temp, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DroprrError.server(http.statusCode, (try? String(contentsOf: temp, encoding: .utf8)) ?? "")
        }
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("droprr-inbox-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: temp, to: kept)
        return kept
    }

    func acknowledge(_ item: InboxItem) async throws {
        let request = try makeRequest(path: "/inbox/\(item.id)", method: "DELETE")
        let (data, response) = try await session.data(for: request)
        try check(response, data)
    }

    private func sendJSON(type: String, content: String) async throws {
        var request = try makeRequest(path: sendPath, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["type": type, "content": content])
        let (data, response) = try await session.data(for: request)
        try check(response, data)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let token = peer.token, !token.isEmpty else { throw DroprrError.notPaired }
        guard let base = lanBase ?? peer.baseURL, let url = URL(string: base.absoluteString + path) else { throw DroprrError.badPeer }
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

private final class UploadProgress: NSObject, URLSessionTaskDelegate {
    let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        DispatchQueue.main.async { self.report(fraction) }
    }
}
