import Foundation
import Network

/// A deliberately small HTTP/1.1 server: one request per connection, request bodies
/// streamed to a temp file (Content-Length or chunked), `Expect: 100-continue` honoured.
/// The plain HTTP server accepts only loopback and Tailscale (100.64.0.0/10, fd7a:115c:a1e0::/48)
/// clients; the HTTPS one (protocol 2) also accepts private LAN addresses.
final class HTTPServer {
    enum Policy {
        /// Plain HTTP: loopback and Tailscale only.
        case tailnet
        /// HTTPS: loopback, Tailscale and private LAN ranges (never link-local IPv4).
        case lan
    }

    let policy: Policy
    private let identity: sec_identity_t?

    init(policy: Policy = .tailnet, identity: sec_identity_t? = nil) {
        self.policy = policy
        self.identity = identity
    }

    struct Request {
        var method: String
        var path: String
        var headers: [String: String]   // lowercased names
        var bodyFile: URL?
        var remoteHost: String?
        /// True when it arrived on the HTTPS (protocol 2) listener.
        var secure = false

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    struct Response {
        var status: Int
        var body: Data
        var contentType = "application/json"
        var headers: [String: String] = [:]
        /// When set, the body is streamed from this file instead of `body`.
        var file: URL?

        static func json(_ status: Int, _ object: [String: Any]) -> Response {
            Response(status: status, body: (try? JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes)) ?? Data())
        }
    }

    /// Called once headers arrive. Return a response to reject the request before its body is read.
    var precheck: (Request) -> Response? = { _ in nil }
    var handler: (Request) async -> Response = { _ in .json(404, ["ok": false, "error": "not found"]) }
    var onStateChange: (String) -> Void = { _ in }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "droprr.http")

    /// Starts listening. `service` advertises the listener with Bonjour (HTTPS only).
    func start(port: Int, service: NWListener.Service? = nil) throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        let params: NWParameters
        if let identity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: tls, tcp: .init())
        } else {
            params = .tcp
        }
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: nwPort)
        listener.service = service
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready: self?.onStateChange("Listening on port \(port)")
            case .failed(let error):
                self?.onStateChange("Receiver stopped: \(error.localizedDescription)")
                // Network changes (Wi-Fi, Tailscale up or down) can fail a listener; start again shortly.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard let self, let listener, self.listener === listener else { return }
                    try? self.start(port: port, service: service)
                }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard Self.isAllowed(connection.endpoint, policy: self.policy) else { connection.cancel(); return }
            HTTPConnection(connection: connection, server: self).start(on: self.queue)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Updates the Bonjour advertisement (for example after a rename) without restarting.
    func advertise(_ service: NWListener.Service?) {
        listener?.service = service
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    static func isAllowed(_ endpoint: NWEndpoint, policy: Policy = .tailnet) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let addr):
            return isAllowedV4(Array(addr.rawValue), policy: policy)
        case .ipv6(let addr):
            let b = Array(addr.rawValue)
            if addr == .loopback { return true }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                return isAllowedV4(Array(b[12..<16]), policy: policy)   // IPv4-mapped
            }
            if b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0 { return true }
            guard policy == .lan else { return false }
            return b[0] == 0xfd || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80)   // fd00::/8, fe80::/10
        default:
            return false
        }
    }

    private static func isAllowedV4(_ b: [UInt8], policy: Policy) -> Bool {
        guard b.count == 4 else { return false }
        if b[0] == 127 || (b[0] == 100 && (b[1] & 0xc0) == 64) { return true }
        guard policy == .lan else { return false }
        return b[0] == 10 || (b[0] == 172 && (b[1] & 0xf0) == 16) || (b[0] == 192 && b[1] == 168)
    }
}

private final class HTTPConnection {
    private let connection: NWConnection
    private let server: HTTPServer
    private var buffer = Data()
    private var request: HTTPServer.Request?
    private var bodyHandle: FileHandle?
    private var remaining = 0
    private var chunked = false
    private var retainSelf: HTTPConnection?

    private static let maxHeaderBytes = 64 * 1024

    init(connection: NWConnection, server: HTTPServer) {
        self.connection = connection
        self.server = server
    }

