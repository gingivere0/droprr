using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace Droprr;

// The join secret for Browser access over the internet (docs/PROTOCOL.md, "The code"): 16 random bytes, base64url,
// in the one code's link. Never saved or logged.
sealed class BrowserAccess
{
    static readonly TimeSpan Lifetime = TimeSpan.FromMinutes(10);

    readonly object _gate = new();

    // It works for any number of browsers, and stays open while anyone holds a lease on it: the Pair window while
    // it's open, and a connected browser's Show QR code for 10 minutes. Each lease ends on its own,
    // so closing the window never cuts off a code a browser is still showing, and opening it never replaces one.
    string? _secret;
    readonly Dictionary<JoinLease, DateTime> _leases = new();

    // A lease on the join secret: the secret opens (or stays the same, if it's open already) until the lease is
    // closed or its lifetime passes.
    public sealed class JoinLease
    {
        internal JoinLease() { }
    }

    public string? Secret
    {
        get
        {
            lock (_gate)
            {
                PruneLeases();
                return _secret;
            }
        }
    }

    public bool IsSecret(string? given)
    {
        var secret = Secret;
        return secret is not null && given is not null
            && CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(given), Encoding.ASCII.GetBytes(secret));
    }

    // Opens the join secret for at most `lifetime` (10 minutes by default), keeping the current one if it's open.
    public JoinLease OpenJoin(TimeSpan? lifetime = null)
    {
        var lease = new JoinLease();
        lock (_gate)
        {
            PruneLeases();
            _secret ??= Convert.ToBase64String(RandomNumberGenerator.GetBytes(16)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
            _leases[lease] = DateTime.UtcNow + (lifetime ?? Lifetime);
        }
        return lease;
    }

    // Ends one lease; the secret closes once no lease is left.
    public void CloseJoin(JoinLease? lease)
    {
        if (lease is null)
            return;
        lock (_gate)
        {
            _leases.Remove(lease);
            PruneLeases();
        }
    }

    // Under _gate: drops expired leases, and the secret with the last one.
    void PruneLeases()
    {
        var now = DateTime.UtcNow;
        foreach (var expired in _leases.Where(l => l.Value <= now).Select(l => l.Key).ToList())
            _leases.Remove(expired);
        if (_leases.Count == 0)
            _secret = null;
    }
}
