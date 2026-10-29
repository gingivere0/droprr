using System;
using System.Collections.Generic;
using System.Linq;

namespace Droprr;

// One device can end up paired twice: once over Tailscale (by host and token) and again over Wi-Fi (by device id
// and certificate). These records are the same device when they share a device id or a pinned fingerprint, and
// don't have two different pins; they're merged into the older one. A shared host alone isn't enough: a host
// comes from the device itself, so it would let one device claim another's record.
static class PeerMerge
{
    // Whether two peers are the same device.
    public static bool SameDevice(Peer a, Peer b) =>
        ((a.Id.Length > 0 && a.Id == b.Id)
         || (a.Fingerprint.Length > 0 && a.Fingerprint.Equals(b.Fingerprint, StringComparison.OrdinalIgnoreCase)))
        && !(a.Fingerprint.Length > 0 && b.Fingerprint.Length > 0 && !a.Fingerprint.Equals(b.Fingerprint, StringComparison.OrdinalIgnoreCase));

    // Pairs (older, newer) of peers that are the same device, by their order in settings (older first).
    public static IReadOnlyList<(Peer Older, Peer Newer)> Duplicates(AppSettings settings)
    {
        var found = new List<(Peer, Peer)>();
        var peers = settings.Peers;
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
    public static void Merge(AppSettings settings, Peer older, Peer newer, bool keepOlderTokens)
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
        if (older.Platform.Length == 0)
            older.Platform = newer.Platform;
        if (newer.LastPath.Length > 0)
            older.LastPath = newer.LastPath;
        if (!keepOlderTokens || older.Token.Length == 0)
        {
            if (newer.Token.Length > 0)
                older.Token = newer.Token;
            if (newer.AcceptToken.Length > 0)
                older.AcceptToken = newer.AcceptToken;
        }
        settings.Peers.Remove(newer);
    }
}
