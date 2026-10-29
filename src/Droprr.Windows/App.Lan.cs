using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Droprr;

// The local network side of the app (docs/PROTOCOL.md, "Local network (LAN) transport"): discovery, LAN
// pairing in both directions, keeping peers' LAN addresses current, and the firewall rule.
public partial class App
{
    // Whether HTTPS for the local network is listening (the setting is on and the firewall allows it).
    internal bool LanListening => _receiver?.LanListening == true;

    // Raised on the UI thread when the devices found nearby change.
    internal event Action? NearbyChanged;

    bool _discoveryHooked;
    string _advertisedOn = "";

    // After a network change that didn't need the receiver restarted: re-advertise if this PC's Wi-Fi or
    // Ethernet addresses changed.
    void RefreshLocalNetwork(ReceiverServer receiver)
    {
        if (CurrentLanAddresses() != _advertisedOn)
            StartLocalNetwork(receiver);
    }

    static string CurrentLanAddresses() => string.Join(",", LanNetwork.LocalAddresses().Select(a => $"{a.Address}%{a.InterfaceIndex}"));

    void StartLocalNetwork(ReceiverServer receiver)
    {
        _advertisedOn = CurrentLanAddresses();
        Sender.LocalNetworkEnabled = Settings.LocalNetwork;
        if (!_discoveryHooked)
        {
            LanDiscovery.Changed += () => Dispatcher.BeginInvoke(OnNearbyChanged);
            _discoveryHooked = true;
        }
        if (Settings.LocalNetwork)
            LanDiscovery.Start(Settings, receiver.TlsPort, advertise: receiver.LanListening);
        else
            LanDiscovery.Stop();
        NearbyChanged?.Invoke();
    }

    // A paired device seen at new addresses (with its pinned fingerprint): remember them.
    void OnNearbyChanged()
    {
        var updates = LanDiscovery.Devices
            .Select(d => (Device: d, Peer: Settings.Peers.Find(p => p.Id == d.Id && p.Fingerprint == d.Fingerprint)))
            .Where(x => x.Peer is not null)
            .Select(x => (x.Peer!.Name, Lan: x.Device.Endpoints.Select(e => e.ToString()).ToList()))
            .Where(x => !x.Lan.SequenceEqual(Settings.FindPeer(x.Name)!.Lan))
            .ToList();
        if (updates.Count > 0)
        {
            Settings = SettingsStore.Update(s =>
            {
                foreach (var (name, lan) in updates)
                    if (s.FindPeer(name) is { } peer)
                        peer.Lan = lan;
            });
        }
        // A nearby device this PC doesn't recognize may be one paired over Tailscale whose id isn't known yet.
        if (LanDiscovery.Devices.Any(d => !Settings.Peers.Any(p => p.Id == d.Id))
            && Settings.Peers.Any(p => !p.IsPhone && p.Id.Length == 0 && p.Host.Length > 0)
            && DateTime.UtcNow - _lastLearned > TimeSpan.FromMinutes(2))
            _ = LearnAndMergePeersAsync();
        NearbyChanged?.Invoke();
    }

    // Devices found nearby: unpaired ones (which can be paired) and ones already paired under another name
    // ("Paired as MacBook"). A device paired under the same name isn't listed.
    internal System.Collections.Generic.IReadOnlyList<NearbyDevice> NearbyDevices()
    {
        var list = new System.Collections.Generic.List<NearbyDevice>();
        foreach (var device in LanDiscovery.Devices)
        {
            var paired = Settings.Peers.Find(p => p.Id == device.Id
                || (p.Fingerprint.Length > 0 && p.Fingerprint.Equals(device.Fingerprint, StringComparison.OrdinalIgnoreCase)));
            if (paired is null)
                list.Add(new NearbyDevice(device, null));
            else if (!paired.Name.Equals(device.Name, StringComparison.OrdinalIgnoreCase))
                list.Add(new NearbyDevice(device, paired.Name));
        }
        return list;
    }

    bool _learning;
    DateTime _lastLearned;

