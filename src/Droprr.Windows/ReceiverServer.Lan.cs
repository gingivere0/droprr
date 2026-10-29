using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;

namespace Droprr;

// What the person sees when a nearby device asks to pair: its name and the six-digit code both screens show.
public sealed record LanPairPrompt(string Name, string Platform, string Code);

// LAN pairing (docs/PROTOCOL.md, "LAN pairing"): POST /pair/request, without a token, over HTTPS only.
sealed partial class ReceiverServer
{
    static readonly TimeSpan PromptTimeout = TimeSpan.FromSeconds(60);
    static readonly TimeSpan BackoffWindow = TimeSpan.FromMinutes(10);

    // Shows the prompt and returns whether the person accepted. Set by the app; without it, requests are declined.
    public Func<LanPairPrompt, CancellationToken, Task<bool>>? ConfirmLanPair { get; set; }

    int _promptOpen;
    readonly Dictionary<IPAddress, List<DateTime>> _refusals = new();

    async Task<IResult> LanPairRequestAsync(HttpContext context)
    {
        var remote = context.Connection.RemoteIpAddress ?? IPAddress.None;
        if (remote.IsIPv4MappedToIPv6)
            remote = remote.MapToIPv4();
        if (IsBackedOff(remote))
            return Error("too many requests", StatusCodes.Status429TooManyRequests);

        PairBody? body;
        try
        {
            body = await context.Request.ReadFromJsonAsync<PairBody>(context.RequestAborted);
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException)
        {
            return Error("body must be JSON: {\"id\", \"name\", \"platform\", \"fp\", ...}", StatusCodes.Status400BadRequest);
        }
        var name = body?.Name?.Trim() ?? "";
        var platform = body?.Platform?.Trim().ToLowerInvariant() ?? "";
        if (ValidId(body?.Id) is not { } id || ValidFingerprint(body?.Fp) is not { } fingerprint)
            return Error("id and fp are required", StatusCodes.Status400BadRequest);
        if (name.Length == 0 || !Platforms.Contains(platform))
            return Error("name and platform are required", StatusCodes.Status400BadRequest);
        if (body!.Port is < 1 or > 65535 || body.TlsPort is < 1 or > 65535)
            return Error("port must be from 1 to 65535", StatusCodes.Status400BadRequest);

        if (Interlocked.CompareExchange(ref _promptOpen, 1, 0) != 0)
            return Error("another pairing request is waiting", StatusCodes.Status429TooManyRequests);
        try
        {
            var code = DeviceIdentity.PairingCode(DeviceIdentity.Fingerprint(Settings), fingerprint);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted);
            timeout.CancelAfter(PromptTimeout);
            bool? accepted;
            try
            {
                accepted = ConfirmLanPair is { } confirm && await confirm(new LanPairPrompt(name, platform, code), timeout.Token);
            }
            catch (OperationCanceledException)
            {
                accepted = null;
            }
            if (accepted != true)
            {
                Refused(remote);
                RequestLog.Note($"local network: pairing request from {name} {(accepted is null ? "timed out" : "declined")}");
                return accepted is null
                    ? Error("timed out", StatusCodes.Status408RequestTimeout)
                    : Error("declined", StatusCodes.Status403Forbidden);
            }

            var phone = platform == "ios";
            var acceptToken = SettingsStore.NewToken();
            var sendToken = body.Token?.Trim();
            PairRequested?.Invoke(new PairRequest(name, platform, phone ? null : body.Host?.Trim(), body.Port,
                string.IsNullOrEmpty(sendToken) ? null : sendToken, acceptToken, id, fingerprint, body.TlsPort, body.Lan));
            return Results.Json(LanPairResponse(acceptToken));
        }
        finally
        {
            Volatile.Write(ref _promptOpen, 0);
        }
    }

    // The /pair and /pair/request response: this PC's name, the device token minted for the caller, and this
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

    static string? ValidFingerprint(string? fp) =>
        fp?.Trim() is { Length: 64 } value && value.All(char.IsAsciiHexDigit) ? value.ToLowerInvariant() : null;

    // Three declines or timeouts from one address within 10 minutes: that address waits 10 minutes.
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
