using System;
using System.Collections.Generic;
using System.Linq;

namespace Droprr;

// One device can end up paired twice: once over Tailscale (by host and token) and again over Wi-Fi (by device id
// and certificate). These records are the same device when they share a device id or a pinned fingerprint, and
// don't have two different ids or two different pins; they're merged into the older one. A shared host alone isn't
// enough: a host comes from the device itself, so it would let one device claim another's record. The Mac and
// iPhone apps use the same rule (DroprrSettings.mergeDuplicates).
public static class PeerMerge
{
    // Whether two peers are the same device.
    public static bool SameDevice(Peer a, Peer b)
    {
        if (a.Fingerprint.Length > 0 && b.Fingerprint.Length > 0 && !a.Fingerprint.Equals(b.Fingerprint, StringComparison.OrdinalIgnoreCase))
            return false;
        if (a.Id.Length > 0 && b.Id.Length > 0 && a.Id != b.Id)
            return false;
        return a.HasIdentity(b.Id, b.Fingerprint);
    }

    // Pairs (older, newer) of peers that are the same device, by their order in settings (older first).
    public static IReadOnlyList<(Peer Older, Peer Newer)> Duplicates(PeerList peers)
    {
        var found = new List<(Peer, Peer)>();
        var merged = new HashSet<Peer>();
        for (var i = 0; i < peers.Count; i++)
        {
            if (merged.Contains(peers[i]))
                continue;
            for (var j = i + 1; j < peers.Count; j++)
            {
                if (!merged.Contains(peers[j]) && SameDevice(peers[i], peers[j]))
                {
                    found.Add((peers[i], peers[j]));
                    merged.Add(peers[j]);
                }
            }
        }
        return found;
    }

    // Folds `newer` into `older` and removes it. The older record keeps its name (the one the person chose) and
    // Tailscale host; the newer one, from the latest pairing, supplies its identity, Wi-Fi addresses, and (unless
    // `keepOlderTokens`, when only the older token was found to work) its tokens.
    public static void Merge(PeerList peers, Peer older, Peer newer, bool keepOlderTokens)
    {
        if (newer.Id.Length > 0)
            older.Id = newer.Id;
        // A pin is only ever added, never moved (SameDevice never pairs two different pins).
        if (older.Fingerprint.Length == 0)
            older.Fingerprint = newer.Fingerprint;
        if (newer.TlsPort > 0)
            older.TlsPort = newer.TlsPort;
        older.Lan = newer.Lan.Concat(older.Lan).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (older.Host.Length == 0)
            older.Host = newer.Host;
        if (older.Platform == DevicePlatform.Unknown)
            older.Platform = newer.Platform;
        if (newer.LastPath != SendPath.None)
            older.LastPath = newer.LastPath;
        if (!keepOlderTokens || older.Token.Length == 0)
        {
            if (newer.Token.Length > 0)
                older.Token = newer.Token;
            if (newer.AcceptToken.Length > 0)
                older.AcceptToken = newer.AcceptToken;
        }
        peers.Remove(newer);
    }

    // What the merged record would look like when calling the device with `token`, to test which token works
    // before merging.
    public static Peer Preview(Peer older, Peer newer, string token) => new()
    {
        Name = older.Name, Host = older.Host.Length > 0 ? older.Host : newer.Host, Port = older.Port,
        Platform = older.Platform != DevicePlatform.Unknown ? older.Platform : newer.Platform,
        Id = newer.Id.Length > 0 ? newer.Id : older.Id,
        Fingerprint = newer.Fingerprint.Length > 0 ? newer.Fingerprint : older.Fingerprint,
        TlsPort = newer.TlsPort, Lan = newer.Lan, Token = token,
    };
}
