using System;
using System.Collections.Generic;

namespace Droprr;

// The devices this PC knows, as saved in settings.json. Names are unique (ignoring case and surrounding spaces);
// device ids and pinned fingerprints belong to at most one peer.
public sealed class PeerList : List<Peer>
{
    public PeerList() { }

    public PeerList(IEnumerable<Peer> peers) : base(peers) { }

    public Peer? FindByName(string name) =>
        Find(p => p.Name.Trim().Equals(name.Trim(), StringComparison.OrdinalIgnoreCase));

    // The peer with this device id or pinned fingerprint, if any.
    public Peer? FindByIdentity(string? id, string? fingerprint) => Find(p => p.HasIdentity(id, fingerprint));

    // Whether a peer other than `self` already has this device id or pinned fingerprint.
    public bool IdentityTakenByOther(Peer self, string? id, string? fingerprint) =>
        Exists(p => p != self && p.HasIdentity(id, fingerprint));

    // `name`, or "name (2)", "name (3)", and so on if a peer already has it.
    public string UniqueName(string name)
    {
        name = name.Trim();
        var unique = name;
        for (var i = 2; FindByName(unique) is not null; i++)
            unique = $"{name} ({i})";
        return unique;
    }
}
