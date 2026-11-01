using System;
using System.Collections.Generic;
using System.Linq;

namespace Droprr;

// The rules for adding and updating peers, in one place: every pairing path (the pairing QR, the one code, LAN
// pairing in both directions, pairing with a computer over Tailscale, a phone checking in, a browser connecting)
// changes the saved peers only through these. Callers load and save settings around them (SettingsStore.Update).
public static class PeerBook
{
    // Phones added just by checking in (GET /inbox?for=) stop being added past this many.
    const int MaxCheckedInPhones = 50;

    // Adds the peer or updates an existing one, as `request.Target` says (see PairTarget), and returns it.
    // A host this PC already has (often a MagicDNS name the user typed) is kept for computers; phones never have one.
    public static Peer ApplyPairing(this PeerList peers, PairRequest request)
    {
        var existing = request.Target switch
        {
            PairTarget.Update update => peers.FindByName(update.Peer),
            PairTarget.Repair repair => peers.FindByName(repair.Peer),
            _ => null,
        };
        // An existing peer renamed or removed meanwhile is matched like the main token's pairing.
        var peer = existing
            ?? (request.Target is PairTarget.New ? null
                : (request.Id is { } id ? peers.Find(p => p.Id == id) : null) ?? peers.FindByName(request.Name));
        if (peer is null)
        {
            peer = new Peer { Name = peers.UniqueName(request.Name) };
            peers.Add(peer);
        }
        if (existing is null || peer.Platform == DevicePlatform.Unknown)
            peer.Platform = request.Platform;
        if (peer.IsPhone)
            peer.Host = "";
        else if (peer.Host.Length == 0 && request.Host is not null)
            peer.Host = request.Host;
        if (request.Port is { } port)
            peer.Port = port;
        // Pairing again replaces the device token, so the previous one stops working.
        if (request.AcceptToken is not null)
            peer.AcceptToken = request.AcceptToken;
        // The token this PC sends to the peer: from the caller. A phone without one (protocol 1) can't be
        // called, so items for it are queued.
        if (request.SendToken is not null)
            peer.Token = request.SendToken;
        else if (peer.IsPhone)
            peer.Token = "";
        // Local network identity and addresses (protocol 2). The fingerprint comes from an authenticated /pair or a
        // confirmed pairing, so it's pinned. A device token's /pair (Update) can only fill them in (a protocol 1
        // pairing upgrading), never replace them, and never with another peer's.
        var mayReplace = existing is null || request.Target is PairTarget.Repair;
        if (request.Id is not null && (mayReplace || peer.Id.Length == 0) && !peers.IdentityTakenByOther(peer, request.Id, null))
            peer.Id = request.Id;
        if (request.Fingerprint is not null && (mayReplace || peer.Fingerprint.Length == 0)
            && !peers.IdentityTakenByOther(peer, null, request.Fingerprint))
            peer.Fingerprint = request.Fingerprint;
        if (request.TlsPort is { } tlsPort)
            peer.TlsPort = tlsPort;
        if (request.Lan is { } lan)
            peer.Lan = lan.ToList();
        return peer;
    }

    // The peer a device pairing again is, if it's paired already: the one with its device id or certificate, of the
    // same kind. A record of another kind (a browser, or a phone versus a computer) is never reused; that device is
    // added as a new peer instead.
    public static Peer? FindRepairable(this PeerList peers, string? id, string? fingerprint, DevicePlatform platform) =>
        peers.FindByIdentity(id, fingerprint) is { } existing && !existing.IsBrowser
        && existing.IsPhone == (platform == DevicePlatform.IOS)
            ? existing
            : null;

    // A phone that checks its inbox under an unknown name (it never called POST /pair) becomes an iPhone peer, so
    // the Send window offers it. A known name is never changed this way (a computer isn't turned into a phone).
    // Returns the new peer, or null if none was added.
    public static Peer? AddCheckedInPhone(this PeerList peers, string name) => peers.CanAddCheckedInPhone(name)
        ? peers.ApplyPairing(new PairRequest(new PairTarget.Match(), name, DevicePlatform.IOS, null, null, null, null))
        : null;

    public static bool CanAddCheckedInPhone(this PeerList peers, string name) =>
        name.Length > 0 && peers.FindByName(name) is null && peers.Count(p => p.IsPhone) < MaxCheckedInPhones;

