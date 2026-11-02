using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Droprr.Codes;

// The one code's short parts (docs/PROTOCOL.md, "The code" and "App details"), kept small so the QR code is too.
// Only the base class library, so the tests run anywhere .NET does.
public static class OneCode
{
    // The room and the DTLS key are cut to their first 22 base64url characters (132 bits).
    public const int ShortIdLength = 22;

    public const byte Format = 2;
    public const byte Windows = 1, MacOS = 2, Web = 3, Phone = 4;
    const byte HasFingerprint = 1, HasTailscale = 2, HasPort = 4;
    public const int DefaultPort = 53318;

    public static string Short(string id) => id.Length > ShortIdLength ? id[..ShortIdLength] : id;

    // A computer's app details: its platform, the first 16 bytes of its LAN certificate's fingerprint, its Tailscale
    // IPv4 address, its HTTP port when it isn't the default (HTTPS is that + 1), and its LAN IPv4 addresses. Name, id,
    // and MagicDNS name come from the /pair answer instead.
    public static string AppInfo(byte platform, string? fingerprintHex, IPAddress? tailscale, int httpPort,
        IEnumerable<IPAddress> lan)
    {
        var bytes = new List<byte> { Format, platform, 0 };
        byte flags = 0;
        if (fingerprintHex is { Length: >= 32 })
        {
            flags |= HasFingerprint;
            bytes.AddRange(Convert.FromHexString(fingerprintHex[..32]));
        }
        if (tailscale is { AddressFamily: AddressFamily.InterNetwork })
        {
            flags |= HasTailscale;
            bytes.AddRange(tailscale.GetAddressBytes());
        }
        if (httpPort != DefaultPort)
        {
            flags |= HasPort;
            bytes.Add((byte)(httpPort >> 8));
            bytes.Add((byte)httpPort);
        }
        bytes[2] = flags;
        foreach (var address in lan.Where(a => a.AddressFamily == AddressFamily.InterNetwork).Take(4))
            bytes.AddRange(address.GetAddressBytes());
        return Base64Url(bytes.ToArray());
    }

    // A browser's or iPhone's app details: its platform and its name in UTF-8, at most 32 bytes.
    public static string NamedAppInfo(byte platform, string name)
    {
        var bytes = new List<byte> { Format, platform, 0 };
        var encoded = Encoding.UTF8.GetBytes(name);
        var end = Math.Min(encoded.Length, 32);
        while (end < encoded.Length && (encoded[end] & 0xC0) == 0x80)
            end--;
        bytes.AddRange(encoded[..end]);
        return Base64Url(bytes.ToArray());
    }

    static string Base64Url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
