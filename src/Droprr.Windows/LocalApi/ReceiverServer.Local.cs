using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;

namespace Droprr;

// The local API (docs/PROTOCOL.md, "Local API"; the request shapes are in LocalApi.cs): GET /local/devices and
// POST /local/send, for tools on this PC such as the Droprr MCP server.
sealed partial class ReceiverServer
{
    // Made fresh each time Droprr starts, and written to the connection file for local tools to read. It works
    // only for /local/, and the main token and device tokens don't work there.
    static readonly string LocalToken = SettingsStore.NewToken();

    // Sends to a peer the way the Send window does. Without it, /local/ isn't served.
    public Func<Peer, IReadOnlyList<string>, string, CancellationToken, Task<DeliveryResult>>? LocalApiSend { get; init; }

    static bool IsLocalPath(PathString path) => path.StartsWithSegments("/local", StringComparison.OrdinalIgnoreCase);

    // Lets local tools find this receiver: the plain HTTP port and the local token.
    void WriteLocalConnectionFile()
    {
        if (LocalApiSend is null)
            return;
        try
        {
            LocalApi.WriteConnectionFile(SettingsStore.Folder, Settings.Port, LocalToken);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            RequestLog.Note($"local API: couldn't write {LocalApi.ConnectionFileName} ({ex.Message.ReplaceLineEndings(" ")})");
        }
    }

    async Task<IResult> HandleLocalAsync(HttpContext context)
    {
        // Only this PC, over plain HTTP, and never from a web page (a page's request carries an Origin).
        var remote = context.Connection.RemoteIpAddress;
        if (LocalApiSend is null || remote is null || !IPAddress.IsLoopback(remote) || context.Connection.LocalPort != Settings.Port
            || context.Request.Headers.Origin.Count > 0)
            return Error("not found", StatusCodes.Status404NotFound);
        var header = context.Request.Headers.Authorization.ToString();
        if (!header.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
            || !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(header["Bearer ".Length..].Trim()), Encoding.UTF8.GetBytes(LocalToken)))
        {
            context.Response.Headers.WWWAuthenticate = "Bearer";
            return Error("unauthorized", StatusCodes.Status401Unauthorized);
        }

        var path = context.Request.Path.Value!.TrimEnd('/').ToLowerInvariant();
        if (path == "/local/devices" && HttpMethods.IsGet(context.Request.Method))
        {
            var settings = Settings;
            return Results.Json(LocalApi.Devices(settings.DeviceName, settings.Peers, peer => Outbox.List(peer.Name).Count));
        }
        if (path == "/local/send" && HttpMethods.IsPost(context.Request.Method))
            return await LocalApiSendAsync(context);
        return Error("not found", StatusCodes.Status404NotFound);
    }

    async Task<IResult> LocalApiSendAsync(HttpContext context)
    {
        var (body, invalid) = await ReadJsonAsync<JsonDocument>(context, LocalApi.MaxSendBody, LocalApi.SendShape);
        if (invalid is not null)
            return invalid;
        using var document = body;
        var (request, failure) = LocalApi.ParseSend(document?.RootElement ?? default, Settings.Peers);
        if (failure is not null)
            return Error(failure.Error, failure.Status);
        try
        {
            var result = await LocalApiSend!(request!.Peer, request.Files, request.Text, context.RequestAborted);
            RequestLog.Note($"local API: sent to {request.Peer.Name} ({result.Wire})");
            return Results.Json(new { ok = true, to = request.Peer.Name, path = result.Wire });
        }
        catch (Exception ex) when (!context.RequestAborted.IsCancellationRequested
                                   && ex is HttpRequestException or IdentityChangedException or IOException)
        {
            // The local caller sees why, as the Send window would show it.
            return Error(ex.Message.Contains(request!.Peer.Name, StringComparison.Ordinal) ? ex.Message : $"{request.Peer.Name}: {ex.Message}",
                StatusCodes.Status502BadGateway);
        }
    }
}