    // A browser on the website introduced itself with the open code: the browser peer with its id, or a new one,
    // now accepting `token`.
    public static Peer ConnectBrowser(this PeerList peers, string id, string name, string token)
    {
        var peer = peers.FindBrowser(id);
        if (peer is null)
        {
            peer = new Peer { Name = peers.UniqueName(name.Length > 0 ? name : "Browser"), Platform = DevicePlatform.Web, Id = id };
            peers.Add(peer);
        }
        peer.AcceptToken = token;
        return peer;
    }

    public static Peer? FindBrowser(this PeerList peers, string id) => peers.Find(p => p.IsBrowser && p.Id == id);

    // A browser disconnected itself: its record goes (its token with it).
    public static void RemoveBrowser(this PeerList peers, string name) =>
        peers.RemoveAll(p => p.IsBrowser && p.Name.Equals(name, StringComparison.OrdinalIgnoreCase));

    // This PC paired with a computer over Tailscale (POST /pair with a token the person entered): from now on each
    // uses the token the other minted. Tailscale authenticates the device, so its id and certificate are pinned,
    // unless another peer already has that identity.
    public static void ApplyTailscalePairing(this PeerList peers, Peer peer, string minted, PairInfo returned)
    {
        peer.AcceptToken = minted;
        peer.Token = returned.Token;
        var id = returned.Id is { Length: > 0 } rid ? rid : null;
        var fingerprint = returned.Fingerprint is { Length: 64 } rfp ? rfp : null;
        if (peers.IdentityTakenByOther(peer, id, fingerprint))
            return;
        if (id is not null)
            peer.Id = id;
        if (fingerprint is not null)
            peer.Fingerprint = fingerprint;
        if (returned.TlsPort is { } tlsPort)
            peer.TlsPort = tlsPort;
        peer.Lan = returned.Lan;
    }

    // This PC paired with a device found nearby (it confirmed the code there). The same device may already be
    // paired over Tailscale under another name, matched by its id or pin (never by name): that one is updated.
    // Returns the saved peer.
    public static Peer ApplyLanPairing(this PeerList peers, LanPairing pairing, PairInfo info)
    {
        var peer = peers.FindByIdentity(pairing.Id, pairing.Fingerprint);
        if (peer is null)
        {
            peer = new Peer { Name = peers.UniqueName(pairing.Name), Platform = pairing.Platform };
            peers.Add(peer);
        }
        peer.Id = pairing.Id;
        peer.AcceptToken = pairing.Minted;
        if (pairing.Platform != DevicePlatform.Unknown)
            peer.Platform = pairing.Platform;
        peer.Fingerprint = pairing.Fingerprint;
        peer.TlsPort = info.TlsPort ?? pairing.Port;
        peer.Lan = info.Lan.Count > 0 ? info.Lan : pairing.SeenAt.ToList();
        peer.Token = info.Token;
        if (peer.Host.Length == 0 && !peer.IsPhone && info.Host is { Length: > 0 } tailscaleHost)
            peer.Host = tailscaleHost;
        return peer;
    }

    // What a computer's /ping over Tailscale said about it. Tailscale authenticates the device, so a certificate
    // is pinned when there's none yet; an id or pin is never replaced this way.
    public static void Learn(this Peer peer, PingInfo info)
    {
        if (info.Platform != DevicePlatform.Unknown)
            peer.Platform = info.Platform;
        if (peer.Id.Length == 0 && info.Id is { Length: > 0 } id)
            peer.Id = id;
        if (peer.Fingerprint.Length == 0 && info.Fingerprint is { Length: 64 } fp)
        {
            peer.Fingerprint = fp;
            if (info.TlsPort is { } tlsPort)
                peer.TlsPort = tlsPort;
        }
    }

    // Computers whose platform, id, or certificate this PC hasn't learned yet, and that it can ask over Tailscale.
    public static IEnumerable<Peer> NeedingIdentity(this PeerList peers) => peers.Where(p => !p.IsPhone && p.Host.Length > 0
        && p.Token.Length > 0 && (p.Platform == DevicePlatform.Unknown || p.Fingerprint.Length == 0 || p.Id.Length == 0));
}

// A LAN pairing this PC started with a device found nearby: what discovery and the TLS handshake said about it
// (its id, platform, advertised HTTPS port, and addresses, and the fingerprint it presented), the name to save it
// under if it's new, and the device token this PC minted for it.
public sealed record LanPairing(string Id, string Name, DevicePlatform Platform, string Fingerprint, int Port,
    IReadOnlyList<string> SeenAt, string Minted);
