using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Web.WebView2.Core;

namespace Droprr;

// Browser access over the internet (docs/PROTOCOL.md): runs host/host.html, hidden, in WebView2 (the browser engine
// built into Windows), which keeps this PC in its room on the relay and talks WebRTC to the browsers that scanned
// its code. The page reaches this class through requests to its own origin under /api, which never leave the PC.
sealed class BrowserHost : IDisposable
{
    public const string DefaultRelay = "wss://droprr-relay.droprr-domain.workers.dev";
    public const string DefaultSite = "https://gingivere0.github.io/droprr/";
    const string Origin = "https://host.droprr.example";

    readonly Func<AppSettings> _settings;
    readonly BrowserAccess _access;
    readonly Func<BrowserHello, BrowserHelloResult> _hello;
    Window? _window;
    CoreWebView2Controller? _controller;
    CoreWebView2? _core;
    static readonly HttpClient Loopback = new() { Timeout = System.Threading.Timeout.InfiniteTimeSpan };

    public BrowserHost(Func<AppSettings> settings, BrowserAccess access, Func<BrowserHello, BrowserHelloResult> hello)
    {
        _settings = settings;
        _access = access;
        _hello = hello;
    }

    AppSettings Settings => _settings();

    // The page's DTLS fingerprint (base64url), once it has reported it.
    public string? Fingerprint { get; private set; }

    public event Action? Ready;

    // Peer ids of the browsers connected right now.
    public IReadOnlyCollection<string> Online { get; private set; } = [];

    public event Action? OnlineChanged;

    public static string Relay(AppSettings settings) =>
        string.IsNullOrWhiteSpace(settings.RelayUrl) ? DefaultRelay : settings.RelayUrl.Trim().TrimEnd('/');

    public static string Site(AppSettings settings) =>
        string.IsNullOrWhiteSpace(settings.SiteUrl) ? DefaultSite : settings.SiteUrl.Trim();

    // SHA-256 of the host key: the room browsers join.
    public static string Room(string hostKey) => Base64Url(SHA256.HashData(FromBase64Url(hostKey)));

    // The link in the QR code, while a code is open and the page is ready. appInfo (base64url JSON) adds what the
    // iPhone app needs to pair from the same code.
    public string? JoinLink(string? appInfo = null) =>
        Fingerprint is { } fp && _access.Secret is { } secret
            ? $"{Site(Settings)}#{Room(Settings.HostKey)}.{secret}.{fp}" + (appInfo is null ? "" : "." + appInfo)
            : null;

    // Tells the page to read its config again (a code opened or closed, or the relay changed).
    public void ConfigChanged() => _core?.PostWebMessageAsJson("{\"t\":\"config\"}");

    // Tells the page something was queued, so it sends it now rather than at its next check.
    public void OutboxChanged() => _core?.PostWebMessageAsJson("{\"t\":\"outbox\"}");

