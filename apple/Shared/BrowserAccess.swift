import Foundation
import Security

/// The one-time access code for Browser access (docs/PROTOCOL.md, "Browser access"). It exists only while the
/// "Open in a browser" window is open, for at most 10 minutes, and works once; five wrong codes close it.
/// Never saved or logged.
final class BrowserAccess {
    enum Result { case accepted, wrong, closed }

    private static let lifetime: TimeInterval = 10 * 60
    private static let maxWrong = 5
    private static let length = 8
    /// Crockford base32: no I, L, O or U, so a code read off a screen can't be mistyped as another letter.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private let lock = NSLock()
    private var code: String?
    /// Browser access over the internet: the join secret in the website QR (16 bytes, base64url), valid for any
    /// number of browsers while the window is open, for at most 10 minutes.
    private var joinSecret: String?
    private var expires = Date.distantPast
    private var wrong = 0

    /// Called (on a server thread) when the code stops working: true once it was used, false after too many
    /// wrong tries.
    var onEnded: ((Bool) -> Void)?

    /// A fresh code, replacing any earlier one.
    func open() -> String {
        var bytes = [UInt8](repeating: 0, count: Self.length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let fresh = String(bytes.map { Self.alphabet[Int($0) % Self.alphabet.count] })
        var secretBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, secretBytes.count, &secretBytes)
        lock.withLock {
            code = fresh
            joinSecret = Data(secretBytes).base64URL
            expires = Date().addingTimeInterval(Self.lifetime)
            wrong = 0
        }
        return fresh
    }

    /// Opens only the join secret (the one code in Pair a phone), without a typed code.
    func openJoin() {
        var secretBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, secretBytes.count, &secretBytes)
        lock.withLock {
            code = nil
            joinSecret = Data(secretBytes).base64URL
            expires = Date().addingTimeInterval(Self.lifetime)
            wrong = 0
        }
    }

    func close() {
        lock.withLock {
            code = nil
            joinSecret = nil
        }
    }

    /// The open join secret, or nil once the window closed or 10 minutes passed.
    var secret: String? {
        lock.withLock { Date() < expires ? joinSecret : nil }
    }

    func isSecret(_ given: String?) -> Bool {
        guard let given, let current = secret else { return false }
        let a = Array(given.utf8), b = Array(current.utf8)
        return a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// "XXXX-XXXX", for showing and typing.
    static func format(_ code: String) -> String {
        code.count == length ? "\(code.prefix(4))-\(code.suffix(4))" : code
    }

    /// Upper case, without separators, with the letters Crockford reads as digits (O as 0, I and L as 1).
    private static func normalize(_ given: String) -> String {
        String(given.uppercased().map { $0 == "O" ? "0" : ($0 == "I" || $0 == "L") ? "1" : $0 }.filter { alphabet.contains($0) })
    }

    func use(_ given: String?) -> Result {
        let normalized = Self.normalize(given ?? "")
        var ended: Bool?
        let result: Result = lock.withLock {
            guard let current = code, Date() < expires else {
                code = nil
                return .closed
            }
            // Compare every character, so timing doesn't reveal how much of a guess was right.
            let a = Array(normalized.utf8), b = Array(current.utf8)
            let match = a.count == b.count && zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
            if match {
                code = nil
                ended = true
                return .accepted
            }
            wrong += 1
            if wrong >= Self.maxWrong {
                code = nil
                ended = false
            }
            return .wrong
        }
        if let ended { onEnded?(ended) }
        return result
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