    // Learns each Tailscale-paired computer's platform, device id, and certificate over Tailscale (which
    // authenticates it, so the certificate can be pinned), then merges any two records that turn out to be the
    // same device: one paired over Tailscale and one over Wi-Fi. When their tokens differ, the one that works
    // is kept (the newer pairing's if both or neither do). Each merge is logged.
    internal async Task LearnAndMergePeersAsync()
    {
        if (_learning)
            return;
        _learning = true;
        _lastLearned = DateTime.UtcNow;
        try
        {
            foreach (var peer in Settings.Peers.Where(p => !p.IsPhone && p.Host.Length > 0 && p.Token.Length > 0
                         && (p.Platform.Length == 0 || p.Fingerprint.Length == 0 || p.Id.Length == 0)).ToList())
            {
                if (await Sender.PingAsync(peer, peer.Token) is not { } info)
                    continue;
                Settings = SettingsStore.Update(s =>
                {
                    if (s.FindPeer(peer.Name) is not { } saved)
                        return;
                    if (!string.IsNullOrEmpty(info.Platform))
                        saved.Platform = info.Platform;
                    if (saved.Id.Length == 0 && info.Id is { Length: > 0 } id)
                        saved.Id = id;
                    if (saved.Fingerprint.Length == 0 && info.Fingerprint is { Length: 64 } fp)
                    {
                        saved.Fingerprint = fp;
                        if (info.TlsPort is { } tlsPort)
                            saved.TlsPort = tlsPort;
                    }
                });
            }

            var merged = false;
            // At most one merge per peer; stops if a merge didn't take (for example, settings changed meanwhile).
            for (var round = Settings.Peers.Count; round > 0 && PeerMerge.Duplicates(Settings).FirstOrDefault() is ({ } older, { } newer); round--)
            {
                var keepOlderTokens = false;
                if (older.Token.Length > 0 && newer.Token.Length > 0 && older.Token != newer.Token)
                {
                    Peer Probe(string token) => new()
                    {
                        Name = older.Name, Host = older.Host.Length > 0 ? older.Host : newer.Host, Port = older.Port,
                        Platform = older.Platform.Length > 0 ? older.Platform : newer.Platform,
                        Id = newer.Id.Length > 0 ? newer.Id : older.Id,
                        Fingerprint = newer.Fingerprint.Length > 0 ? newer.Fingerprint : older.Fingerprint,
                        TlsPort = newer.TlsPort, Lan = newer.Lan, Token = token,
                    };
                    keepOlderTokens = !(await Sender.TestAsync(Probe(newer.Token))).Ok && (await Sender.TestAsync(Probe(older.Token))).Ok;
                }
                var (olderIndex, newerIndex) = (Settings.Peers.IndexOf(older), Settings.Peers.IndexOf(newer));
                Settings = SettingsStore.Update(s =>
                {
                    if (olderIndex < s.Peers.Count && newerIndex < s.Peers.Count && PeerMerge.SameDevice(s.Peers[olderIndex], s.Peers[newerIndex]))
                        PeerMerge.Merge(s, s.Peers[olderIndex], s.Peers[newerIndex], keepOlderTokens);
                });
                RequestLog.Note($"merged device \"{newer.Name}\" into \"{older.Name}\" (same device; kept {(keepOlderTokens ? "the older" : "the newer")} tokens)");
                merged = true;
            }
            if (merged)
                SettingsSaved?.Invoke();
            NearbyChanged?.Invoke();
        }
        finally
        {
            _learning = false;
        }
    }

    // Someone nearby asked to pair (POST /pair/request): ask the person here, showing the code.
    Task<bool> ConfirmLanPairAsync(LanPairPrompt prompt, CancellationToken cancel) =>
        Dispatcher.InvokeAsync(() => PairCodeWindow.AskAsync(prompt.Name, prompt.Code, cancel)).Task.Unwrap();

