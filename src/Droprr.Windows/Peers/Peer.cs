using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace Droprr;

public static class Protocol
{
    // The plain HTTP port (docs/PROTOCOL.md); HTTPS for the local network is the next one.
    public const int DefaultPort = 53318;
}

// Another device this PC knows: a computer it sends to directly, or a phone or browser whose items are queued.
public sealed class Peer
{
    public string Name { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = Protocol.DefaultPort;

    // The token this PC sends when calling the peer: the device token it got from pairing, or one entered by
    // hand. Empty for phones (they can't be called) and for computers that aren't paired yet. Never this PC's
    // own main token.
    public string Token { get; set; } = "";

    // The device token this PC minted for the peer during POST /pair and accepts from it. Re-pairing
    // replaces it; removing the peer revokes it.
    public string AcceptToken { get; set; } = "";

    // From pairing or the peer's /ping. Unknown until one of them says.
    public DevicePlatform Platform { get; set; }

    // Local network (protocol 2): the peer's device id, its pinned certificate fingerprint, its HTTPS port, its
    // last known LAN addresses ("host:port"), and the path the last send took.
    public string Id { get; set; } = "";
    public string Fingerprint { get; set; } = "";
    public int TlsPort { get; set; }
    public List<string> Lan { get; set; } = new();
    public SendPath LastPath { get; set; }

    [JsonIgnore]
    public string PathLabel => LastPath.Label();

    // Phones can't listen, so sends to them are queued in the Outbox until they check in. Browsers (Browser
    // access) are queued the same way. Settings' iPhone switch sets it: on makes the peer an iPhone (a browser
    // stays a browser), off makes a phone or browser a device of unknown platform again.
    [JsonIgnore]
    public bool IsPhone
    {
        get => Platform is DevicePlatform.IOS or DevicePlatform.Web;
        set => Platform = value ? (IsBrowser ? Platform : DevicePlatform.IOS) : (IsPhone ? DevicePlatform.Unknown : Platform);
    }

    [JsonIgnore]
    public bool IsBrowser => Platform == DevicePlatform.Web;

    // Items in this peer's outbox, filled in by whoever shows the peer.
    [JsonIgnore]
    public int Waiting { get; set; }

    [JsonIgnore]
    public bool HasWaiting => Waiting > 0;

    [JsonIgnore]
    public string WaitingLabel => $"{Waiting} waiting";

    [JsonIgnore]
    public string ClearWaitingLabel => $"Clear {Waiting} item{(Waiting == 1 ? "" : "s")} waiting for {Name}";

    // Computers have an address, port, and token to edit in Settings; phones and browsers don't.
    [JsonIgnore]
    public bool HasDetails => !IsPhone;

    // A computer needs a token to be sent to; phones are queued instead.
    [JsonIgnore]
    public bool IsPaired => IsPhone || Token.Length > 0;

    [JsonIgnore]
    public string Note => !IsPaired ? "Missing Token"
        : !IsPhone ? Address
        : Waiting > 0 ? $"{(IsBrowser ? "Browser" : "iPhone")} · {Waiting} waiting"
        : IsBrowser ? "Browser"
        : "iPhone";

    // Where the device is: its Tailscale host, or for a device paired over Wi-Fi, its Wi-Fi address. Never an
    // empty host.
    [JsonIgnore]
    public string Address => Host.Length > 0 ? Host : LanAddress ?? "Wi-Fi";

    // The first LAN address without its port ("192.168.1.20" from "192.168.1.20:53319", "fe80::1" from
    // "[fe80::1]:53319"), or null.
    [JsonIgnore]
    public string? LanAddress => Lan.Count == 0 ? null
        : Lan[0].StartsWith('[') ? Lan[0][1..Math.Max(1, Lan[0].IndexOf(']'))]
        : Lan[0].LastIndexOf(':') is var colon and > 0 ? Lan[0][..colon]
        : Lan[0];

    // Whether this record carries the given device id or pinned fingerprint (either may be null).
    public bool HasIdentity(string? id, string? fingerprint) =>
        (id is { Length: > 0 } && Id == id)
        || (fingerprint is { Length: > 0 } && Fingerprint.Equals(fingerprint, StringComparison.OrdinalIgnoreCase));
}
