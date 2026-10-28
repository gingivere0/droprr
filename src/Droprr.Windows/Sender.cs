using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Droprr;

static class Sender
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(30) };

    // Reports bytes uploaded as they're read from disk.
    public static async Task SendFilesAsync(Peer peer, string token, IReadOnlyList<string> paths,
        IProgress<long>? progress = null, CancellationToken cancel = default)
    {
        using var form = new MultipartFormDataContent();
        foreach (var path in paths)
        {
            var content = new StreamContent(new ProgressStream(File.OpenRead(path), n => progress?.Report(n)), 81920);
            content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
            form.Add(content, "file", Path.GetFileName(path));
        }
        await PostAsync(peer, token, form, cancel);
    }

    public static async Task SendTextAsync(Peer peer, string token, string text, CancellationToken cancel = default) =>
        await PostAsync(peer, token, JsonContent.Create(new { type = TextType(text), content = text }), cancel);

    // Returns the peer's platform from /ping, or null if it can't be reached.
    public static async Task<string?> PingAsync(Peer peer, string token, CancellationToken cancel = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(TimeSpan.FromSeconds(4));
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, Endpoint(peer, "ping"));
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            using var response = await Http.SendAsync(request, timeout.Token);
            if (!response.IsSuccessStatusCode)
                return null;
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(timeout.Token));
            return json.RootElement.TryGetProperty("platform", out var platform) ? platform.GetString() : null;
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or JsonException)
        {
            return null;
        }
    }

    // "url" for a single http(s) link, otherwise "text".
    public static string TextType(string text) =>
        !text.Contains('\n') && !text.Contains(' ')
        && Uri.TryCreate(text, UriKind.Absolute, out var uri)
        && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps)
            ? "url"
            : "text";

    static Uri Endpoint(Peer peer, string path) => new UriBuilder(Uri.UriSchemeHttp, peer.Host, peer.Port, path).Uri;

    static async Task PostAsync(Peer peer, string token, HttpContent content, CancellationToken cancel)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint(peer, "send")) { Content = content };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await Http.SendAsync(request, cancel);
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(cancel);
            throw new HttpRequestException($"{(int)response.StatusCode} {response.ReasonPhrase} {body}".Trim());
        }
    }
}
