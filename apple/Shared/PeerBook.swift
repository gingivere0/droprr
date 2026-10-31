import Foundation

/// The rules for adding and updating peers when a device pairs, shared by the Mac and the iPhone (the Windows app
/// keeps the same rules in Peers/PeerBook.cs).
extension DroprrSettings {
    /// The peer a device pairing again is, if it's paired already: the one with its device id or certificate, of the
    /// same kind. A record of another kind (a browser, or a phone versus a computer) is never reused; that device is
    /// added as a new peer instead.
    func repairablePeer(deviceID: String?, fingerprint: String?, isPhone: Bool) -> UUID? {
        let fingerprint = fingerprint?.lowercased()
        return peers.first { peer in
            ((deviceID != nil && peer.deviceID == deviceID) || (fingerprint != nil && peer.fingerprint?.lowercased() == fingerprint))
                && !peer.isBrowser && peer.isPhone == isPhone
        }?.id
    }

    /// Adds the device that paired, or updates the peer `request.target` names, and returns the peer's id.
    /// A device token (`.update`) updates only its own peer; a confirmed new pairing (`.new`) always adds an entry;
    /// the main token (`.match`, QR pairing) matches the device id, then the name.
    @discardableResult
    func applyPairing(_ request: PairRequest) -> UUID {
        let match: Int?
        switch request.target {
        case .update(let id), .repair(let id):
            match = peers.firstIndex { $0.id == id }
        case .new:
            match = nil
        case .match:
            match = request.deviceID.flatMap { id in peers.firstIndex { $0.deviceID == id } }
                ?? peers.firstIndex { $0.matches(deviceName: request.name) }
        }
        let peerID: UUID
        if let i = match {
            var peer = peers[i]
            peer.platform = request.platform
            peer.remoteName = request.name
            // Keep a host we already have for a known computer.
            if peer.host.isEmpty { peer.host = request.host }
            if request.platform != "ios" && peer.host == request.host { peer.port = request.port }
            // Pairing again replaces the device token, so the old one stops working.
            peer.acceptToken = request.acceptToken
            if let token = request.token { peer.token = token }
            else if request.platform == "ios" { peer.token = nil }
            peers[i] = peer
            peerID = peer.id
        } else {
            let peer = Peer(name: uniqueName(request.name), host: request.host, port: request.port,
                            platform: request.platform, remoteName: request.name,
                            token: request.token, acceptToken: request.acceptToken)
            peers.append(peer)
            peerID = peer.id
        }
        // Pairing is where a fingerprint gets pinned (or replaced). A device token may only fill in an id or pin its
        // peer doesn't have yet (protocol 1 upgrade).
        learn(peerID, deviceID: request.deviceID, fingerprint: request.fingerprint, tlsPort: request.tlsPort,
              lan: request.lan, replacePin: request.target.replacesIdentity && request.fingerprint != nil)
        return peerID
    }
}
