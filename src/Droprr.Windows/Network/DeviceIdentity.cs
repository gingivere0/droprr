using System;
using System.Linq;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace Droprr;

// This PC's stable device id and its self-signed TLS certificate (docs/PROTOCOL.md, "Device identity"). Both are
// made once and kept in settings.json; the certificate, private key included, is stored encrypted with DPAPI
// like the tokens.
static class DeviceIdentity
{
    static string? _loadedFrom;
    static X509Certificate2? _certificate;

    // 16 random bytes, base32, lowercase, without padding.
    public static string NewId()
    {
        const string alphabet = "abcdefghijklmnopqrstuvwxyz234567";
        var bytes = RandomNumberGenerator.GetBytes(16);
        var text = new StringBuilder();
        int buffer = 0, bits = 0;
        foreach (var b in bytes)
        {
            buffer = (buffer << 8) | b;
            bits += 8;
            while (bits >= 5)
            {
                text.Append(alphabet[(buffer >> (bits - 5)) & 31]);
                bits -= 5;
            }
        }
        if (bits > 0)
            text.Append(alphabet[(buffer << (5 - bits)) & 31]);
        return text.ToString();
    }

    // An ECDSA P-256 certificate for "CN=Droprr <id>", valid for 20 years, as base64 PKCS #12.
    public static string NewCertificate(string id)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest($"CN=Droprr {id}", key, HashAlgorithmName.SHA256);
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(20));
        return Convert.ToBase64String(certificate.Export(X509ContentType.Pkcs12));
    }

    static string? _fingerprintOf;
    static string _fingerprint = "";

    // The certificate in settings, with its private key, for the HTTPS listener. Loaded once (and again only if
    // settings hold a different one). Windows' TLS stack can't use an in-memory-only key, so the key goes in a
    // temporary container, which is deleted when the certificate is disposed: on reload and at exit.
    public static X509Certificate2 Certificate(AppSettings settings)
    {
        if (_certificate is null || _loadedFrom != settings.Identity)
        {
            if (_certificate is null)
                AppDomain.CurrentDomain.ProcessExit += (_, _) => _certificate?.Dispose();
            _certificate?.Dispose();
            _certificate = X509CertificateLoader.LoadPkcs12(Convert.FromBase64String(settings.Identity), null, X509KeyStorageFlags.UserKeySet);
            _loadedFrom = settings.Identity;
        }
        return _certificate;
    }

    // This PC's fingerprint, from an in-memory copy of the certificate (no key container needed).
    public static string Fingerprint(AppSettings settings)
    {
        if (_fingerprintOf != settings.Identity)
        {
            using var certificate = X509CertificateLoader.LoadPkcs12(Convert.FromBase64String(settings.Identity), null, X509KeyStorageFlags.EphemeralKeySet);
            _fingerprint = Fingerprint(certificate);
            _fingerprintOf = settings.Identity;
        }
        return _fingerprint;
    }

    // SHA-256 of the certificate's DER encoding, as 64 lowercase hex characters.
    public static string Fingerprint(X509Certificate certificate) =>
        Convert.ToHexStringLower(SHA256.HashData(certificate.GetRawCertData()));

    // The six-digit code both screens show during LAN pairing: SHA-256 of "fpLow:fpHigh:nonceR:nonceS" (the two
    // fingerprints sorted, then the requester's and the receiver's nonces, all lowercase hex), first 4 bytes
    // big-endian, modulo 1,000,000, zero-padded. The requester commits to its nonce before it sees the receiver's,
    // so nobody in the middle can pick certificates or nonces that make two different codes match.
    public static string PairingCode(string fingerprintA, string fingerprintB, string requesterNonce, string receiverNonce)
    {
        var sorted = new[] { fingerprintA.ToLowerInvariant(), fingerprintB.ToLowerInvariant() }.Order(StringComparer.Ordinal);
        var input = string.Join(":", sorted.Append(requesterNonce.ToLowerInvariant()).Append(receiverNonce.ToLowerInvariant()));
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(input));
        var value = ((uint)hash[0] << 24) | ((uint)hash[1] << 16) | ((uint)hash[2] << 8) | hash[3];
        return (value % 1_000_000).ToString("D6");
    }

    // 32 random bytes as lowercase hex: a pairing nonce.
    public static string NewNonce() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));

    // The commitment to a nonce: SHA-256 of its 32 raw bytes, as lowercase hex.
    public static string Commit(string nonce) => Convert.ToHexStringLower(SHA256.HashData(Convert.FromHexString(nonce)));
}
