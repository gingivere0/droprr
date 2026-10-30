using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace Droprr;

// A Droprr device found on the local network. Discovery only finds addresses; it never makes a device trusted.
public sealed record LanDevice(string Id, string Name, string Platform, string Fingerprint, int Port,
    IReadOnlyList<IPAddress> Addresses, DateTime Seen)
{
    public bool IsFresh => DateTime.UtcNow - Seen < LanDiscovery.FreshFor;

    // IPv4 first: link-local IPv6 needs a scope id that a URL can't carry well.
    public IEnumerable<IPEndPoint> Endpoints => Addresses
        .OrderBy(a => a.AddressFamily == AddressFamily.InterNetwork ? 0 : 1)
        .Select(a => new IPEndPoint(a, Port));

    // IPv4, or IPv6 without a scope id (a link-local scope can't go in a URL reliably).
    public static bool IsUsable(IPEndPoint endpoint) =>
        endpoint.AddressFamily == AddressFamily.InterNetwork || endpoint.Address.ScopeId == 0;
}

// Advertises this PC as _droprr._tcp and browses for other Droprr devices (docs/PROTOCOL.md, "Discovery").
static class LanDiscovery
{
    public static readonly TimeSpan FreshFor = TimeSpan.FromMinutes(2);
    static readonly TimeSpan BrowseEvery = TimeSpan.FromSeconds(20);

    static readonly ConcurrentDictionary<string, LanDevice> Found = new();
    static readonly List<Dnssd.Registration> Registrations = new();
    // What's advertised now (name, port, TXT, and addresses), so an unchanged advertisement is left alone.
    static string _advertised = "";
    // Bumped by every Start and Stop, so a delayed re-advertisement that's no longer wanted is dropped.
    static int _generation;
    static CancellationTokenSource? _browsing;
    static string _ownId = "";

    // Raised on a background thread after each browse that changed what's known.
    public static event Action? Changed;

    public static IReadOnlyList<LanDevice> Devices => Found.Values.Where(d => d.IsFresh).OrderBy(d => d.Name).ToList();

    // The peer as discovery last saw it, if recently and with the fingerprint pinned for it.
    public static LanDevice? Find(Peer peer) =>
        peer.Id.Length > 0 && Found.TryGetValue(peer.Id, out var device) && device.IsFresh
        && device.Fingerprint.Equals(peer.Fingerprint, StringComparison.OrdinalIgnoreCase)
            ? device
            : null;

    // (Re)starts browsing, and advertising when this PC is listening for HTTPS. An advertisement that hasn't changed
    // is kept as it is. A changed one is withdrawn, and the new one goes out a moment later: registering the same name
    // again before Windows has finished withdrawing the old one makes Windows rename it "Name (1)", and a renamed
    // registration can never be withdrawn (it stays on the network until Windows restarts).
    public static void Start(AppSettings settings, int tlsPort, bool advertise)
    {
        _browsing?.Cancel();
        _ownId = settings.DeviceId;
        var generation = Interlocked.Increment(ref _generation);
        var wanted = advertise ? AdvertisementKey(settings, tlsPort) : "";
        bool withdrawn;
        lock (Registrations)
        {
            withdrawn = wanted != _advertised && Registrations.Count > 0;
            if (wanted != _advertised)
                Withdraw();
        }
        if (advertise && wanted != _advertised)
        {
            _ = Task.Run(async () =>
            {
                if (withdrawn)
                    await Task.Delay(TimeSpan.FromSeconds(2));
                lock (Registrations)
                {
                    if (generation == Volatile.Read(ref _generation) && Registrations.Count == 0)
                        Advertise(settings, tlsPort, wanted);
                }
            });
        }
        var browsing = new CancellationTokenSource();
        _browsing = browsing;
        _ = Task.Run(() => BrowseLoopAsync(browsing.Token));
    }

    public static void Stop()
    {
        _browsing?.Cancel();
        _browsing = null;
        Interlocked.Increment(ref _generation);
        lock (Registrations)
            Withdraw();
    }

    // Callers hold the Registrations lock.
    static void Withdraw()
    {
        foreach (var registration in Registrations)
            registration.Dispose();
        Registrations.Clear();
        _advertised = "";
    }

    static string AdvertisementKey(AppSettings settings, int tlsPort) =>
        string.Join("|", settings.DeviceName, settings.DeviceId, tlsPort, DeviceIdentity.Fingerprint(settings),
            string.Join(",", LanNetwork.LocalAddresses().Select(a => $"{a.Address}%{a.InterfaceIndex}")));

