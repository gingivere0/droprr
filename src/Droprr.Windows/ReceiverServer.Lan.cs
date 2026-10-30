using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;

namespace Droprr;

// What the person sees when a nearby device asks to pair: its name and the six-digit code both screens show.
public sealed record LanPairPrompt(string Name, string Platform, string Code);

// LAN pairing (docs/PROTOCOL.md, "LAN pairing"), over HTTPS only and without a token, in two steps:
// POST /pair/request commits to the requester's nonce and gets this PC's, then POST /pair/confirm reveals the
// requester's nonce, shows the code here, and waits for the person's answer. The requester's identity is the
// TLS client certificate it presented, never a claim in the body.
sealed partial class ReceiverServer
{
    static readonly TimeSpan PromptTimeout = TimeSpan.FromSeconds(60);
    static readonly TimeSpan SessionTimeout = TimeSpan.FromSeconds(30);
    static readonly TimeSpan BackoffWindow = TimeSpan.FromMinutes(10);
    const long MaxPairBody = 64 * 1024;

    // Shows the prompt and returns whether the person accepted. Set by the app; without it, requests are declined.
    // Throws OperationCanceledException if `cancel` fires first (the request timed out or was abandoned).
    public Func<LanPairPrompt, CancellationToken, Task<bool>>? ConfirmLanPair { get; set; }

    // The one pairing in progress: from /pair/request until /pair/confirm answers, or SessionTimeout passes
    // without a confirm.
    sealed record PairSession(string Id, IPAddress Remote, string Fingerprint, string DeviceId, string Name, string Platform,
        string Commit, string Nonce, DateTime Created);

    PairSession? _session;
    int _promptOpen;
    readonly Dictionary<IPAddress, List<DateTime>> _refusals = new();

    // The peer this device already is, if any.
    Peer? AlreadyPaired(string deviceId, string fingerprint) =>
        Settings.Peers.Find(p => p.Id == deviceId || p.Fingerprint.Equals(fingerprint, StringComparison.OrdinalIgnoreCase));

    // A device pairing again is the same peer again (fresh tokens, nothing to remove first) when its TLS client
    // certificate is the one pinned for that peer (or the peer has no pin yet, say it was paired over Tailscale; the
    // person still confirms, and its certificate is pinned then). A different certificate claiming a pinned peer's
    // id, or a peer of another kind, is refused, so a pairing can never take over (or move the pin of) another device.
    Peer? Blocking(string deviceId, string fingerprint, string platform) =>
        AlreadyPaired(deviceId, fingerprint) is { } existing
        && !((existing.Fingerprint.Length == 0 || existing.Fingerprint.Equals(fingerprint, StringComparison.OrdinalIgnoreCase)) && !existing.IsBrowser
             && existing.IsPhone == (platform == "ios") && (existing.Id.Length == 0 || existing.Id == deviceId))
            ? existing
            : null;

    static IPAddress RemoteOf(HttpContext context)
    {
        var remote = context.Connection.RemoteIpAddress ?? IPAddress.None;
        return remote.IsIPv4MappedToIPv6 ? remote.MapToIPv4() : remote;
    }

    static string? ClientFingerprint(HttpContext context) =>
        context.Connection.ClientCertificate is { } certificate ? DeviceIdentity.Fingerprint(certificate) : null;

    static async Task<PairBody?> ReadPairBodyAsync(HttpContext context)
    {
        LimitBody(context, MaxPairBody);
        return await context.Request.ReadFromJsonAsync<PairBody>(context.RequestAborted);
    }

    // Step 1: { id, name, platform, commit } -> { ok, session, nonce }.
    async Task<IResult> LanPairRequestAsync(HttpContext context)
    {
        var remote = RemoteOf(context);
        if (IsBackedOff(remote))
            return Error("too many requests", StatusCodes.Status429TooManyRequests);
        if (ClientFingerprint(context) is not { } fingerprint)
            return Error("pairing needs this device's certificate as a TLS client certificate", StatusCodes.Status400BadRequest);

        PairBody? body;
        try
        {
            body = await ReadPairBodyAsync(context);
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or BadHttpRequestException)
        {
            return Error("body must be JSON: {\"id\", \"name\", \"platform\", \"commit\"}", StatusCodes.Status400BadRequest);
        }
        var name = Printable(body?.Name);
        var platform = body?.Platform?.Trim().ToLowerInvariant() ?? "";
        if (ValidId(body?.Id) is not { } id || ValidHex64(body?.Commit) is not { } commit)
            return Error("id and commit are required", StatusCodes.Status400BadRequest);
        if (name.Length == 0 || !Platforms.Contains(platform))
            return Error("name and platform are required", StatusCodes.Status400BadRequest);
        if (body!.Fp is { Length: > 0 } claimed && !claimed.Trim().Equals(fingerprint, StringComparison.OrdinalIgnoreCase))
            return Error("fp doesn't match the client certificate", StatusCodes.Status400BadRequest);
        if (Blocking(id, fingerprint, platform) is { } existing)
            return Error($"already paired as {existing.Name}: remove it on {Settings.DeviceName} to pair again", StatusCodes.Status409Conflict);

        var session = new PairSession(Guid.NewGuid().ToString("N"), remote, fingerprint, id, name, platform, commit,
            DeviceIdentity.NewNonce(), DateTime.UtcNow);
        lock (_refusals)
        {
            if (Volatile.Read(ref _promptOpen) != 0 || _session is { } open && DateTime.UtcNow - open.Created < SessionTimeout)
                return Error("another pairing request is waiting", StatusCodes.Status429TooManyRequests);
            _session = session;
        }
        return Results.Json(new { ok = true, session = session.Id, nonce = session.Nonce });
    }

