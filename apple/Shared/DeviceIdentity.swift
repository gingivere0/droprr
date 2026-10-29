import CryptoKit
import Foundation
import Network
import Security

/// This device's TLS identity for Wi-Fi connections: a P-256 key and a self-signed certificate,
/// made once and kept with the tokens. Other devices pin the certificate's SHA-256 fingerprint
/// (shared when pairing), so no certificate authority is involved.
final class DeviceIdentity {
    let certificate: SecCertificate
    let privateKey: SecKey
    /// Lowercase hex SHA-256 of the certificate's DER bytes.
    let fingerprint: String

    private init(certificate: SecCertificate, privateKey: SecKey) {
        self.certificate = certificate
        self.privateKey = privateKey
        fingerprint = Self.fingerprint(of: SecCertificateCopyData(certificate) as Data)
    }

    /// The identity for a TLS listener.
    var secIdentity: SecIdentity? {
        SecIdentityCreate(nil, certificate, privateKey)?.takeRetainedValue()
    }

    var tlsIdentity: sec_identity_t? {
        secIdentity.flatMap { sec_identity_create($0) }
    }

    static func fingerprint(of der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Loads this device's identity, creating and saving one the first time.
    static func load(from store: TokenStore, name: String = "Droprr") -> DeviceIdentity? {
        if let keyText = store.get("tls.key"), let certText = store.get("tls.cert"),
           let keyData = Data(base64Encoded: keyText), let certData = Data(base64Encoded: certText),
           let key = SecKeyCreateWithData(keyData as CFData, [
               kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
               kSecAttrKeyClass: kSecAttrKeyClassPrivate,
           ] as CFDictionary, nil),
           let cert = SecCertificateCreateWithData(nil, certData as CFData) {
            return DeviceIdentity(certificate: cert, privateKey: key)
        }
        guard let key = SecKeyCreateRandomKey([
                  kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                  kSecAttrKeySizeInBits: 256,
              ] as CFDictionary, nil),
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let der = SelfSignedCertificate.make(key: key, commonName: name),
              let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        store.set(keyData.base64EncodedString(), for: "tls.key")
        store.set(der.base64EncodedString(), for: "tls.cert")
        return DeviceIdentity(certificate: cert, privateKey: key)
    }
}

/// Builds a key into an identity without adding anything to the keychain. Public on neither
/// platform's headers but exported by Security.framework on both; fine for an app installed directly.
@_silgen_name("SecIdentityCreate")
private func SecIdentityCreate(_ allocator: CFAllocator?, _ certificate: SecCertificate, _ privateKey: SecKey) -> Unmanaged<SecIdentity>?

/// A minimal X.509 v1 certificate (ECDSA P-256 with SHA-256), DER encoded by hand.
enum SelfSignedCertificate {
    static func make(key: SecKey, commonName: String, years: Int = 20) -> Data? {
        guard let publicKey = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
        let ecdsaWithSHA256 = sequence(oid([1, 2, 840, 10045, 4, 3, 2]))
        let name = sequence(set(sequence(oid([2, 5, 4, 3]) + tlv(0x0C, Data(commonName.utf8)))))
        let now = Date()
        let validity = sequence(time(now.addingTimeInterval(-86_400)) + time(now.addingTimeInterval(Double(years) * 365.25 * 86_400)))
        let spki = sequence(sequence(oid([1, 2, 840, 10045, 2, 1]) + oid([1, 2, 840, 10045, 3, 1, 7])) + bitString(point))
        var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        serial[0] &= 0x7F   // positive
        let tbs = sequence(tlv(0x02, serial) + ecdsaWithSHA256 + name + validity + name + spki)
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, nil) as Data? else { return nil }
        return sequence(tbs + ecdsaWithSHA256 + bitString(signature))
    }

    private static func tlv(_ tag: UInt8, _ value: Data) -> Data {
        var out = Data([tag])
        let n = value.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var length = withUnsafeBytes(of: UInt32(n).bigEndian) { Data($0) }
            while length.first == 0 { length.removeFirst() }
            out.append(0x80 | UInt8(length.count))
            out.append(length)
        }
        return out + value
    }

    private static func sequence(_ content: Data) -> Data { tlv(0x30, content) }
    private static func set(_ content: Data) -> Data { tlv(0x31, content) }
    private static func bitString(_ bytes: Data) -> Data { tlv(0x03, Data([0]) + bytes) }

    private static func oid(_ parts: [UInt]) -> Data {
        var body = Data([UInt8(parts[0] * 40 + parts[1])])
        for var part in parts.dropFirst(2) {
            var bytes = [UInt8(part & 0x7F)]
            part >>= 7
            while part > 0 {
                bytes.insert(UInt8(part & 0x7F) | 0x80, at: 0)
                part >>= 7
            }
            body.append(contentsOf: bytes)
        }
        return tlv(0x06, body)
    }

    /// UTCTime through 2049, GeneralizedTime after (RFC 5280).
    private static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
        if year < 2050 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Data(formatter.string(from: date).utf8))
        }
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(0x18, Data(formatter.string(from: date).utf8))
    }
}

/// URLSession delegate that trusts a server only if its certificate matches a pinned fingerprint.
final class PinnedTrust: NSObject, URLSessionDelegate {
    let fingerprint: String
    /// Set when the server presented a different certificate (as opposed to not answering).
    private(set) var mismatch = false

    init(fingerprint: String) {
        self.fingerprint = fingerprint.lowercased()
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              DeviceIdentity.fingerprint(of: SecCertificateCopyData(leaf) as Data) == fingerprint else {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { mismatch = true }
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
