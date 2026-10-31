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
public sealed record LanPairPrompt(string Name, DevicePlatform Platform, string Code);

// A POST /pair, /pair/request, or /pair/confirm body as it arrives. Handlers read it through CheckedPair.
sealed record PairBody(string? Name, string? Platform, string? Host, int? Port, string? Token,
    string? Id = null, string? Fp = null, int? TlsPort = null, List<string>? Lan = null,
    string? Commit = null, string? Session = null, string? Nonce = null);

// A pairing body checked once, at the edge: a printable name (empty if missing), the platform (Unknown if it isn't
// one), ids, fingerprints, commits, and nonces well formed or null, at most 16 LAN addresses, and whether the ports
// are ports.
sealed record CheckedPair(string Name, DevicePlatform Platform, string Host, int? Port, string? SendToken, string? Id,
    string? Fingerprint, int? TlsPort, IReadOnlyList<string>? Lan, string? Commit, string? Session, string? Nonce)
{
    const int MaxLanAddresses = 16;

    public static CheckedPair From(PairBody? body) => new(
        FileNames.DeviceName(body?.Name),
        DevicePlatforms.FromWire(body?.Platform),
        body?.Host?.Trim() ?? "",
        body?.Port,
        body?.Token?.Trim() is { Length: > 0 } token ? token : null,
        ValidId(body?.Id),
        ValidHex64(body?.Fp),
        body?.TlsPort,
        body?.Lan?.Where(a => a is { Length: > 0 and <= 64 }).Take(MaxLanAddresses).ToList(),
        ValidHex64(body?.Commit),
        body?.Session,
        ValidHex64(body?.Nonce));

    public bool PortsValid => Port is null or (>= 1 and <= 65535) && TlsPort is null or (>= 1 and <= 65535);

    // 1 to 64 letters and digits, lowercased.
    static string? ValidId(string? id) =>
        id?.Trim() is { Length: > 0 and <= 64 } value && value.All(char.IsAsciiLetterOrDigit) ? value.ToLowerInvariant() : null;

    // 64 hex digits, lowercased: a fingerprint, commit, or nonce.
    static string? ValidHex64(string? value) =>
        value?.Trim() is { Length: 64 } hex && hex.All(char.IsAsciiHexDigit) ? hex.ToLowerInvariant() : null;
}

