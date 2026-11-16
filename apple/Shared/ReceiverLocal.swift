import Foundation

/// The local API (docs/PROTOCOL.md, "Local API"): tools on this Mac, such as the Droprr MCP server for AI
/// assistants, list this Mac's devices and send to them through the app (GET /local/devices, POST /local/send).
/// It answers only this Mac, and only with the local token, which works for nothing else. The same requests and
/// messages as the Windows app's LocalApi.cs.
extension DroprrReceiver {
    /// Made fresh each time Droprr starts, and written to the connection file for local tools to read.
    static let localToken = DroprrSettings.generateToken()

    /// ~/Library/Application Support/Droprr/local-api.json: the plain HTTP address on loopback and the local token.
    static var localConnectionFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Droprr/local-api.json")
    }

    static let localApiSendShape = #"{"to": "<device name>", "text": "...", "files": ["<absolute path>"]}"#

    /// Lets local tools find this receiver. Readable only by this user.
    func writeLocalConnectionFile() {
        guard localApiSend != nil else { return }
        let file = Self.localConnectionFile
        let temp = file.deletingLastPathComponent().appendingPathComponent("local-api.json.tmp")
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let body = try JSONSerialization.data(withJSONObject: ["url": "http://127.0.0.1:\(settings.port)", "token": Self.localToken],
                                                  options: .withoutEscapingSlashes)
            try? FileManager.default.removeItem(at: temp)
            guard FileManager.default.createFile(atPath: temp.path, contents: body, attributes: [.posixPermissions: 0o600]),
                  rename(temp.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            NSLog("Droprr: couldn't write the local API connection file: %@", String(describing: error))
        }
    }

    /// Only over plain HTTP from this Mac, never from a web page (a page's request carries an Origin), and only
    /// with the local token.
    func precheckLocal(_ request: HTTPServer.Request) -> HTTPServer.Response? {
        let notFound = HTTPServer.Response.json(404, ["ok": false, "error": "not found"])
        guard localApiSend != nil, !request.secure, !request.browserPort, Self.isLoopback(request.remoteHost),
              request.header("origin") == nil else { return notFound }
        let header = (request.header("authorization") ?? "").trimmingCharacters(in: .whitespaces)
        guard header.lowercased().hasPrefix("bearer "),
              DroprrSettings.constantTimeEqual(String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces), Self.localToken) else {
            var response = HTTPServer.Response.json(401, ["ok": false, "error": "unauthorized"])
            response.headers["WWW-Authenticate"] = "Bearer"
            return response
        }
        switch (request.method, Route(request).segments) {
        case ("GET", ["local", "devices"]), ("POST", ["local", "send"]): return nil
        default: return notFound
        }
    }

    func handleLocal(_ request: HTTPServer.Request, _ route: Route) async -> HTTPServer.Response {
        guard let localApiSend else { return .json(404, ["ok": false, "error": "not found"]) }
        // Settings belong to the main thread.
        let settings = self.settings
        let (name, peers) = await MainActor.run { (settings.deviceName, settings.peers) }
        if route.segments == ["local", "devices"] {
            let devices: [[String: Any]] = peers.map { peer in
                [
                    "name": peer.name,
                    "platform": (peer.platform ?? "").isEmpty ? "unknown" : peer.platform!,
                    "kind": peer.isBrowser ? "browser" : peer.isPhone ? "phone" : "computer",
                    "paired": peer.isPaired,
                    "waiting": peer.isPhone || peer.isBrowser ? outbox?.count(for: peer) ?? 0 : 0,
                ]
            }
            return .json(200, ["ok": true, "name": name, "devices": devices])
        }
        let body = request.bodyFile.flatMap { try? Data(contentsOf: $0) } ?? Data()
        let send: (peer: Peer, payloads: [SendPayload])
        switch Self.parseLocalApiSend(body, peers: peers) {
        case .failure(let failure): return .json(failure.status, ["ok": false, "error": failure.message])
        case .success(let parsed): send = parsed
        }
        do {
            let path = try await localApiSend(send.peer, send.payloads)
            return .json(200, ["ok": true, "to": send.peer.name, "path": path])
        } catch {
            // The local caller sees why, as the Send window would show it.
            let message = error.localizedDescription
            return .json(502, ["ok": false, "error": message.contains(send.peer.name) ? message : "\(send.peer.name): \(message)"])
        }
    }

    /// POST /local/send's body, checked against this Mac's devices and files: files first, then the text, which is
    /// sent as a link when it's a single http(s) URL.
    static func parseLocalApiSend(_ body: Data, peers: [Peer]) -> Result<(peer: Peer, payloads: [SendPayload]), Failure> {
        guard let object = try? JSONSerialization.jsonObject(with: body), let json = object as? [String: Any] else {
            return .failure(Failure(400, "body must be JSON: \(localApiSendShape)"))
        }
        guard let to = (json["to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty else {
            return .failure(Failure(400, #"missing "to": the name of the device to send to"#))
        }
        guard let peer = peers.first(where: { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(to) == .orderedSame }) else {
            return .failure(Failure(404, peers.isEmpty
                ? "no device named \"\(to)\": this computer has no devices yet. Pair one in Droprr first."
                : "no device named \"\(to)\". Devices: \(peers.map(\.name).joined(separator: ", "))"))
        }
        guard peer.isPaired else {
            return .failure(Failure(409, "\(peer.name) isn't paired. Scan its code or enter its token in Droprr's Settings."))
        }

        var text = ""
        if let value = json["text"], !(value is NSNull) {
            guard let string = value as? String else { return .failure(Failure(400, #""text" must be a string"#)) }
            text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var files: [URL] = []
        if let value = json["files"], !(value is NSNull) {
            guard let list = value as? [Any] else { return .failure(Failure(400, #""files" must be an array of absolute paths"#)) }
            for item in list {
                guard let path = item as? String, path.hasPrefix("/") else {
                    return .failure(Failure(400, #"each of "files" must be an absolute path"#))
                }
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else {
                    return .failure(Failure(400, "no file at \(path)"))
                }
                if isFolder.boolValue { return .failure(Failure(400, "\(path) is a folder. Only files can be sent.")) }
                files.append(URL(fileURLWithPath: path))
            }
        }
        guard !text.isEmpty || !files.isEmpty else {
            return .failure(Failure(400, #"nothing to send: give "text", "files", or both"#))
        }

        var payloads: [SendPayload] = []
        if !files.isEmpty { payloads.append(.files(files)) }
        if !text.isEmpty {
            if !text.contains(where: \.isWhitespace), let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                payloads.append(.url(url))
            } else {
                payloads.append(.text(text))
            }
        }
        return .success((peer, payloads))
    }
}