    func start(on queue: DispatchQueue) {
        retainSelf = self
        self.queue = queue
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Also require the *local* address to fit the policy, so a LAN client that gives itself
                // a 100.64.x.x address can't reach the plain HTTP listener through Wi-Fi or Ethernet.
                guard let local = self.connection.currentPath?.localEndpoint,
                      HTTPServer.isAllowed(local, policy: self.server.policy) else {
                    self.connection.cancel()
                    return
                }
                self.armTimeout(seconds: Self.headerTimeout)
                self.receive()
            case .failed, .cancelled:
                self.cleanup()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: Limits

    private static let headerTimeout: TimeInterval = 30   // to finish sending headers
    private static let idleTimeout: TimeInterval = 60     // between body packets
    private static let minimumFreeSpace: Int64 = 1_000_000_000
    private var queue: DispatchQueue?
    private var timeout: DispatchWorkItem?

    /// Closes the connection if nothing more arrives in time.
    private func armTimeout(seconds: TimeInterval) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.connection.cancel()
        }
        timeout = work
        queue?.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Free space on the volume that holds temporary and received files.
    private static func freeSpace() -> Int64? {
        let url = FileManager.default.temporaryDirectory
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if (isComplete || error != nil) && self.retainSelf != nil && !self.finished {
                self.connection.cancel()
            }
        }
    }

    private var finished = false

    private func consume(_ data: Data) {
        buffer.append(data)
        if request != nil { armTimeout(seconds: Self.idleTimeout) }
        if request == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > Self.maxHeaderBytes { respond(.json(431, ["ok": false, "error": "headers too large"])) }
                else { receive() }
                return
            }
            let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            buffer = Data(buffer[end.upperBound...])
            guard let req = parseHead(head) else {
                respond(.json(400, ["ok": false, "error": "bad request"]))
                return
            }
            request = req
            armTimeout(seconds: Self.idleTimeout)
            if let rejection = server.precheck(req) {
                respond(rejection)
                return
            }
            chunked = req.header("transfer-encoding")?.lowercased().contains("chunked") == true
            remaining = Int(req.header("content-length") ?? "") ?? 0
            if remaining > 0, let free = Self.freeSpace(), free - Int64(remaining) < Self.minimumFreeSpace {
                respond(.json(507, ["ok": false, "error": "not enough disk space"]))
                return
            }
            if chunked || remaining > 0 {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("droprr-recv-\(UUID().uuidString)")
                FileManager.default.createFile(atPath: file.path, contents: nil)
                bodyHandle = try? FileHandle(forWritingTo: file)
                request?.bodyFile = file
                if req.header("expect")?.lowercased() == "100-continue" {
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                }
            }
        }
        if chunked ? drainChunked() : drainFixed() {
            try? bodyHandle?.close()
            bodyHandle = nil
            dispatch()
        } else {
            receive()
        }
    }

    /// Returns true once the whole body has been written.
    private func drainFixed() -> Bool {
        if remaining > 0 && !buffer.isEmpty {
            let take = buffer.prefix(remaining)
            try? bodyHandle?.write(contentsOf: take)
            remaining -= take.count
            buffer = Data(buffer.dropFirst(take.count))
        }
        return remaining <= 0
    }

    private func drainChunked() -> Bool {
        let crlf = Data("\r\n".utf8)
        while true {
            if remaining > 0 {
                // Need chunk data plus its trailing CRLF.
                guard buffer.count >= remaining + 2 else { return false }
                try? bodyHandle?.write(contentsOf: buffer.prefix(remaining))
                buffer = Data(buffer.dropFirst(remaining + 2))
                remaining = 0
            }
            guard let lineEnd = buffer.range(of: crlf) else { return false }
            let line = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
            let sizeText = line.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let size = Int(sizeText, radix: 16) else { return true }   // malformed: stop reading
            buffer = Data(buffer[lineEnd.upperBound...])
            if size == 0 { return true }   // trailers ignored
            remaining = size
        }
    }

    private func parseHead(_ head: String) -> HTTPServer.Request? {
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rawPath = String(parts[1])
        let path = rawPath
        var remoteHost: String?
        if case .hostPort(let host, _) = connection.endpoint { remoteHost = "\(host)".components(separatedBy: "%").first }
        return .init(method: String(parts[0]).uppercased(), path: path, headers: headers, bodyFile: nil, remoteHost: remoteHost,
                     secure: server.policy == .lan)
    }

    private func dispatch() {
        guard let request else { return }
        finished = true
        Task {
            let response = await server.handler(request)
            respond(response)
        }
    }

    private func respond(_ response: HTTPServer.Response) {
        finished = true
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 415: "Unsupported Media Type",
                       507: "Insufficient Storage",
                       431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable"]
        let reason = reasons[response.status] ?? "Status"
        var length = response.body.count
        var input: FileHandle?
        if let file = response.file, let handle = try? FileHandle(forReadingFrom: file) {
            input = handle
            length = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(length)\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Connection: close\r\n\r\n"
        guard let input else {
            connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
            return
        }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        sendChunks(from: input)
    }

    /// Streams a file one chunk at a time, waiting for each send so memory stays flat.
    private func sendChunks(from input: FileHandle) {
        let chunk = (try? input.read(upToCount: 1 << 20)) ?? nil
        guard let chunk, !chunk.isEmpty else {
            try? input.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { try? input.close(); return }
            self.sendChunks(from: input)
        })
    }

    private func cleanup() {
        timeout?.cancel()
        timeout = nil
        try? bodyHandle?.close()
        bodyHandle = nil
        if let file = request?.bodyFile { try? FileManager.default.removeItem(at: file) }
        retainSelf = nil
    }
}