// Pairing (docs/PROTOCOL.md): POST /pair, with a token or the one code's join secret, and LAN pairing over HTTPS
// without a token, in two steps: POST /pair/request commits to the requester's nonce and gets this PC's, then
// POST /pair/confirm reveals the requester's nonce, shows the code here, and waits for the person's answer. The
// requester's identity is the TLS client certificate it presented, never a claim in the body.
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
    sealed record PairSession(string Id, IPAddress Remote, string Fingerprint, string DeviceId, string Name, DevicePlatform Platform,
        string Commit, string Nonce, DateTime Created);

    PairSession? _session;
    int _promptOpen;
    readonly Dictionary<IPAddress, List<DateTime>> _refusals = new();

    static IPAddress RemoteOf(HttpContext context)
    {
        var remote = context.Connection.RemoteIpAddress ?? IPAddress.None;
        return remote.IsIPv4MappedToIPv6 ? remote.MapToIPv4() : remote;
    }

    static string? ClientFingerprint(HttpContext context) =>
        context.Connection.ClientCertificate is { } certificate ? DeviceIdentity.Fingerprint(certificate) : null;

    // A device that just scanned this PC's pairing QR (or a computer pairing with it) introduces itself.
    // This PC mints a device token for it and keeps the token the caller minted for this PC, if any.
    async Task<IResult> PairAsync(HttpContext context)
    {
        var (raw, unreadable) = await ReadJsonAsync<PairBody>(context, MaxPairBody, "{\"name\", \"platform\", \"host\"?, \"port\"?, \"token\"?}");
        if (unreadable is not null)
            return unreadable;
        var body = CheckedPair.From(raw);
        if (body.Name.Length == 0)
            return Error("name is required", StatusCodes.Status400BadRequest);
        if (!body.Platform.CanPair())
            return Error("platform must be \"ios\", \"macos\", or \"windows\"", StatusCodes.Status400BadRequest);
        var phone = body.Platform == DevicePlatform.IOS;
        if (!phone && body.Host.Length == 0)
            return Error("host is required for computers", StatusCodes.Status400BadRequest);
        if (!body.PortsValid)
            return Error("port must be from 1 to 65535", StatusCodes.Status400BadRequest);

        // With the one code's join secret: a new peer, or, for a device that's already paired, that same peer again
        // with fresh tokens and its current certificate (pairing again just works; the person has the code open).
        PairTarget target;
        if (context.Items[JoinKey] is true)
            target = Settings.Peers.FindRepairable(body.Id, body.Fingerprint, body.Platform) is { } existing
                ? new PairTarget.Repair(existing.Name)
                : new PairTarget.New();
        else
            target = DevicePeer(context) is { } owner ? new PairTarget.Update(owner) : new PairTarget.Match();
        // Joining, the certificate the device presented (over HTTPS) is its identity rather than what the body says.
        var fingerprint = (context.Items[JoinKey] is true ? ClientFingerprint(context) : null) ?? body.Fingerprint;
        var acceptToken = SettingsStore.NewToken();
        // Phones send a token too when they can receive directly over the local network.
        PairRequested?.Invoke(new PairRequest(target, body.Name, body.Platform, phone ? null : body.Host, body.Port,
            body.SendToken, acceptToken, body.Id, fingerprint, body.TlsPort, body.Lan));
        return Results.Json(PairResponse(acceptToken));
    }

    // Step 1: { id, name, platform, commit } -> { ok, session, nonce }.
    async Task<IResult> LanPairRequestAsync(HttpContext context)
    {
        var remote = RemoteOf(context);
        if (IsBackedOff(remote))
            return Error("too many requests", StatusCodes.Status429TooManyRequests);
        if (ClientFingerprint(context) is not { } fingerprint)
            return Error("pairing needs this device's certificate as a TLS client certificate", StatusCodes.Status400BadRequest);

        var (raw, unreadable) = await ReadJsonAsync<PairBody>(context, MaxPairBody, "{\"id\", \"name\", \"platform\", \"commit\"}");
        if (unreadable is not null)
            return unreadable;
        var body = CheckedPair.From(raw);
        if (body.Id is not { } id || body.Commit is not { } commit)
            return Error("id and commit are required", StatusCodes.Status400BadRequest);
        if (body.Name.Length == 0 || !body.Platform.CanPair())
            return Error("name and platform are required", StatusCodes.Status400BadRequest);
        if (raw?.Fp is { Length: > 0 } claimed && !claimed.Trim().Equals(fingerprint, StringComparison.OrdinalIgnoreCase))
            return Error("fp doesn't match the client certificate", StatusCodes.Status400BadRequest);
        var session = new PairSession(Guid.NewGuid().ToString("N"), remote, fingerprint, id, body.Name, body.Platform, commit,
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
        var (raw, unreadable) = await ReadJsonAsync<PairBody>(context, MaxPairBody, "{\"session\", \"nonce\", ...}");
        if (unreadable is not null)
            return unreadable;
        var body = CheckedPair.From(raw);

        PairSession? session;
        lock (_refusals)
        {
            session = _session;
            if (session is null || session.Id != body.Session || DateTime.UtcNow - session.Created >= SessionTimeout
                || ClientFingerprint(context) != session.Fingerprint)
                return Error("unknown or expired pairing session", StatusCodes.Status404NotFound);
            _session = null;
        }
        if (body.Nonce is not { } nonce || DeviceIdentity.Commit(nonce) != session.Commit)
        {
            Refused(remote);
            return Error("nonce doesn't match the commit", StatusCodes.Status400BadRequest);
        }
        if (!body.PortsValid)
            return Error("port must be from 1 to 65535", StatusCodes.Status400BadRequest);
        // Pairing again: the same peer, with fresh tokens.
        var repair = Settings.Peers.FindRepairable(session.DeviceId, session.Fingerprint, session.Platform)?.Name;

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

            var phone = session.Platform == DevicePlatform.IOS;
            var acceptToken = SettingsStore.NewToken();
            PairTarget target = repair is not null ? new PairTarget.Repair(repair) : new PairTarget.New();
            PairRequested?.Invoke(new PairRequest(target, session.Name, session.Platform, phone ? null : body.Host, body.Port,
                body.SendToken, acceptToken, session.DeviceId, session.Fingerprint, body.TlsPort, body.Lan));
            return Results.Json(PairResponse(acceptToken));
        }
        finally
        {
            Volatile.Write(ref _promptOpen, 0);
        }
    }

    // The /pair and /pair/confirm response: this PC's pairing fields (OwnDevice), with the device token minted for
    // the caller.
    Dictionary<string, object?> PairResponse(string acceptToken) =>
        new(OwnDevice.PairFields(Settings, TailscaleNetwork.OwnHost(), acceptToken, LanListening)) { ["ok"] = true };

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