    // One registration per private-network interface, carrying that interface's address. Callers hold the
    // Registrations lock.
    static void Advertise(AppSettings settings, int tlsPort, string key)
    {
        _advertised = key;
        var txt = new Dictionary<string, string>
        {
            ["v"] = "2",
            ["id"] = settings.DeviceId,
            ["name"] = settings.DeviceName,
            ["platform"] = "windows",
            ["port"] = tlsPort.ToString(),
            ["fp"] = DeviceIdentity.Fingerprint(settings),
        };
        foreach (var (address, index) in LanNetwork.LocalAddresses())
        {
            if (Dnssd.Register(settings.DeviceName, LanNetwork.ServiceType, tlsPort, txt, (uint)index, address) is { } registration)
                Registrations.Add(registration);
        }
        RequestLog.Note($"local network: advertising on {Registrations.Count} interface(s)");
    }

    static async Task BrowseLoopAsync(CancellationToken cancel)
    {
        var shown = new HashSet<string>();
        while (!cancel.IsCancellationRequested)
        {
            try
            {
                var changed = false;
                foreach (var instance in await Dnssd.BrowseAsync(LanNetwork.ServiceType, TimeSpan.FromSeconds(4), cancel))
                {
                    if (Parse(instance) is not { } device || device.Id == _ownId)
                        continue;
                    var known = Found.TryGetValue(device.Id, out var before)
                        && before.Fingerprint == device.Fingerprint && before.Name == device.Name
                        && before.Addresses.SequenceEqual(device.Addresses) && before.IsFresh;
                    // Windows keeps a registration whose process exited without withdrawing it (a crashed test run,
                    // or a renamed "Name (1)"), until it restarts. Only a device that answers on its port is listed.
                    if (!known && !await AnswersAsync(device, cancel))
                        continue;
                    Found[device.Id] = device;
                    changed |= !known;
                }
                // A device that left the network drops off the list once it's no longer fresh.
                var fresh = Devices.Select(d => d.Id).ToHashSet();
                changed |= !fresh.SetEquals(shown);
                shown = fresh;
                if (changed)
                    Changed?.Invoke();
                await Task.Delay(BrowseEvery, cancel);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception ex)
            {
                RequestLog.Note($"local network: browse failed: {ex.Message.ReplaceLineEndings(" ")}");
                try { await Task.Delay(BrowseEvery, cancel); } catch (OperationCanceledException) { return; }
            }
        }
    }

    // Advertisements that didn't answer, by id, port, and addresses, so they aren't tried on every browse.
    static readonly ConcurrentDictionary<string, DateTime> Silent = new();
    static readonly TimeSpan SilentFor = TimeSpan.FromMinutes(5);

    // Whether anything accepts a TCP connection on one of the device's addresses, within 1.5 seconds each.
    static async Task<bool> AnswersAsync(LanDevice device, CancellationToken cancel)
    {
        var key = $"{device.Id}|{device.Port}|{string.Join(",", device.Addresses)}";
        if (Silent.TryGetValue(key, out var since) && DateTime.UtcNow - since < SilentFor)
            return false;
        foreach (var endpoint in device.Endpoints.Where(LanDevice.IsUsable))
        {
            using var client = new TcpClient(endpoint.AddressFamily);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            timeout.CancelAfter(TimeSpan.FromSeconds(1.5));
            try
            {
                await client.ConnectAsync(endpoint, timeout.Token);
                Silent.TryRemove(key, out _);
                return true;
            }
            catch (Exception ex) when (ex is SocketException or OperationCanceledException && !cancel.IsCancellationRequested)
            {
            }
        }
        Silent[key] = DateTime.UtcNow;
        return false;
    }

    // A protocol 2 instance with an id, a full fingerprint, and at least one address Droprr will talk to.
    static LanDevice? Parse(Dnssd.Instance instance)
    {
        var txt = instance.Txt;
        if (!txt.TryGetValue("v", out var v) || !int.TryParse(v, out var version) || version < 2
            || !txt.TryGetValue("id", out var id) || id.Length is 0 or > 64
            || !txt.TryGetValue("fp", out var fp) || fp.Length != 64)
            return null;
        var port = txt.TryGetValue("port", out var p) && int.TryParse(p, out var parsed) ? parsed : instance.Port;
        var addresses = instance.Addresses.Where(LanNetwork.IsAllowedRemote).Distinct().ToList();
        if (addresses.Count == 0 || port is < 1 or > 65535)
            return null;
        txt.TryGetValue("name", out var name);
        txt.TryGetValue("platform", out var platform);
        return new LanDevice(id, string.IsNullOrWhiteSpace(name) ? instance.FullName.Split('.')[0] : name,
            platform ?? "", fp.ToLowerInvariant(), port, addresses, DateTime.UtcNow);
    }
}
