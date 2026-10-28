import Foundation
import Network

/// A deliberately small HTTP/1.1 server: one request per connection, request bodies
/// streamed to a temp file (Content-Length or chunked), `Expect: 100-continue` honoured.
/// Only loopback and Tailscale (100.64.0.0/10, fd7a:115c:a1e0::/48) clients are accepted.
final class HTTPServer {
    struct Request {
        var method: String
        var path: String
        var headers: [String: String]   // lowercased names
        var bodyFile: URL?

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    struct Response {
        var status: Int
        var body: Data
        var contentType = "application/json"

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

    func start(port: Int) throws {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: nwPort)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onStateChange("Listening on port \(port)")
            case .failed(let error): self?.onStateChange("Receiver stopped: \(error.localizedDescription)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard Self.isAllowed(connection.endpoint) else { connection.cancel(); return }
            HTTPConnection(connection: connection, server: self).start(on: self.queue)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    static func isAllowed(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let addr):
            return isAllowedV4(Array(addr.rawValue))
        case .ipv6(let addr):
            let b = Array(addr.rawValue)
            if addr == .loopback { return true }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                return isAllowedV4(Array(b[12..<16]))   // IPv4-mapped
            }
            return b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0
        default:
            return false
        }
    }

    private static func isAllowedV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        return b[0] == 127 || (b[0] == 100 && (b[1] & 0xc0) == 64)
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
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.cleanup()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
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
            if let rejection = server.precheck(req) {
                respond(rejection)
                return
            }
            chunked = req.header("transfer-encoding")?.lowercased().contains("chunked") == true
            remaining = Int(req.header("content-length") ?? "") ?? 0
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
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
        return .init(method: String(parts[0]).uppercased(), path: path, headers: headers, bodyFile: nil)
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
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.status).capitalized
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func cleanup() {
        try? bodyHandle?.close()
        bodyHandle = nil
        if let file = request?.bodyFile { try? FileManager.default.removeItem(at: file) }
        retainSelf = nil
    }
}