    // Pairs with a device found nearby: shows the code here while the person there confirms it.
    internal async Task PairOverLanAsync(LanDevice device)
    {
        string? fingerprint = null;
        System.Net.IPEndPoint? endpoint = null;
        foreach (var candidate in device.Endpoints.Where(LanDevice.IsUsable))
        {
            fingerprint = await Sender.ServerFingerprintAsync(candidate);
            if (fingerprint is not null)
            {
                endpoint = candidate;
                break;
            }
        }
        if (endpoint is null || fingerprint is null)
        {
            await AppTheme.ShowMessageAsync("Couldn't reach " + device.Name, "It may have left this network. Try again in a moment.");
            return;
        }
        // The certificate it presents must be the one it advertises.
        if (fingerprint != device.Fingerprint)
        {
            await AppTheme.ShowMessageAsync("Couldn't pair with " + device.Name, $"{device.Name}'s identity didn't match what it advertised, so Droprr didn't pair.");
            return;
        }

        var minted = SettingsStore.NewToken();
        // The same device may already be paired over Tailscale under another name: update that one.
        bool Matches(Peer p) => p.Id == device.Id || (p.Fingerprint.Length > 0 && p.Fingerprint == fingerprint);
        var existed = Settings.Peers.Any(Matches);
        // Accept the new token before asking, since the device may call back right away.
        Settings = SettingsStore.Update(s =>
        {
            var peer = s.Peers.Find(Matches) ?? s.FindPeer(device.Name);
            if (peer is null)
            {
                peer = new Peer { Name = device.Name, Platform = device.Platform };
                s.Peers.Add(peer);
            }
            peer.Id = device.Id;
            peer.AcceptToken = minted;
        });
        var name = Settings.Peers.Find(Matches)!.Name;

        var code = DeviceIdentity.PairingCode(fingerprint, DeviceIdentity.Fingerprint(Settings));
        using var cancel = new CancellationTokenSource();
        var waiting = PairCodeWindow.ShowWaiting(device.Name, code, cancel.Cancel);
        var host = PairWindow.MagicDnsName() ?? TailscaleNetwork.FindAddresses().FirstOrDefault()?.ToString();
        var (status, info) = await Sender.RequestLanPairAsync(endpoint, fingerprint,
            Sender.OwnPairFields(Settings, host, minted, LanListening), cancel.Token);
        waiting.Close();

        if (status == 200 && info is not null)
        {
            Settings = SettingsStore.Update(s =>
            {
                if (s.FindPeer(name) is not { } p)
                    return;
                p.Platform = device.Platform.Length > 0 ? device.Platform : p.Platform;
                p.Fingerprint = fingerprint;
                p.TlsPort = info.TlsPort ?? device.Port;
                p.Lan = info.Lan.Count > 0 ? info.Lan : device.Endpoints.Select(e => e.ToString()).ToList();
                p.Token = info.Token;
                if (p.Host.Length == 0 && !p.IsPhone && info.Host is { Length: > 0 } tailscaleHost)
                    p.Host = tailscaleHost;
            });
            SettingsSaved?.Invoke();
            var peer = Settings.FindPeer(name)!;
            _tray?.Notify($"{peer.Name} paired", "Each of you can now send to the other over Wi-Fi.");
            DevicePaired?.Invoke(peer);
            NearbyChanged?.Invoke();
            return;
        }

        // Not paired: drop the token offered, and the peer if this attempt added it.
        Settings = SettingsStore.Update(s =>
        {
            if (s.FindPeer(name) is not { } p)
                return;
            if (!existed)
                s.Peers.Remove(p);
            else
                p.AcceptToken = "";
        });
        SettingsSaved?.Invoke();
        if (cancel.IsCancellationRequested)
            return;
        var reason = status switch
        {
            403 => $"{device.Name} declined.",
            408 => $"Nobody confirmed on {device.Name} in time.",
            429 => $"{device.Name} is busy with another pairing request. Try again in a moment.",
            _ => $"Couldn't reach {device.Name}.",
        };
        await AppTheme.ShowMessageAsync("Not paired", reason);
    }

    internal void Notify(string title, string text) => _tray?.Notify(title, text);

    // Settings' "Allow Droprr on your private network": one UAC prompt, then start listening on the LAN.
    internal async Task<bool> AllowLocalNetworkAsync()
    {
        var ok = await LanFirewall.AllowAsync(LanNetwork.TlsPort(Settings.Port));
        if (ok)
            await StartReceiverAsync();
        return ok;
    }
}
