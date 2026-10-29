using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.Extensions.Logging;

namespace Droprr;

public enum ItemKind { File, Text, Url }

public sealed record ReceivedItem(ItemKind Kind, string Display, string? Path, string? Content);

public sealed record TransferProgress(Guid Id, long Received, long? Total, bool Done);

sealed record PairBody(string? Name, string? Platform, string? Host, int? Port, string? Token,
    string? Id = null, string? Fp = null, int? TlsPort = null, List<string>? Lan = null,
    string? Commit = null, string? Session = null, string? Nonce = null);

// SendToken: the token the caller minted for this PC to use when calling it (computers, and phones that receive
// directly over the local network). AcceptToken: the device token this PC minted for the caller, returned in the
// response. Id, Fingerprint, TlsPort, and Lan: the caller's local network identity and addresses (protocol 2).
// ExistingPeer: the peer whose device token authenticated the request, which is updated rather than matched by name.
// FromLan: a confirmed LAN pairing, which always adds a new peer (the receiver refuses devices already paired).
public sealed record PairRequest(string Name, string Platform, string? Host, int? Port, string? SendToken, string? AcceptToken,
    string? Id = null, string? Fingerprint = null, int? TlsPort = null, IReadOnlyList<string>? Lan = null, string? ExistingPeer = null,
    bool FromLan = false);

// The receiver described in docs/PROTOCOL.md: plain HTTP on loopback and Tailscale addresses, plus HTTPS on the
// next port for the local network when it's turned on and the firewall allows it.
sealed partial class ReceiverServer : IAsyncDisposable
{
    static readonly string Version =
        typeof(ReceiverServer).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? "0.0.0";

    // Read on every request, so pairings and Settings changes apply without restarting the receiver.
    readonly Func<AppSettings> _settings;
    WebApplication? _app;

    public ReceiverServer(Func<AppSettings> settings) => _settings = settings;

    AppSettings Settings => _settings();

    // The peer whose device token authenticated the request; absent for the main token.
    const string DevicePeerKey = "droprr.devicePeer";

    static string? DevicePeer(HttpContext context) => context.Items[DevicePeerKey] as string;

    public event Action<ReceivedItem>? ItemReceived;

    // Raised on a server thread with the device name a phone asked for in GET /inbox.
    public event Action<string>? InboxPolled;

    // Raised on a server thread when a device calls POST /pair. Handlers must save the peer before
    // returning, since the caller may use its new token right away.
    public event Action<PairRequest>? PairRequested;

    // Raised on a server thread, at most every 200 ms per request, and once more when it ends.
    public event Action<TransferProgress>? ReceiveProgress;

    public IReadOnlyList<IPAddress> TailscaleAddresses { get; private set; } = [];

    // Whether HTTPS for the local network is listening, and on which port.
    public bool LanListening { get; private set; }
    public int TlsPort => LanNetwork.TlsPort(Settings.Port);

    // For tests: listen on loopback only (HTTP and HTTPS), without needing the firewall rule.
    internal bool LoopbackOnly { get; init; }

    // Plain HTTP only, even with Local network on (when the HTTPS port couldn't be opened).
    public bool WithoutLan { get; init; }

    public async Task StartAsync()
    {
        TailscaleAddresses = TailscaleNetwork.FindAddresses();
        var port = Settings.Port;
        var tlsPort = TlsPort;
        var lan = Settings.LocalNetwork && !WithoutLan && tlsPort <= 65535 && (LoopbackOnly || LanFirewall.HasRule(tlsPort));
        var certificate = lan ? DeviceIdentity.Certificate(Settings) : null;

        var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions
        {
            ContentRootPath = AppContext.BaseDirectory,
        });
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(kestrel =>
        {
            kestrel.Limits.MaxRequestBodySize = null;
            kestrel.ListenLocalhost(port);
            foreach (var address in LoopbackOnly ? [] : TailscaleAddresses)
                kestrel.Listen(address, port);
            if (certificate is not null)
            {
                void Https(Microsoft.AspNetCore.Server.Kestrel.Core.ListenOptions listen)
                {
                    // Dropped before the TLS handshake: anything but loopback, Tailscale, and private LAN ranges.
                    listen.Use(next => connection =>
                    {
                        if (!LanNetwork.IsAllowedRemote((connection.RemoteEndPoint as IPEndPoint)?.Address))
                        {
                            connection.Abort();
                            return Task.CompletedTask;
                        }
                        return next(connection);
                    });
                    // Devices present their own certificate as a client certificate; LAN pairing takes the requester's
                    // identity from it. It's checked by fingerprint where it matters, not by a chain.
                    listen.UseHttps(new Microsoft.AspNetCore.Server.Kestrel.Https.HttpsConnectionAdapterOptions
                    {
                        ServerCertificate = certificate,
                        ClientCertificateMode = Microsoft.AspNetCore.Server.Kestrel.Https.ClientCertificateMode.AllowCertificate,
                        ClientCertificateValidation = (_, _, _) => true,
                        HandshakeTimeout = TimeSpan.FromSeconds(10),
                    });
                }
                if (LoopbackOnly)
                    kestrel.ListenLocalhost(tlsPort, Https);
                else
                    kestrel.ListenAnyIP(tlsPort, Https);
            }
        });

