using System;
using System.Collections.Generic;
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
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.Extensions.Logging;
using Microsoft.Net.Http.Headers;

namespace Droprr;

public enum ItemKind { File, Text, Url }

public sealed record ReceivedItem(ItemKind Kind, string Display, string? Path, string? Content);

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

    async Task<IResult> HandleSendAsync(HttpContext context)
    {
        var request = context.Request;
        var folder = _settings.ResolveSaveFolder();
        Directory.CreateDirectory(folder);

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
            else
            {
                return Error("use multipart/form-data or application/json", StatusCodes.Status415UnsupportedMediaType);
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
            else if (disposition.IsFormDisposition())
            {
                var field = HeaderUtilities.RemoveQuotes(disposition.Name).Value;
                if (field is "text" or "url")
                {
                    using var text = new StreamReader(section.Body, Encoding.UTF8);
                    items.Add(SaveText(folder, field, await text.ReadToEndAsync(cancel)));
                }
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
