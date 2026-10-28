using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Droprr;

static class Sender
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(30) };

    public static async Task SendFilesAsync(Peer peer, string token, IReadOnlyList<string> paths, CancellationToken cancel = default)
    {
        using var form = new MultipartFormDataContent();
        foreach (var path in paths)
        {
            var content = new StreamContent(File.OpenRead(path));
            content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
            form.Add(content, "file", Path.GetFileName(path));
        }
        await PostAsync(peer, token, form, cancel);
    }

    public static async Task SendTextAsync(Peer peer, string token, string text, CancellationToken cancel = default)
    {
        var type = LooksLikeUrl(text) ? "url" : "text";
        await PostAsync(peer, token, JsonContent.Create(new { type, content = text }), cancel);
    }

    static async Task PostAsync(Peer peer, string token, HttpContent content, CancellationToken cancel)
    {
        var endpoint = new UriBuilder(Uri.UriSchemeHttp, peer.Host, peer.Port, "send").Uri;
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint) { Content = content };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        using var response = await Http.SendAsync(request, cancel);
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(cancel);
            throw new HttpRequestException($"{(int)response.StatusCode} {response.ReasonPhrase} {body}".Trim());
        }
    }

    static bool LooksLikeUrl(string text) =>
        !text.Contains('\n') && !text.Contains(' ')
        && Uri.TryCreate(text, UriKind.Absolute, out var uri)
        && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps);
}
