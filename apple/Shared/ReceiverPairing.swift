import CryptoKit
import Foundation
import Network

// Pairing (docs/PROTOCOL.md): POST /pair, and LAN pairing v2 (POST /pair/request, POST /pair/confirm).
extension DroprrReceiver {
    /// POST /pair: a device that scanned this device's code (or a computer pairing with it) introduces itself.
    /// This device mints a device token for it and keeps the token the caller minted, if any.
    func handlePair(_ request: HTTPServer.Request, onPair: (PairRequest) -> Void) -> HTTPServer.Response {
        guard let body = request.bodyFile, let data = try? Data(contentsOf: body),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .json(400, ["ok": false, "error": "expected a JSON body"])
        }
        guard let name = (json["name"] as? String).map(PairRequest.displayName), !name.isEmpty else {
            return .json(400, ["ok": false, "error": "missing name"])
        }
        guard let platform = (json["platform"] as? String)?.lowercased(), ["ios", "macos", "windows"].contains(platform) else {
            return .json(400, ["ok": false, "error": "platform must be ios, macos or windows"])
        }
        var host = (json["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if platform != "ios" && host.isEmpty {
            return .json(400, ["ok": false, "error": "computers must send host"])
        }
        // Plain HTTP only ever goes to Tailscale, so only keep a Tailscale host.
        if !PairingInfo.isTailscaleHost(host) { host = "" }
        var port = DroprrDefaults.port
        if let raw = json["port"], !(raw is NSNull) {
            guard let value = raw as? Int, (1...65535).contains(value) else {
                return .json(400, ["ok": false, "error": "bad port"])
            }
            port = value
        }
        // With the join secret, like LAN pairing: a new peer, or the same device pairing again (below).
        let joined = isJoin(request)
        let deviceID = Self.deviceID(json["id"])
        let fingerprint = request.clientFingerprint ?? Self.fingerprint(json["fp"])
        // Pairing again just works (docs/PROTOCOL.md, "Pairing rules"): the open code is the authorization, so a
        // peer of the same kind with the caller's id or certificate gets fresh tokens and the caller's current id
        // and pin. A match of another kind (or a browser) is left alone and the caller is added as a new peer.
        var repairID: UUID?
        if joined {
            repairID = DispatchQueue.main.sync {
                settings.repairablePeer(deviceID: deviceID, fingerprint: fingerprint, isPhone: platform == "ios")
            }
        }
        let callerToken = (json["token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let minted = DroprrSettings.generateToken()
        // Store before answering, so the caller's very next request with the new token is accepted.
        // Protocol 2 phones also mint a token, for direct sends while Droprr is open on them.
        let target: PairTarget
        if let repairID {
            target = .repair(repairID)
        } else if case .device(let id) = authorization(request) {
            target = .update(id)
        } else {
            target = joined ? .new : .match
        }
        let pair = PairRequest(name: name, platform: platform, host: host, port: port,
                               token: callerToken, acceptToken: minted,
                               deviceID: deviceID, fingerprint: fingerprint,
                               tlsPort: json["tlsPort"] as? Int, lan: json["lan"] as? [String], target: target)
        DispatchQueue.main.sync { onPair(pair) }
        return .json(200, responseFields(token: minted))
    }

    // MARK: - LAN pairing v2 (POST /pair/request, POST /pair/confirm)

    /// An open pairing: the requester's commitment and certificate, and this device's nonce.
    struct PairSession {
        var id: String
        var requesterID: String
        var name: String
        var platform: String
        var commit: Data
        var clientFingerprint: String
        var nonceS: Data
        var created: Date
        var prompting = false
    }

    /// A protocol device id: 26 lowercase base32 characters.
    static func deviceID(_ value: Any?) -> String? {
        guard let text = (value as? String)?.lowercased(), text.count == 26,
              text.allSatisfy({ ("a"..."z").contains($0) || ("2"..."7").contains($0) }) else { return nil }
        return text
    }

    static func fingerprint(_ value: Any?) -> String? {
        guard let text = (value as? String)?.lowercased(), text.count == 64, text.allSatisfy(\.isHexDigit) else { return nil }
        return text
    }

    /// The six digits both devices show: SHA-256 of "fpLow:fpHigh:nonceR:nonceS" (lowercase hex),
    /// first 4 bytes as a big-endian integer, modulo 1,000,000.
    static func pairingCode(fpA: String, fpB: String, nonceR: Data, nonceS: Data) -> String {
        let fps = [fpA.lowercased(), fpB.lowercased()].sorted()
        let text = "\(fps[0]):\(fps[1]):\(nonceR.hexString):\(nonceS.hexString)"
        let digest = Array(SHA256.hash(data: Data(text.utf8)))
        let value = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
        return String(format: "%06u", value % 1_000_000)
    }

    func readJSON(_ request: HTTPServer.Request) -> [String: Any]? {
        guard let body = request.bodyFile, let data = try? Data(contentsOf: body) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Three declines, timeouts or wrong reveals from one address within 10 minutes: 429 for 10 minutes.
    func isBlocked(_ address: String) -> Bool {
        pairLock.withLock {
            let now = Date()
            pairStrikes[address] = pairStrikes[address]?.filter { now.timeIntervalSince($0) < 600 }
            return (pairStrikes[address]?.count ?? 0) >= 3
        }
    }

    func strike(_ address: String) {
        pairLock.withLock { pairStrikes[address, default: []].append(Date()) }
    }

    /// Step 1: the requester commits to its nonce; this device answers with its own right away.
    func handlePairRequest(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        guard onPairRequest != nil, onPair != nil, settings.identity != nil else { return .json(404, ["ok": false, "error": "not found"]) }
        let address = request.remoteHost ?? ""
        guard let clientFP = request.clientFingerprint else {
            return .json(400, ["ok": false, "error": "a client certificate is required"])
        }
        guard let json = readJSON(request),
              let id = Self.deviceID(json["id"]),
              let name = (json["name"] as? String).map(PairRequest.displayName), !name.isEmpty,
              let platform = (json["platform"] as? String)?.lowercased(), ["ios", "macos", "windows"].contains(platform),
              let commitHex = (json["commit"] as? String)?.lowercased(), let commit = Data(hex: commitHex), commit.count == 32 else {
            return .json(400, ["ok": false, "error": "expected id, name, platform and commit"])
        }
        if let bodyFP = json["fp"] { guard Self.fingerprint(bodyFP) == clientFP else {
            return .json(400, ["ok": false, "error": "fp doesn't match the client certificate"])
        } }
        if isBlocked(address) { return .json(429, ["ok": false, "error": "try again later"]) }

        var nonceS = Data(count: 32)
        _ = nonceS.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let session = PairSession(id: UUID().uuidString.lowercased(), requesterID: id, name: name, platform: platform,
                                  commit: commit, clientFingerprint: clientFP, nonceS: nonceS, created: Date())
        let opened: Bool = pairLock.withLock {
            if let open = pairSession, open.prompting || Date().timeIntervalSince(open.created) < 30 { return false }
            pairSession = session
            return true
        }
        guard opened else { return .json(429, ["ok": false, "error": "another pairing is in progress"]) }
        return .json(200, ["ok": true, "session": session.id, "nonce": nonceS.hexString])
    }

    /// Step 2: the requester reveals its nonce; check it, ask the person, and pair on Pair.
    func handlePairConfirm(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        guard let ask = onPairRequest, let onPair, let ownFP = settings.identity?.fingerprint else {
            return .json(404, ["ok": false, "error": "not found"])
        }
        let address = request.remoteHost ?? ""
        let notFound = HTTPServer.Response.json(404, ["ok": false, "error": "no such pairing"])
        guard let clientFP = request.clientFingerprint, let json = readJSON(request),
              let sessionID = json["session"] as? String else { return notFound }
        // The open session, from the same certificate, not expired and not already being asked about.
        let session: PairSession? = pairLock.withLock {
            guard var open = pairSession, open.id == sessionID, open.clientFingerprint == clientFP,
                  !open.prompting, Date().timeIntervalSince(open.created) < 30 else { return nil }
            open.prompting = true
            pairSession = open
            return open
        }
        guard let session else { return notFound }
        defer { pairLock.withLock { if pairSession?.id == session.id { pairSession = nil } } }

        guard let nonceHex = (json["nonce"] as? String)?.lowercased(), let nonceR = Data(hex: nonceHex), nonceR.count == 32,
              Data(SHA256.hash(data: nonceR)) == session.commit else {
            strike(address)
            return .json(400, ["ok": false, "error": "the nonce doesn't match the commitment"])
        }
        let code = Self.pairingCode(fpA: ownFP, fpB: session.clientFingerprint, nonceR: nonceR, nonceS: session.nonceS)
        let question = LANPairRequest(name: session.name, platform: session.platform, code: code)
        let answer: Bool? = await withTaskGroup(of: Bool?.self) { group in
            group.addTask { @MainActor in await ask(question) }
            group.addTask {
                try? await Task.sleep(for: .seconds(60))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard answer == true else {
            strike(address)
            return answer == nil ? .json(408, ["ok": false, "error": "timed out"]) : .json(403, ["ok": false, "error": "declined"])
        }
        let minted = DroprrSettings.generateToken()
        var port = DroprrDefaults.port
        if let value = json["port"] as? Int, (1...65535).contains(value) { port = value }
        let host = (json["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var pair = PairRequest(name: session.name, platform: session.platform,
                               host: PairingInfo.isTailscaleHost(host) ? host : "",
                               port: port, token: (json["token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                               acceptToken: minted, deviceID: session.requesterID, fingerprint: session.clientFingerprint,
                               tlsPort: json["tlsPort"] as? Int, lan: json["lan"] as? [String], target: .new)
        // Pairing again (the person just confirmed the code): a peer of the same kind with this id or certificate gets
        // the fresh tokens and the caller's current id and pin, instead of a second entry.
        let existing = await MainActor.run { [settings] in
            settings.repairablePeer(deviceID: session.requesterID, fingerprint: session.clientFingerprint,
                                    isPhone: session.platform == "ios")
        }
        if let existing { pair.target = .repair(existing) }
        let confirmed = pair
        await MainActor.run { onPair(confirmed) }
        return .json(200, responseFields(token: minted))
    }
}
