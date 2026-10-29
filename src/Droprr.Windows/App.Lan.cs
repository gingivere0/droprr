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

    void StartLocalNetwork(ReceiverServer receiver)
    {
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
        NearbyChanged?.Invoke();
    }

    // Devices found nearby that aren't paired with this PC yet.
    internal System.Collections.Generic.IReadOnlyList<LanDevice> UnpairedNearby() =>
        LanDiscovery.Devices.Where(d => !Settings.Peers.Any(p => p.Id == d.Id)).ToList();

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
        var existed = Settings.Peers.Any(p => p.Id == device.Id);
        // Accept the new token before asking, since the device may call back right away.
        Settings = SettingsStore.Update(s =>
        {
            var peer = s.Peers.Find(p => p.Id == device.Id) ?? s.FindPeer(device.Name);
            if (peer is null)
            {
                peer = new Peer { Name = device.Name, Platform = device.Platform };
                s.Peers.Add(peer);
            }
            peer.Id = device.Id;
            peer.AcceptToken = minted;
        });
        var name = Settings.Peers.Find(p => p.Id == device.Id)!.Name;

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
