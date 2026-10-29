using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Droprr;

// How a send went: "lan" or "tailscale", and whether the peer's LAN identity didn't match its pin.
public sealed record SendOutcome(string Path, bool IdentityChanged)
{
    public string Label => Path == "lan" ? "Wi-Fi" : "Tailscale";
}

// What a peer's /ping says about it.
public sealed record PingInfo(string? Platform, string? Id, string? Fingerprint, int? TlsPort, string? Version = null);

// A /pair or /pair/request response: the device token minted for this PC, and the peer's identity and addresses.
public sealed record PairInfo(string Token, string? Name, string? Id, string? Fingerprint, int? TlsPort, List<string> Lan, string? Host);

// The peer's LAN certificate didn't match its pin, and there's no Tailscale path to fall back on.
// A plain HTTP (Tailscale path) host that doesn't resolve to a Tailscale or loopback address.
public sealed class NotTailscaleException(string host)
    : IOException($"{host} isn't a Tailscale address, so Droprr won't send to it unencrypted.");

public sealed class IdentityChangedException(string name)
    : Exception($"{name}'s identity changed. Pair again.");

static class Sender
{
    // Connecting gets 5 seconds; once connected, a large file has as long as it needs, as long as it keeps moving
    // (see PostAsync). Plain HTTP only ever goes to Tailscale addresses (or this PC), so tokens and files never
    // travel unencrypted over another network, whatever host a peer has.
    static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        ConnectTimeout = TimeSpan.FromSeconds(5),
        ConnectCallback = ConnectOverTailscaleAsync,
    })
    { Timeout = Timeout.InfiniteTimeSpan };

    // A send that moves no bytes (and gets no answer) for this long is given up.
    static readonly TimeSpan StallTimeout = TimeSpan.FromMinutes(2);
    static readonly TimeSpan LanConnectTimeout = TimeSpan.FromSeconds(1.5);
    static readonly ConcurrentDictionary<string, HttpClient> Pinned = new();

    // Off when Settings turns the local network off.
    public static bool LocalNetworkEnabled { get; set; } = true;

    // This PC's device certificate, presented as the TLS client certificate on every HTTPS (local network)
    // request, so the other side knows which device is calling (LAN pairing depends on it).
    public static System.Security.Cryptography.X509Certificates.X509Certificate2? ClientCertificate { get; set; }

    sealed record Route(Uri Base, HttpClient Client, string Path);

    // Reports bytes uploaded as they're read from disk, and each path it tries in `stage`.
    public static Task<SendOutcome> SendFilesAsync(Peer peer, string token, IReadOnlyList<string> paths,
        IProgress<long>? progress = null, CancellationToken cancel = default, IProgress<string>? stage = null) =>
        SendAsync(peer, token, moved =>
        {
            var form = new MultipartFormDataContent();
            foreach (var path in paths)
            {
                var content = new StreamContent(new ProgressStream(File.OpenRead(path), n =>
                {
                    moved();
                    progress?.Report(n);
                }), 81920);
                content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
                form.Add(content, "file", Path.GetFileName(path));
            }
            return form;
        }, cancel, stage);

    public static Task<SendOutcome> SendTextAsync(Peer peer, string token, string text, CancellationToken cancel = default,
        IProgress<string>? stage = null) =>
        SendAsync(peer, token, _ => JsonContent.Create(new { type = TextType(text), content = text }), cancel, stage);

    // Whether Tailscale is up on this PC: without a 100.64/10 address, a Tailscale host can't be reached, so it
    // isn't even tried.
    static bool TailscaleUp => TailscaleNetwork.FindAddresses().Count > 0;

    // The peer's Tailscale host can be tried: Tailscale is up here (or the host is this PC itself, for tests).
    static bool CanTryTailscale(Peer peer) => peer.Host.Length > 0
        && (TailscaleUp || peer.Host is "localhost" || (IPAddress.TryParse(peer.Host, out var ip) && IPAddress.IsLoopback(ip)));

    // Why a peer can't be reached at all, without trying: no Wi-Fi route and no usable Tailscale route.
    static string Unreachable(Peer peer) => peer.Host.Length > 0
        ? peer.Fingerprint.Length > 0
            ? $"{peer.Name} isn't reachable: Tailscale is off on this PC, and it hasn't been seen on this Wi-Fi."
            : $"{peer.Name} isn't reachable: Tailscale is off on this PC."
        : $"{peer.Name} hasn't been seen on this Wi-Fi. Check that Droprr is open on it and it's on the same network.";

    // LAN first when the peer was discovered recently (about 1.5 s to connect), then Tailscale. Never both: a
    // body is sent once. A LAN certificate that doesn't match the pin isn't used.
    // `content` makes the body, calling the Action it's given whenever bytes go out.
    static async Task<SendOutcome> SendAsync(Peer peer, string token, Func<Action, HttpContent> content, CancellationToken cancel,
        IProgress<string>? stage)
    {
        var identityChanged = false;
        var triedLan = LocalNetworkEnabled && peer.Fingerprint.Length > 0 && LanDiscovery.Find(peer) is not null;
        if (triedLan)
            stage?.Report($"Sending to {peer.Name} over Wi-Fi…");
        if (await LanRouteAsync(peer, cancel) is { } lan)
        {
            try
            {
                await PostAsync(lan, token, content, cancel);
                return new SendOutcome("lan", false);
            }
            catch (HttpRequestException ex) when (ex.InnerException is AuthenticationException)
            {
                identityChanged = true;
                RequestLog.Note($"local network: {peer.Name}'s certificate doesn't match its pin");
            }
        }
        if (!CanTryTailscale(peer))
            throw identityChanged ? new IdentityChangedException(peer.Name) : new HttpRequestException(Unreachable(peer));
        stage?.Report(triedLan ? "Wi-Fi didn't answer. Trying Tailscale…" : $"Sending to {peer.Name} over Tailscale…");
        try
        {
            await PostAsync(TailscaleRoute(peer), token, content, cancel);
        }
        catch (HttpRequestException ex) when (ex.InnerException is NotTailscaleException)
        {
            throw new HttpRequestException($"{peer.Name}'s address ({peer.Host}) isn't on Tailscale, so Droprr won't send to it unencrypted. Use its Tailscale name, or pair over Wi-Fi.", ex);
        }
        catch (Exception ex) when (!cancel.IsCancellationRequested && IsConnectFailure(ex))
        {
            throw new HttpRequestException($"Couldn't reach {peer.Name} over Tailscale. Check that Tailscale is on and {peer.Name} is awake.", ex);
        }
        return new SendOutcome("tailscale", identityChanged);
    }

    // Connecting failed or timed out (as opposed to the peer answering with an error).
    static bool IsConnectFailure(Exception ex) =>
        ex is OperationCanceledException or TimeoutException
        || (ex is HttpRequestException { StatusCode: null } && ex.InnerException is SocketException or IOException or TimeoutException or OperationCanceledException);

    // The peer over the local network, if it has a pin, was discovered recently, and one of its addresses answers.
    static async Task<Route?> LanRouteAsync(Peer peer, CancellationToken cancel)
    {
        if (!LocalNetworkEnabled || peer.Fingerprint.Length == 0 || LanDiscovery.Find(peer) is not { } device)
            return null;
        foreach (var endpoint in device.Endpoints.Where(LanDevice.IsUsable))
        {
            if (await CanConnectAsync(endpoint, cancel))
                return new Route(new UriBuilder(Uri.UriSchemeHttps, endpoint.Address.ToString(), endpoint.Port, "/").Uri,
                    PinnedClient(peer.Fingerprint), "lan");
        }
        return null;
    }

    // Whether the peer can take a direct send over the local network right now (phones: only while open).
    public static async Task<bool> IsOnLanAsync(Peer peer, CancellationToken cancel = default) =>
        await LanRouteAsync(peer, cancel) is not null;

    static Route TailscaleRoute(Peer peer) => new(new UriBuilder(Uri.UriSchemeHttp, peer.Host, peer.Port, "/").Uri, Http, "tailscale");

    static async Task<bool> CanConnectAsync(IPEndPoint endpoint, CancellationToken cancel)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(LanConnectTimeout);
        using var socket = new Socket(endpoint.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
        try
        {
            await socket.ConnectAsync(endpoint, timeout.Token);
            return true;
        }
        catch (Exception ex) when (ex is SocketException or OperationCanceledException)
        {
            return false;
        }
    }

    // A client that trusts only the certificate with this fingerprint: no chain, host name, or expiry checks.
    static HttpClient PinnedClient(string fingerprint) => Pinned.GetOrAdd(fingerprint.ToLowerInvariant(), pin =>
        new HttpClient(new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(5),
            SslOptions = new SslClientAuthenticationOptions
            {
                RemoteCertificateValidationCallback = (_, certificate, _, _) =>
                    certificate is not null && DeviceIdentity.Fingerprint(certificate) == pin,
                // Always this PC's own certificate, whatever issuers the server lists.
                LocalCertificateSelectionCallback = (_, _, _, _, _) => ClientCertificate!,
            },
        })
        { Timeout = Timeout.InfiniteTimeSpan });

    // Introduces this PC to a computer peer over Tailscale (POST /pair), handing it `acceptToken` to use when
    // calling this PC. Returns what the peer answered, or null if pairing failed.
    public static async Task<PairInfo?> PairAsync(Peer peer, string token, AppSettings settings, string host,
        string acceptToken, CancellationToken cancel = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(TimeSpan.FromSeconds(10));
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(TailscaleRoute(peer).Base, "pair"))
            {
                Content = JsonContent.Create(OwnPairFields(settings, host, acceptToken)),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            using var response = await Http.SendAsync(request, timeout.Token);
            return response.IsSuccessStatusCode ? ReadPairInfo(await response.Content.ReadAsStringAsync(timeout.Token)) : null;
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or JsonException)
        {
            return null;
        }
    }

    // What this PC tells a device it pairs with: name, platform, Tailscale host, ports, the token minted for it,
    // and its local network identity and addresses.
    public static Dictionary<string, object?> OwnPairFields(AppSettings settings, string? host, string acceptToken, bool lanListening = true)
    {
        var tlsPort = LanNetwork.TlsPort(settings.Port);
        return new()
        {
            ["id"] = settings.DeviceId,
            ["name"] = settings.DeviceName,
            ["platform"] = "windows",
            ["host"] = host,
            ["port"] = settings.Port,
            ["token"] = acceptToken,
            ["fp"] = DeviceIdentity.Fingerprint(settings),
            ["tlsPort"] = lanListening ? tlsPort : null,
            ["lan"] = lanListening ? LanNetwork.LocalAddresses().Select(a => $"{a.Address}:{tlsPort}").ToList() : new List<string>(),
        };
    }

    // The server's certificate fingerprint at this address, from a TLS handshake that trusts nothing yet.
    public static async Task<string?> ServerFingerprintAsync(IPEndPoint endpoint, CancellationToken cancel = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(TimeSpan.FromSeconds(4));
        try
        {
            using var client = new TcpClient(endpoint.AddressFamily);
            await client.ConnectAsync(endpoint, timeout.Token);
            string? fingerprint = null;
            await using var tls = new SslStream(client.GetStream(), false, (_, certificate, _, _) =>
            {
                fingerprint = certificate is null ? null : DeviceIdentity.Fingerprint(certificate);
                return certificate is not null;
            });
            // With this PC's certificate too: a Mac requires one on every HTTPS connection.
            await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
            {
                TargetHost = "droprr",
                LocalCertificateSelectionCallback = (_, _, _, _, _) => ClientCertificate!,
            }, timeout.Token);
            return fingerprint;
        }
        catch (Exception ex) when (ex is SocketException or IOException or AuthenticationException or OperationCanceledException)
        {
            return null;
        }
    }

    // POST /pair/request to a discovered device, pinned to the fingerprint it presented, waiting while the person
    // there decides. Returns the status (200, 403 declined, 408 timed out, 429 busy; 0 if unreachable).
    // LAN pairing as the requester (docs/PROTOCOL.md, "LAN pairing"): commits to a nonce with POST /pair/request,
    // gets the receiver's nonce, shows the code (`showCode`), then reveals its nonce with POST /pair/confirm, which
    // answers once the person there accepts or declines. `body` is this PC's /pair fields. Returns the final HTTP
    // status (0 if the device couldn't be reached), the receiver's answer on 200, and its error message otherwise.
    public static async Task<(int Status, PairInfo? Info, string? Error)> RequestLanPairAsync(IPEndPoint endpoint, string fingerprint,
        string ownFingerprint, Dictionary<string, object?> body, Action<string> showCode, CancellationToken cancel)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(TimeSpan.FromSeconds(100));
        var client = PinnedClient(fingerprint);
        Uri At(string path) => new UriBuilder(Uri.UriSchemeHttps, endpoint.Address.ToString(), endpoint.Port, path).Uri;
        static string? ErrorOf(string text)
        {
            try
            {
                using var json = JsonDocument.Parse(text);
                return json.RootElement.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.String ? error.GetString() : null;
            }
            catch (JsonException)
            {
                return null;
            }
        }
        try
        {
            var nonce = DeviceIdentity.NewNonce();
            var request = new Dictionary<string, object?>
            {
                ["id"] = body["id"], ["name"] = body["name"], ["platform"] = body["platform"],
                ["fp"] = ownFingerprint, ["commit"] = DeviceIdentity.Commit(nonce),
            };
            string session, receiverNonce;
            using (var response = await client.PostAsync(At("pair/request"), JsonContent.Create(request), timeout.Token))
            {
                var text = await response.Content.ReadAsStringAsync(timeout.Token);
                if (response.StatusCode != HttpStatusCode.OK)
                    return ((int)response.StatusCode, null, ErrorOf(text));
                using var json = JsonDocument.Parse(text);
                session = json.RootElement.GetProperty("session").GetString() ?? "";
                receiverNonce = json.RootElement.GetProperty("nonce").GetString() ?? "";
                if (receiverNonce.Length != 64 || !receiverNonce.All(char.IsAsciiHexDigit))
                    return (0, null, "unexpected answer");
            }
            // Only now, with the receiver's nonce fixed, is this side's revealed.
            showCode(DeviceIdentity.PairingCode(fingerprint, ownFingerprint, nonce, receiverNonce));
            var confirm = new Dictionary<string, object?>(body) { ["session"] = session, ["nonce"] = nonce };
            confirm.Remove("fp");
            confirm.Remove("id");
            using (var response = await client.PostAsync(At("pair/confirm"), JsonContent.Create(confirm), timeout.Token))
            {
                var text = await response.Content.ReadAsStringAsync(timeout.Token);
                return response.StatusCode == HttpStatusCode.OK
                    ? (200, ReadPairInfo(text), null)
                    : ((int)response.StatusCode, null, ErrorOf(text));
            }
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or JsonException or KeyNotFoundException or InvalidOperationException)
        {
            return (0, null, null);
        }
    }

    static PairInfo? ReadPairInfo(string body)
    {
        using var json = JsonDocument.Parse(body);
        var root = json.RootElement;
        string? Text(string name) => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        if (Text("token") is not { Length: > 0 } token)
            return null;
        var lan = root.TryGetProperty("lan", out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.String).Select(e => e.GetString()!).ToList()
            : new List<string>();
        var tlsPort = root.TryGetProperty("tlsPort", out var port) && port.ValueKind == JsonValueKind.Number ? port.GetInt32() : (int?)null;
        return new PairInfo(token, Text("name"), Text("id"), Text("fp")?.ToLowerInvariant(), tlsPort, lan, Text("host"));
    }

    // What the peer's /ping says, over Tailscale (which already authenticates the device, so its id and
    // fingerprint can be pinned), or null if it can't be reached.
    public static async Task<PingInfo?> PingAsync(Peer peer, string token, CancellationToken cancel = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(TimeSpan.FromSeconds(4));
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(TailscaleRoute(peer).Base, "ping"));
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            using var response = await Http.SendAsync(request, timeout.Token);
            if (!response.IsSuccessStatusCode)
                return null;
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(timeout.Token));
            var root = json.RootElement;
            string? Text(string name) => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
            var tlsPort = root.TryGetProperty("tlsPort", out var port) && port.ValueKind == JsonValueKind.Number ? port.GetInt32() : (int?)null;
            return new PingInfo(Text("platform"), Text("id"), Text("fp")?.ToLowerInvariant(), tlsPort, Text("version"));
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or JsonException)
        {
            return null;
        }
    }

    // Settings' Test: /ping the way a send would go (Wi-Fi first, pinned; then Tailscale). Returns, for example,
    // "Mac · v0.1.0 · Wi-Fi", or what went wrong.
    public static async Task<(bool Ok, string Text)> TestAsync(Peer peer, CancellationToken cancel = default)
    {
        if (peer.Token.Length == 0)
            return (false, "Missing Token");
        var routes = new List<Route>();
        if (await LanRouteAsync(peer, cancel) is { } lan)
            routes.Add(lan);
        if (CanTryTailscale(peer))
            routes.Add(TailscaleRoute(peer));
        if (routes.Count == 0)
            return (false, Unreachable(peer));
        var identityChanged = false;
        foreach (var route in routes)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            timeout.CancelAfter(TimeSpan.FromSeconds(4));
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(route.Base, "ping"));
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", peer.Token);
                using var response = await route.Client.SendAsync(request, timeout.Token);
                if ((int)response.StatusCode == 401)
                    return (false, "Wrong token");
                if (!response.IsSuccessStatusCode)
                    continue;
                using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(timeout.Token));
                string? Text(string name) => json.RootElement.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
                var platform = Text("platform") switch { "macos" => "Mac", "windows" => "Windows PC", "ios" => "iPhone", var other => other ?? "Droprr" };
                var path = route.Path == "lan" ? "Wi-Fi" : "Tailscale";
                return (true, $"{platform} · v{Text("version") ?? "?"} · {path}" + (identityChanged ? " (Wi-Fi identity changed: pair again)" : ""));
            }
            catch (HttpRequestException ex) when (ex.InnerException is AuthenticationException)
            {
                identityChanged = true;
            }
            catch (Exception ex) when (!cancel.IsCancellationRequested && ex is HttpRequestException or OperationCanceledException or JsonException)
            {
            }
        }
        cancel.ThrowIfCancellationRequested();
        return (false, identityChanged ? $"{peer.Name}'s identity changed. Pair again." : "Couldn't reach it");
    }

    // "url" for a single http(s) link, otherwise "text".
    public static string TextType(string text) =>
        !text.Contains('\n') && !text.Contains(' ')
        && Uri.TryCreate(text, UriKind.Absolute, out var uri)
        && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps)
            ? "url"
            : "text";

    // Gives up once nothing has moved for StallTimeout, rather than after a fixed time, so a large file over a slow
    // link has as long as it needs.
    static async Task PostAsync(Route route, string token, Func<Action, HttpContent> content, CancellationToken cancel)
    {
        using var stalled = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        stalled.CancelAfter(StallTimeout);
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(route.Base, "send"))
        {
            Content = content(() => stalled.CancelAfter(StallTimeout)),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        try
        {
            using var response = await route.Client.SendAsync(request, stalled.Token);
            if (!response.IsSuccessStatusCode)
            {
                var body = await response.Content.ReadAsStringAsync(stalled.Token);
                throw new HttpRequestException($"{(int)response.StatusCode} {response.ReasonPhrase} {body}".Trim());
            }
        }
        catch (OperationCanceledException) when (!cancel.IsCancellationRequested && stalled.IsCancellationRequested)
        {
            throw new HttpRequestException($"The transfer stopped: nothing moved for {StallTimeout.TotalMinutes:0} minutes.");
        }
    }

    // Plain HTTP's connect step: resolves the host and connects only to a Tailscale or loopback address.
    static async ValueTask<Stream> ConnectOverTailscaleAsync(SocketsHttpConnectionContext context, CancellationToken cancel)
    {
        var host = context.DnsEndPoint.Host;
        var addresses = IPAddress.TryParse(host.Trim('[', ']'), out var literal)
            ? [literal]
            : await Dns.GetHostAddressesAsync(host, cancel);
        var allowed = addresses.Where(a => IPAddress.IsLoopback(a) || LanNetwork.IsTailscale(a.IsIPv4MappedToIPv6 ? a.MapToIPv4() : a)).ToArray();
        if (allowed.Length == 0)
            throw new NotTailscaleException(host);
        var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try
        {
            await socket.ConnectAsync(allowed, context.DnsEndPoint.Port, cancel);
            return new NetworkStream(socket, ownsSocket: true);
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }
}