        var app = builder.Build();
        app.Use(async (context, next) =>
        {
            await next(context);
            RequestLog.Write(context);
        });
        app.Use(async (context, next) =>
        {
            // LAN pairing is the one exchange without a token, and only over HTTPS.
            var pairRequest = context.Request.Path.Equals("/pair/request", StringComparison.OrdinalIgnoreCase);
            if (pairRequest || context.Request.Path.Equals("/pair/confirm", StringComparison.OrdinalIgnoreCase))
            {
                IResult result;
                try
                {
                    result = certificate is not null && context.Connection.LocalPort == tlsPort && HttpMethods.IsPost(context.Request.Method)
                        ? await (pairRequest ? LanPairRequestAsync(context) : LanPairConfirmAsync(context))
                        : Error("not found", StatusCodes.Status404NotFound);
                }
                catch (Exception ex) when (!context.RequestAborted.IsCancellationRequested)
                {
                    RequestLog.WriteError(context, ex);
                    result = Error("receiver error", StatusCodes.Status500InternalServerError);
                }
                await result.ExecuteAsync(context);
                return;
            }
            if (!TryAuthenticate(context.Request, out var devicePeer))
            {
                context.Response.Headers.WWWAuthenticate = "Bearer";
                await Error("unauthorized", StatusCodes.Status401Unauthorized).ExecuteAsync(context);
                return;
            }
            if (devicePeer is not null)
                context.Items[DevicePeerKey] = devicePeer;
            try
            {
                await next(context);
            }
            catch (Exception ex) when (!context.Response.HasStarted && !context.RequestAborted.IsCancellationRequested)
            {
                // The detail stays in the local log; peers only learn that something failed.
                RequestLog.WriteError(context, ex);
                await Error("receiver error", StatusCodes.Status500InternalServerError).ExecuteAsync(context);
            }
        });
        app.MapGet("/ping", () => Results.Json(new
        {
            name = Settings.DeviceName, version = Version, platform = "windows", protocol = 2,
            id = Settings.DeviceId, fp = DeviceIdentity.Fingerprint(Settings), tlsPort = LanListening ? tlsPort : (int?)null,
        }));
        app.MapFallback(() => Error("not found", StatusCodes.Status404NotFound));
        app.MapPost("/send", (Func<HttpContext, Task<IResult>>)HandleSendAsync);
        app.MapPost("/pair", (Func<HttpContext, Task<IResult>>)PairAsync);
        app.MapGet("/inbox", (Func<HttpContext, IResult>)ListInbox);
        app.MapGet("/inbox/{id}", (Func<HttpContext, string, IResult>)DownloadInboxItem);
        app.MapDelete("/inbox/{id}", (Func<HttpContext, string, IResult>)DeleteInboxItem);

