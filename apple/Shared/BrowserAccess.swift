import Foundation
import Security

/// The live website and relay for Browser access over the internet (docs/PROTOCOL.md).
enum DroprrWeb {
    static let relay = "wss://droprr-relay.droprr-domain.workers.dev"
    static let site = "https://gingivere0.github.io/droprr/"
}

/// The join secret for Browser access over the internet (docs/PROTOCOL.md, "The code"): 16 random bytes, base64url,
/// in the one code's link. It works for any number of browsers, and stays open while anyone holds a lease on it:
/// Pair a phone while it's open, and a connected browser's Show QR code for 10 minutes. Each lease ends on its own,
/// so closing the window never cuts off a code a browser is still showing, and opening it never replaces one.
/// Never saved or logged.
final class BrowserAccess {
    /// A lease on the join secret, from `openJoin`, until `closeJoin` or its lifetime passes.
    final class JoinLease {
        fileprivate init() {}
    }

    static let lifetime: TimeInterval = 10 * 60

    private let lock = NSLock()
    private var joinSecret: String?
    private var leases: [ObjectIdentifier: (lease: JoinLease, expires: Date)] = [:]

    /// Opens the join secret for at most `lifetime` (10 minutes by default), keeping the current one if it's open.
    @discardableResult
    func openJoin(lifetime: TimeInterval = BrowserAccess.lifetime) -> JoinLease {
        let lease = JoinLease()
        var secretBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, secretBytes.count, &secretBytes)
        lock.withLock {
            pruneLeases()
            if joinSecret == nil { joinSecret = Data(secretBytes).base64URL }
            leases[ObjectIdentifier(lease)] = (lease, Date().addingTimeInterval(lifetime))
        }
        return lease
    }

    /// Ends one lease; the secret closes once no lease is left.
    func closeJoin(_ lease: JoinLease?) {
        guard let lease else { return }
        lock.withLock {
            leases[ObjectIdentifier(lease)] = nil
            pruneLeases()
        }
    }

    /// The open join secret, or nil once every lease has ended.
    var secret: String? {
        lock.withLock {
            pruneLeases()
            return joinSecret
        }
    }

    func isSecret(_ given: String?) -> Bool {
        guard let given, let current = secret else { return false }
        let a = Array(given.utf8), b = Array(current.utf8)
        return a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Under the lock: drops expired leases, and the secret with the last one.
    private func pruneLeases() {
        let now = Date()
        leases = leases.filter { $0.value.expires > now }
        if leases.isEmpty { joinSecret = nil }
    }
}

extension Data {
    /// Base64url without padding.
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var plain = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        plain += String(repeating: "=", count: (4 - plain.count % 4) % 4)
        self.init(base64Encoded: plain)
    }
}
