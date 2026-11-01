using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace Droprr;

// Which saved peer a pairing applies to.
public abstract record PairTarget
{
    PairTarget() { }

    // The main token (the pairing QR, a token typed in, a phone checking in): the peer with the same device id,
    // else the same name, else a new one.
    public sealed record Match : PairTarget;

    // A confirmed pairing with a device not paired before (a LAN code, the one code, or a browser): always a new peer.
    public sealed record New : PairTarget;

    // The peer whose device token authenticated the request. It can fill in its platform, id, and pinned
    // certificate, never change them, so one paired device can't make itself look like another.
    public sealed record Update(string Peer) : PairTarget;

    // The device pairing again with the person's consent (a confirmed code, or the open one code): the same peer,
    // with fresh tokens and its current id and certificate.
    public sealed record Repair(string Peer) : PairTarget;
}

// A device introducing itself to this PC. SendToken: the token the caller minted for this PC to use when calling
// it (computers, and phones that receive directly over the local network). AcceptToken: the device token this PC
// minted for the caller. Id, Fingerprint, TlsPort, and Lan: the caller's local network identity and addresses
// (protocol 2).
public sealed record PairRequest(PairTarget Target, string Name, DevicePlatform Platform, string? Host, int? Port,
    string? SendToken, string? AcceptToken, string? Id = null, string? Fingerprint = null, int? TlsPort = null,
    IReadOnlyList<string>? Lan = null);

// What a peer's /ping says about it.
public sealed record PingInfo(DevicePlatform Platform, string? Id, string? Fingerprint, int? TlsPort, string? Version = null)
{
    public static PingInfo Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        return new PingInfo(DevicePlatforms.FromWire(root.Text("platform")), root.Text("id"), root.Text("fp")?.ToLowerInvariant(),
            root.Int("tlsPort"), root.Text("version"));
    }
}

// A /pair or /pair/confirm response: the device token minted for this PC, and the peer's identity and addresses.
public sealed record PairInfo(string Token, string? Name, string? Id, string? Fingerprint, int? TlsPort, List<string> Lan, string? Host)
{
    // Null when the response has no token.
    public static PairInfo? Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.Text("token") is not { Length: > 0 } token)
            return null;
        var lan = root.TryGetProperty("lan", out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.String).Select(e => e.GetString()!).ToList()
            : new List<string>();
        return new PairInfo(token, root.Text("name"), root.Text("id"), root.Text("fp")?.ToLowerInvariant(), root.Int("tlsPort"), lan,
            root.Text("host"));
    }
}

static class JsonFields
{
    // A string property, or null if it's missing or not a string.
    public static string? Text(this JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    // An integer property, or null if it's missing or not a number.
    public static int? Int(this JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number
            && value.TryGetInt32(out var number)
            ? number
            : null;
}