        await app.StartAsync();
        _app = app;
        LanListening = certificate is not null;
    }

    // Accepts the main token or any peer's device token, comparing against every one in constant time.
    // devicePeer names the peer whose device token matched, or is null for the main token.
    bool TryAuthenticate(HttpRequest request, out string? devicePeer)
    {
        devicePeer = null;
        var header = request.Headers.Authorization.ToString();
        if (!header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return false;
        var given = Encoding.UTF8.GetBytes(header["Bearer ".Length..].Trim());
        var settings = Settings;
        var main = Matches(given, settings.Token);
        foreach (var peer in settings.Peers)
        {
            if (Matches(given, peer.AcceptToken))
                devicePeer ??= peer.Name;
        }
        foreach (var (token, peerName) in _pendingTokens)
        {
            if (Matches(given, token))
                devicePeer ??= peerName;
        }
        if (main)
            devicePeer = null;
        return main || devicePeer is not null;
    }

    // Device tokens offered in a LAN pairing this PC started, accepted while it's in progress (the device may call
    // back before it answers): token -> the name the peer will be saved under.
    readonly System.Collections.Concurrent.ConcurrentDictionary<string, string> _pendingTokens = new();

    public void AcceptPendingToken(string token, string peerName) => _pendingTokens[token] = peerName;

    public void ForgetPendingToken(string token) => _pendingTokens.TryRemove(token, out _);

    // Refuses bodies over `max` bytes (413), for requests that are small by nature.
    static void LimitBody(HttpContext context, long max)
    {
        if (context.Features.Get<Microsoft.AspNetCore.Http.Features.IHttpMaxRequestBodySizeFeature>() is { IsReadOnly: false } limit)
            limit.MaxRequestBodySize = max;
    }

    static bool Matches(byte[] given, string token) =>
        token.Length > 0 & CryptographicOperations.FixedTimeEquals(given, Encoding.UTF8.GetBytes(token));

    static readonly string[] Platforms = ["ios", "macos", "windows"];

    // A device that just scanned this PC's pairing QR (or a computer pairing with it) introduces itself.
    // This PC mints a device token for it and keeps the token the caller minted for this PC, if any.
    async Task<IResult> PairAsync(HttpContext context)
    {
        PairBody? body;
        try
        {
            body = await ReadPairBodyAsync(context);
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or BadHttpRequestException)
        {
            return Error("body must be JSON: {\"name\", \"platform\", \"host\"?, \"port\"?, \"token\"?}", StatusCodes.Status400BadRequest);
        }

        var name = Printable(body?.Name);
        var platform = body?.Platform?.Trim().ToLowerInvariant() ?? "";
        var host = body?.Host?.Trim() ?? "";
        if (name.Length == 0)
            return Error("name is required", StatusCodes.Status400BadRequest);
        if (!Platforms.Contains(platform))
            return Error("platform must be \"ios\", \"macos\", or \"windows\"", StatusCodes.Status400BadRequest);
        if (platform != "ios" && host.Length == 0)
            return Error("host is required for computers", StatusCodes.Status400BadRequest);
        if (body!.Port is < 1 or > 65535)
            return Error("port must be from 1 to 65535", StatusCodes.Status400BadRequest);

        var phone = platform == "ios";
        // Phones send one too when they can receive directly over the local network.
        var sendToken = body.Token?.Trim();
        var acceptToken = SettingsStore.NewToken();
        PairRequested?.Invoke(new PairRequest(name, platform, phone ? null : host, body.Port,
            string.IsNullOrEmpty(sendToken) ? null : sendToken, acceptToken,
            ValidId(body.Id), ValidFingerprint(body.Fp), body.TlsPort, body.Lan, DevicePeer(context)));
        return Results.Json(LanPairResponse(acceptToken));
    }

    // With a device token, only that peer's queue (?for= is ignored); with the main token, the queue named by ?for=.
    IResult ListInbox(HttpContext context)
    {
        var device = DevicePeer(context);
        if (device is null)
        {
            device = context.Request.Query["for"].ToString().Trim();
            if (device.Length == 0)
                return Error("missing ?for=<device name>", StatusCodes.Status400BadRequest);
            InboxPolled?.Invoke(device);
        }

        // Different names can share a folder once cleaned up for the file system, so filter by the exact name too.
        var items = Outbox.List(device).Where(item => item.Peer.Trim().Equals(device.Trim(), StringComparison.OrdinalIgnoreCase)).Select(item => item.Type == "file"
            ? (object)new { id = item.Id, type = item.Type, name = item.Name, size = item.Size, created = Iso8601(item.Created) }
            : new { id = item.Id, type = item.Type, name = item.Name, size = item.Size, content = item.Content, created = Iso8601(item.Created) });
        return Results.Json(new { ok = true, items });
    }

    // An item visible to this request: any queue for the main token, only its own queue for a device token.
    static (OutboxItem Item, string DataPath)? FindInboxItem(HttpContext context, string id) =>
        Outbox.Find(id) is { } found
        && (DevicePeer(context) is not { } peer || found.Item.Peer.Trim().Equals(peer.Trim(), StringComparison.OrdinalIgnoreCase))
            ? found
            : null;

    static IResult DeleteInboxItem(HttpContext context, string id) =>
        FindInboxItem(context, id) is not null && Outbox.Delete(id)
            ? Results.Json(new { ok = true })
            : Error("unknown or expired item", StatusCodes.Status404NotFound);

    static IResult DownloadInboxItem(HttpContext context, string id)
    {
        if (FindInboxItem(context, id) is not { } found)
            return Error("unknown or expired item", StatusCodes.Status404NotFound);
        if (found.Item.Type != "file")
            return Results.Text(found.Item.Content, "text/plain; charset=utf-8");

        if (!ContentTypes.TryGetContentType(found.Item.Name, out var contentType))
            contentType = "application/octet-stream";
        var stream = new FileStream(found.DataPath, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete, 81920, useAsync: true);
        return Results.Stream(stream, contentType, found.Item.Name, enableRangeProcessing: true);
    }

    static readonly FileExtensionContentTypeProvider ContentTypes = new();

    static string Iso8601(DateTime time) =>
        time.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    static IResult Error(string message, int status) => Results.Json(new { ok = false, error = message }, statusCode: status);

    public async ValueTask DisposeAsync()
    {
        if (_app is null)
            return;
        try { await _app.StopAsync(); } catch { /* already stopping */ }
        await _app.DisposeAsync();
        _app = null;
    }
}
