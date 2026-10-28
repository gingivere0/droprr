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
using System.Threading;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.StaticFiles;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.Extensions.Logging;
using Microsoft.Net.Http.Headers;

namespace Droprr;

public enum ItemKind { File, Text, Url }

public sealed record ReceivedItem(ItemKind Kind, string Display, string? Path, string? Content);

public sealed record TransferProgress(Guid Id, long Received, long? Total, bool Done);

sealed record SendBody(string? Type, string? Content);

// The HTTP receiver described in docs/PROTOCOL.md. Binds only to loopback and Tailscale addresses.
sealed class ReceiverServer : IAsyncDisposable
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

    async Task<IResult> HandleSendAsync(HttpContext context)
    {
        var request = context.Request;
        var folder = _settings.ResolveSaveFolder();
        Directory.CreateDirectory(folder);

        // Report progress for the whole request body, whatever its format.
        var transfer = Guid.NewGuid();
        var total = request.ContentLength;
        long received = 0;
        var lastReport = Environment.TickCount64;
        request.Body = new ProgressStream(request.Body, n =>
        {
            received += n;
            if (Environment.TickCount64 - lastReport < 200)
                return;
            lastReport = Environment.TickCount64;
            ReceiveProgress?.Invoke(new TransferProgress(transfer, received, total, Done: false));
        });
        try
        {
            return await ReceiveAsync(context, folder);
        }
        finally
        {
            ReceiveProgress?.Invoke(new TransferProgress(transfer, received, total, Done: true));
        }
    }

    async Task<IResult> ReceiveAsync(HttpContext context, string folder)
    {
        var request = context.Request;
        List<ReceivedItem> items;
        try
        {
            if (request.ContentType?.StartsWith("multipart/form-data", StringComparison.OrdinalIgnoreCase) == true)
            {
                items = await ReadMultipartAsync(request, folder, context.RequestAborted);
            }
            else if (request.HasJsonContentType())
            {
                var body = await request.ReadFromJsonAsync<SendBody>(context.RequestAborted)
                    ?? throw new InvalidDataException("empty JSON body");
                items = [SaveText(folder, body.Type, body.Content)];
            }
            else if (request.ContentType?.StartsWith("application/x-www-form-urlencoded", StringComparison.OrdinalIgnoreCase) == true)
            {
                // iOS Shortcuts sends this when a Form field is Text rather than File.
                var form = await request.ReadFormAsync(context.RequestAborted);
                items = new List<ReceivedItem>();
                foreach (var field in new[] { "url", "content", "text", "file" })
                {
                    var value = form[field].ToString();
                    if (value.Length > 0)
                        items.Add(SaveText(folder, field == "url" || IsSingleWebUrl(value) ? "url" : "text", value));
                }
            }
            else if (IsMediaType(request, "text/plain") && RawFileName(request) is null)
            {
                using var reader = new StreamReader(request.Body, Encoding.UTF8);
                var value = await reader.ReadToEndAsync(context.RequestAborted);
                items = [SaveText(folder, IsSingleWebUrl(value) ? "url" : "text", value)];
            }
            else
            {
                // Raw upload: the body is the file itself (iOS Shortcuts "Request Body: File").
                items = [await SaveRawFileAsync(request, folder, context.RequestAborted)];
            }
        }
        catch (Exception ex) when (ex is InvalidDataException or JsonException)
        {
            return Error(ex.Message, StatusCodes.Status400BadRequest);
        }

        if (items.Count == 0)
            return Error("nothing to receive", StatusCodes.Status400BadRequest);

        foreach (var item in items)
            ItemReceived?.Invoke(item);
        return Results.Json(new { ok = true, received = items.Count });
    }

    static IResult Error(string message, int status) => Results.Json(new { ok = false, error = message }, statusCode: status);

    // Streams each file part straight to disk so large files are never buffered in memory.
    static async Task<List<ReceivedItem>> ReadMultipartAsync(HttpRequest request, string folder, CancellationToken cancel)
    {
        var boundary = HeaderUtilities.RemoveQuotes(MediaTypeHeaderValue.Parse(request.ContentType).Boundary).Value;
        if (string.IsNullOrEmpty(boundary))
            throw new InvalidDataException("missing multipart boundary");

        var reader = new MultipartReader(boundary, request.Body) { BodyLengthLimit = null };
        var items = new List<ReceivedItem>();
        for (var section = await reader.ReadNextSectionAsync(cancel); section is not null; section = await reader.ReadNextSectionAsync(cancel))
        {
            if (!ContentDispositionHeaderValue.TryParse(section.ContentDisposition, out var disposition))
                continue;

            if (disposition.IsFileDisposition())
            {
                var name = disposition.FileNameStar.HasValue
                    ? disposition.FileNameStar.Value
                    : HeaderUtilities.RemoveQuotes(disposition.FileName).Value;
                items.Add(await SaveFileAsync(folder, name, section.Body, cancel));
            }
            else
            {
                // Any part without a filename is text, or a url when it's a single http(s) URL.
                using var text = new StreamReader(section.Body, Encoding.UTF8);
                var value = await text.ReadToEndAsync(cancel);
                if (value.Length > 0)
                    items.Add(SaveText(folder, IsSingleWebUrl(value) ? "url" : "text", value));
            }
        }
        return items;
    }

    static async Task<ReceivedItem> SaveFileAsync(string folder, string? name, Stream body, CancellationToken cancel)
    {
        var (stream, path) = FileNames.CreateUnique(folder, name);
        try
        {
            await using (stream)
                await body.CopyToAsync(stream, cancel);
        }
        catch
        {
            try { File.Delete(path); } catch { /* best effort cleanup of a partial file */ }
            throw;
        }
        return new ReceivedItem(ItemKind.File, Path.GetFileName(path), path, null);
    }

    static readonly Dictionary<string, string> ExtensionsByMediaType = new(StringComparer.OrdinalIgnoreCase)
    {
        // Keep in sync with the table in docs/PROTOCOL.md.
        ["image/jpeg"] = ".jpg", ["image/png"] = ".png", ["image/heic"] = ".heic", ["image/heif"] = ".heif",
        ["image/gif"] = ".gif", ["image/webp"] = ".webp", ["video/quicktime"] = ".mov", ["video/mp4"] = ".mp4",
        ["audio/mpeg"] = ".mp3", ["audio/mp4"] = ".m4a", ["application/pdf"] = ".pdf", ["application/zip"] = ".zip",
        ["text/plain"] = ".txt",
    };

    static async Task<ReceivedItem> SaveRawFileAsync(HttpRequest request, string folder, CancellationToken cancel)
    {
        if (request.ContentLength == 0)
            throw new InvalidDataException("empty body");

        var extension = ExtensionsByMediaType.GetValueOrDefault(MediaType(request), ".bin");
        var name = RawFileName(request) ?? $"Droprr {DateTime.Now:yyyy-MM-dd HHmmss}";
        if (!Path.HasExtension(name))
            name += extension;
        var item = await SaveFileAsync(folder, name, request.Body, cancel);
        if (new FileInfo(item.Path!).Length == 0)
        {
            File.Delete(item.Path!);
            throw new InvalidDataException("empty body");
        }
        return item;
    }

    static string? RawFileName(HttpRequest request)
    {
        var header = request.Headers["X-Droprr-Filename"].ToString();
        var name = header.Length > 0 ? Uri.UnescapeDataString(header) : null;
        if (string.IsNullOrWhiteSpace(name) && ContentDispositionHeaderValue.TryParse(request.Headers.ContentDisposition.ToString(), out var disposition))
            name = disposition.FileNameStar.HasValue ? disposition.FileNameStar.Value : HeaderUtilities.RemoveQuotes(disposition.FileName).Value;
        return string.IsNullOrWhiteSpace(name) ? null : name;
    }

    static string MediaType(HttpRequest request) => request.ContentType?.Split(';')[0].Trim() ?? "";

    static bool IsMediaType(HttpRequest request, string mediaType) =>
        MediaType(request).Equals(mediaType, StringComparison.OrdinalIgnoreCase);

    static bool IsSingleWebUrl(string value)
    {
        value = value.Trim();
        return !value.Any(char.IsWhiteSpace)
               && Uri.TryCreate(value, UriKind.Absolute, out var uri)
               && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps);
    }

    static ReceivedItem SaveText(string folder, string? type, string? content)
    {
        if (string.IsNullOrEmpty(content))
            throw new InvalidDataException("content is empty");

        var stamp = DateTime.Now.ToString("yyyy-MM-dd HHmmss");
        switch (type?.ToLowerInvariant())
        {
            case "text":
            {
                var (stream, path) = FileNames.CreateUnique(folder, $"Text {stamp}.txt");
                using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
                    writer.Write(content);
                return new ReceivedItem(ItemKind.Text, content, path, content);
            }
            case "url":
            {
                content = content.Trim();
                if (content.Contains('\n') || content.Contains('\r') || !Uri.TryCreate(content, UriKind.Absolute, out _))
                    throw new InvalidDataException("content is not an absolute URL");
                var (stream, path) = FileNames.CreateUnique(folder, $"Link {stamp}.url");
                using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
                    writer.Write($"[InternetShortcut]\r\nURL={content}\r\n");
                return new ReceivedItem(ItemKind.Url, content, path, content);
            }
            default:
                throw new InvalidDataException("type must be \"text\" or \"url\"");
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_app is null)
            return;
        try { await _app.StopAsync(); } catch { /* already stopping */ }
        await _app.DisposeAsync();
        _app = null;
    }
}
