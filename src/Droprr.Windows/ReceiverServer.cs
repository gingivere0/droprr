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

sealed record PairBody(string? Name, string? Platform, string? Host, int? Port);

public sealed record PairRequest(string Name, string Platform, string? Host, int? Port);

// The HTTP receiver described in docs/PROTOCOL.md. Binds only to loopback and Tailscale addresses.
sealed partial class ReceiverServer : IAsyncDisposable
{
    static readonly string Version =
        typeof(ReceiverServer).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? "0.0.0";

    readonly AppSettings _settings;
    WebApplication? _app;

    public ReceiverServer(AppSettings settings) => _settings = settings;

    public event Action<ReceivedItem>? ItemReceived;

    // Raised on a server thread with the device name a phone asked for in GET /inbox.
    public event Action<string>? InboxPolled;

    // Raised on a server thread when a device calls POST /pair.
    public event Action<PairRequest>? PairRequested;

    // Raised on a server thread, at most every 200 ms per request, and once more when it ends.
    public event Action<TransferProgress>? ReceiveProgress;

    public IReadOnlyList<IPAddress> TailscaleAddresses { get; private set; } = [];

    public async Task StartAsync()
    {
        TailscaleAddresses = TailscaleNetwork.FindAddresses();

        var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions
        {
            ContentRootPath = AppContext.BaseDirectory,
        });
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(kestrel =>
        {
            kestrel.Limits.MaxRequestBodySize = null;
            kestrel.ListenLocalhost(_settings.Port);
            foreach (var address in TailscaleAddresses)
                kestrel.Listen(address, _settings.Port);
        });

        var app = builder.Build();
        app.Use(async (context, next) =>
        {
            await next(context);
            RequestLog.Write(context);
        });
        app.Use(async (context, next) =>
        {
            if (!IsAuthorized(context.Request))
            {
                context.Response.Headers.WWWAuthenticate = "Bearer";
                await Error("unauthorized", StatusCodes.Status401Unauthorized).ExecuteAsync(context);
                return;
            }
            try
            {
                await next(context);
            }
            catch (Exception ex) when (!context.Response.HasStarted && !context.RequestAborted.IsCancellationRequested)
            {
                await Error(ex.Message, StatusCodes.Status500InternalServerError).ExecuteAsync(context);
            }
        });
        app.MapGet("/ping", () => Results.Json(new { name = _settings.DeviceName, version = Version, platform = "windows" }));
        app.MapFallback(() => Error("not found", StatusCodes.Status404NotFound));
        app.MapPost("/send", (Func<HttpContext, Task<IResult>>)HandleSendAsync);
        app.MapPost("/pair", (Func<HttpContext, Task<IResult>>)PairAsync);
        app.MapGet("/inbox", (Func<HttpContext, IResult>)ListInbox);
        app.MapGet("/inbox/{id}", (Func<string, IResult>)DownloadInboxItem);
        app.MapDelete("/inbox/{id}", (string id) =>
            Outbox.Delete(id) ? Results.Json(new { ok = true }) : Error("unknown or expired item", StatusCodes.Status404NotFound));

        await app.StartAsync();
        _app = app;
    }

    bool IsAuthorized(HttpRequest request)
    {
        var header = request.Headers.Authorization.ToString();
        if (_settings.Token.Length == 0 || !header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return false;
        var given = Encoding.UTF8.GetBytes(header["Bearer ".Length..].Trim());
        return CryptographicOperations.FixedTimeEquals(given, Encoding.UTF8.GetBytes(_settings.Token));
    }

    static readonly string[] Platforms = ["ios", "macos", "windows"];

    // A device that just scanned this PC's pairing QR introduces itself, so this PC can send back to it.
    async Task<IResult> PairAsync(HttpContext context)
    {
        PairBody? body;
        try
        {
            body = await context.Request.ReadFromJsonAsync<PairBody>(context.RequestAborted);
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException)
        {
            return Error("body must be JSON: {\"name\", \"platform\", \"host\"?, \"port\"?}", StatusCodes.Status400BadRequest);
        }

        var name = body?.Name?.Trim() ?? "";
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

        PairRequested?.Invoke(new PairRequest(name, platform, platform == "ios" ? null : host, body.Port));
        return Results.Json(new { ok = true, name = _settings.DeviceName });
    }

    IResult ListInbox(HttpContext context)
    {
        var device = context.Request.Query["for"].ToString().Trim();
        if (device.Length == 0)
            return Error("missing ?for=<device name>", StatusCodes.Status400BadRequest);

        InboxPolled?.Invoke(device);
        var items = Outbox.List(device).Select(item => item.Type == "file"
            ? (object)new { id = item.Id, type = item.Type, name = item.Name, size = item.Size, created = Iso8601(item.Created) }
            : new { id = item.Id, type = item.Type, name = item.Name, size = item.Size, content = item.Content, created = Iso8601(item.Created) });
        return Results.Json(new { ok = true, items });
    }

    static IResult DownloadInboxItem(string id)
    {
        if (Outbox.Find(id) is not { } found)
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