    // Step 2: { session, nonce, token?, host?, port?, tlsPort?, lan? } -> the /pair response once the person accepts.
    async Task<IResult> LanPairConfirmAsync(HttpContext context)
    {
        var remote = RemoteOf(context);
        PairBody? body;
        try
        {
            body = await ReadPairBodyAsync(context);
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or BadHttpRequestException)
        {
            return Error("body must be JSON: {\"session\", \"nonce\", ...}", StatusCodes.Status400BadRequest);
        }

        PairSession? session;
        lock (_refusals)
        {
            session = _session;
            if (session is null || session.Id != body?.Session || DateTime.UtcNow - session.Created >= SessionTimeout
                || ClientFingerprint(context) != session.Fingerprint)
                return Error("unknown or expired pairing session", StatusCodes.Status404NotFound);
            _session = null;
        }
        if (ValidHex64(body.Nonce) is not { } nonce || DeviceIdentity.Commit(nonce) != session.Commit)
        {
            Refused(remote);
            return Error("nonce doesn't match the commit", StatusCodes.Status400BadRequest);
        }
        if (body.Port is < 1 or > 65535 || body.TlsPort is < 1 or > 65535)
            return Error("port must be from 1 to 65535", StatusCodes.Status400BadRequest);
        if (Blocking(session.DeviceId, session.Fingerprint, session.Platform) is { } existing)
            return Error($"already paired as {existing.Name}: remove it on {Settings.DeviceName} to pair again", StatusCodes.Status409Conflict);
        // Pairing again: the same peer, with fresh tokens.
        var repair = AlreadyPaired(session.DeviceId, session.Fingerprint)?.Name;

        if (Interlocked.CompareExchange(ref _promptOpen, 1, 0) != 0)
            return Error("another pairing request is waiting", StatusCodes.Status429TooManyRequests);
        try
        {
            var code = DeviceIdentity.PairingCode(DeviceIdentity.Fingerprint(Settings), session.Fingerprint, nonce, session.Nonce);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted);
            timeout.CancelAfter(PromptTimeout);
            bool? accepted;
            try
            {
                accepted = ConfirmLanPair is { } confirm && await confirm(new LanPairPrompt(session.Name, session.Platform, code), timeout.Token);
            }
            catch (OperationCanceledException)
            {
                accepted = null;
            }
            if (accepted != true)
            {
                Refused(remote);
                RequestLog.Note($"local network: pairing request from {session.Name} {(accepted is null ? "timed out" : "declined")}");
                return accepted is null
                    ? Error("timed out", StatusCodes.Status408RequestTimeout)
                    : Error("declined", StatusCodes.Status403Forbidden);
            }

            var phone = session.Platform == "ios";
            var acceptToken = SettingsStore.NewToken();
            var sendToken = body.Token?.Trim();
            PairRequested?.Invoke(new PairRequest(session.Name, session.Platform, phone ? null : body.Host?.Trim(), body.Port,
                string.IsNullOrEmpty(sendToken) ? null : sendToken, acceptToken, session.DeviceId, session.Fingerprint,
                body.TlsPort, body.Lan, ExistingPeer: repair, FromLan: repair is null));
            return Results.Json(LanPairResponse(acceptToken));
        }
        finally
        {
            Volatile.Write(ref _promptOpen, 0);
        }
    }

    // The /pair and /pair/confirm response: this PC's name, the device token minted for the caller, and this
    // PC's local network identity and addresses.
    object LanPairResponse(string acceptToken) => new
    {
        ok = true,
        name = Settings.DeviceName,
        token = acceptToken,
        id = Settings.DeviceId,
        fp = DeviceIdentity.Fingerprint(Settings),
        tlsPort = LanListening ? TlsPort : (int?)null,
        lan = LanListening ? LanNetwork.LocalAddresses().Select(a => $"{a.Address}:{TlsPort}").ToList() : [],
        host = PairWindow.MagicDnsName() ?? TailscaleAddresses.FirstOrDefault()?.ToString(),
    };

    static string? ValidId(string? id) =>
        id?.Trim() is { Length: > 0 and <= 64 } value && value.All(char.IsAsciiLetterOrDigit) ? value.ToLowerInvariant() : null;

    static string? ValidFingerprint(string? fp) => ValidHex64(fp);

    static string? ValidHex64(string? value) =>
        value?.Trim() is { Length: 64 } hex && hex.All(char.IsAsciiHexDigit) ? hex.ToLowerInvariant() : null;

    // A device name from the network, safe to show and log: no control or bidirectional-override characters, at
    // most 64 characters.
    internal static string Printable(string? name) => FileNames.Printable(name ?? "", 64);

    // Three declines, timeouts, or bad reveals from one address within 10 minutes: that address waits 10 minutes.
    bool IsBackedOff(IPAddress address)
    {
        lock (_refusals)
        {
            if (!_refusals.TryGetValue(address, out var times))
                return false;
            times.RemoveAll(t => DateTime.UtcNow - t > BackoffWindow);
            return times.Count >= 3;
        }
    }

    void Refused(IPAddress address)
    {
        lock (_refusals)
        {
            if (!_refusals.TryGetValue(address, out var times))
                _refusals[address] = times = new List<DateTime>();
            times.Add(DateTime.UtcNow);
        }
    }
}