    public async Task StartAsync()
    {
        // A window that's never shown, just for the handle WebView2 needs.
        _window = new Window { Width = 0, Height = 0, ShowInTaskbar = false, WindowStyle = WindowStyle.None, Style = new Style(typeof(Window)) };
        var handle = new WindowInteropHelper(_window).EnsureHandle();
        // Its own profile folder, so the DTLS certificate (and so the code's fingerprint) survives updates. Background
        // throttling is off because nobody ever sees this page, but it must answer promptly.
        var options = new CoreWebView2EnvironmentOptions
        {
            AdditionalBrowserArguments = "--disable-background-timer-throttling --disable-renderer-backgrounding --disable-features=IntensiveWakeUpThrottling",
        };
        var profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Droprr", "BrowserHost");
        var environment = await CoreWebView2Environment.CreateAsync(null, profile, options);
        _controller = await environment.CreateCoreWebView2ControllerAsync(handle);
        _controller.IsVisible = false;
        _core = _controller.CoreWebView2;
        _core.Settings.AreDevToolsEnabled = false;
        _core.Settings.AreDefaultContextMenusEnabled = false;
        _core.Settings.IsStatusBarEnabled = false;
        _core.AddWebResourceRequestedFilter(Origin + "/*", CoreWebView2WebResourceContext.All);
        _core.WebResourceRequested += OnRequest;
        // Only this PC's own page, never anything else.
        _core.NavigationStarting += (_, e) => e.Cancel = !e.Uri.StartsWith(Origin + "/", StringComparison.Ordinal);
        _core.NewWindowRequested += (_, e) => e.Handled = true;
        _core.WebMessageReceived += (_, _) => { };
        _core.Navigate(Origin + "/host.html");
        // If the page never reports ready (it failed to load, or its script stopped), load it again.
        _watchdog = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(20) };
        _watchdog.Tick += (_, _) =>
        {
            if (Fingerprint is not null)
                _watchdog.Stop();
            else
                _core?.Navigate(Origin + "/host.html");
        };
        _watchdog.Start();
    }

    System.Windows.Threading.DispatcherTimer? _watchdog;

    static readonly Dictionary<string, (string Resource, string Type)> Files = new()
    {
        ["/host.html"] = ("Droprr.host.host.html", "text/html; charset=utf-8"),
        ["/host.js"] = ("Droprr.host.host.js", "text/javascript; charset=utf-8"),
        ["/rtc.js"] = ("Droprr.host.rtc.js", "text/javascript; charset=utf-8"),
    };

    async void OnRequest(object? sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        var deferral = e.GetDeferral();
        try
        {
            var uri = new Uri(e.Request.Uri);
            var (status, type, body) = await HandleAsync(e.Request.Method, uri, e.Request);
            e.Response = _core!.Environment.CreateWebResourceResponse(body, status, status == 200 ? "OK" : "Error",
                $"Content-Type: {type}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff");
        }
        catch (Exception ex)
        {
            RequestLog.Note($"browser host: {e.Request.Method} {new Uri(e.Request.Uri).AbsolutePath} failed: {ex.Message.ReplaceLineEndings(" ")}");
            e.Response = _core!.Environment.CreateWebResourceResponse(Json(new { ok = false, error = "error" }), 500, "Error", "Content-Type: application/json");
        }
        finally
        {
            deferral.Complete();
        }
    }

    static Stream Json(object value) => new MemoryStream(JsonSerializer.SerializeToUtf8Bytes(value, JsonOptions));

    static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    async Task<T?> ReadJsonAsync<T>(CoreWebView2WebResourceRequest request)
    {
        if (request.Content is null)
            return default;
        using var buffer = new MemoryStream();
        await request.Content.CopyToAsync(buffer);
        return JsonSerializer.Deserialize<T>(buffer.ToArray(), JsonOptions);
    }

    sealed record ReadyBody(string? Fp);
    sealed record StatusBody(List<string>? Browsers);
    sealed record HelloBody(string? Id, string? Name, string? Secret, string? Token);

    async Task<(int Status, string Type, Stream Body)> HandleAsync(string method, Uri uri, CoreWebView2WebResourceRequest request)
    {
        const string json = "application/json; charset=utf-8";
        var path = uri.AbsolutePath;
        if (method == "GET" && Files.TryGetValue(path, out var file))
            return (200, file.Type, typeof(BrowserHost).Assembly.GetManifestResourceStream(file.Resource)!);

        var settings = Settings;
        switch (method, path)
        {
            case ("GET", "/api/config"):
                return (200, json, Json(new { relay = Relay(settings), key = settings.HostKey, name = settings.DeviceName, secret = _access.Secret }));
            case ("POST", "/api/ready"):
                var ready = await ReadJsonAsync<ReadyBody>(request);
                if (ready?.Fp is { Length: 43 } fp)
                {
                    Fingerprint = fp;
                    Ready?.Invoke();
                }
                return (200, json, Json(new { ok = true }));
            case ("POST", "/api/status"):
                Online = (await ReadJsonAsync<StatusBody>(request))?.Browsers?.ToList() ?? [];
                OnlineChanged?.Invoke();
                return (200, json, Json(new { ok = true }));
            case ("POST", "/api/hello"):
                var hello = await ReadJsonAsync<HelloBody>(request);
                var result = _hello(new BrowserHello(hello?.Id ?? "", hello?.Name ?? "", hello?.Secret, hello?.Token));
                return (200, json, result.Ok
                    ? Json(new { ok = true, peer = result.PeerId, token = result.Token })
                    : Json(new { ok = false, error = result.Error }));
        }

        // /api/p/<peer id>/...: one browser's sends and queue.
        var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length >= 4 && parts[0] == "api" && parts[1] == "p"
            && settings.Peers.Find(p => p.IsBrowser && p.Id == Uri.UnescapeDataString(parts[2])) is { } peer)
        {
            var rest = parts[3..];
            if (method == "POST" && rest is ["send"])
                return await ForwardSendAsync(peer, request);
            if (method == "GET" && rest is ["inbox"])
            {
                var items = Outbox.List(peer.Name).Where(i => i.Peer.Trim().Equals(peer.Name.Trim(), StringComparison.OrdinalIgnoreCase))
                    .Select(i => new { id = i.Id, type = i.Type, name = i.Name, size = i.Size, content = i.Content });
                return (200, json, Json(new { ok = true, items }));
            }
            if (rest is ["inbox", var id] && Outbox.Find(id) is { } found
                && found.Item.Peer.Trim().Equals(peer.Name.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                if (method == "DELETE")
                {
                    Outbox.Delete(id);
                    return (200, json, Json(new { ok = true }));
                }
                if (method == "GET")
                {
                    return found.Item.Type == "file"
                        ? (200, "application/octet-stream", new FileStream(found.DataPath, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete))
                        : (200, "text/plain; charset=utf-8", new MemoryStream(Encoding.UTF8.GetBytes(found.Item.Content ?? "")));
                }
            }
        }
        return (404, json, Json(new { ok = false, error = "not found" }));
    }

    // An item from a browser goes through this PC's own receiver over loopback, authenticated as that browser, so
    // it's saved, announced, and checked exactly like anything else that arrives.
    async Task<(int, string, Stream)> ForwardSendAsync(Peer peer, CoreWebView2WebResourceRequest request)
    {
        var temp = Path.Combine(Path.GetTempPath(), $"droprr-{Guid.NewGuid():N}.part");
        try
        {
            await using (var target = File.Create(temp))
            {
                if (request.Content is not null)
                    await request.Content.CopyToAsync(target);
            }
            var headers = request.Headers;
            using var message = new HttpRequestMessage(HttpMethod.Post, $"http://localhost:{Settings.Port}/send");
            message.Headers.Authorization = new AuthenticationHeaderValue("Bearer", peer.AcceptToken);
            var content = new StreamContent(new FileStream(temp, FileMode.Open, FileAccess.Read, FileShare.Read, 81920, FileOptions.DeleteOnClose));
            if (headers.Contains("Content-Type"))
                content.Headers.TryAddWithoutValidation("Content-Type", headers.GetHeader("Content-Type"));
            if (headers.Contains("X-Droprr-Filename"))
                message.Headers.TryAddWithoutValidation("X-Droprr-Filename", headers.GetHeader("X-Droprr-Filename"));
            message.Content = content;
            using var response = await Task.Run(() => Loopback.SendAsync(message));
            var body = await response.Content.ReadAsByteArrayAsync();
            return ((int)response.StatusCode, "application/json; charset=utf-8", new MemoryStream(body));
        }
        finally
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch { /* deleted on close */ }
        }
    }

    public static string NewHostKey() => Base64Url(RandomNumberGenerator.GetBytes(32));

    static string Base64Url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    static byte[] FromBase64Url(string text)
    {
        var padded = text.Replace('-', '+').Replace('_', '/');
        return Convert.FromBase64String(padded + new string('=', (4 - padded.Length % 4) % 4));
    }

    public void Dispose()
    {
        _watchdog?.Stop();
        _controller?.Close();
        _controller = null;
        _core = null;
        _window?.Close();
        _window = null;
    }
}

public sealed record BrowserHello(string Id, string Name, string? Secret, string? Token);

public sealed record BrowserHelloResult(bool Ok, string? PeerId = null, string? Token = null, string? Error = null);
