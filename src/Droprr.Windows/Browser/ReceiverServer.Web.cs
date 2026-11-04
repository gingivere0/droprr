using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;

namespace Droprr;

// Browser access (docs/PROTOCOL.md, "Browser access"): the page in web/ at /web, and the HttpOnly cookie a browser
// signed in with earlier, accepted in place of a bearer token on the few endpoints the page uses. New browsers
// connect over the internet with the one code instead. A browser is a queue-only peer ("web"), like a phone without Droprr open.
sealed partial class ReceiverServer
{
    const string WebCookie = "droprr";
    const string WebHeader = "X-Droprr-Web";
    static readonly TimeSpan WebCookieLifetime = TimeSpan.FromDays(30);

    // Set by the app: the one code's join secret.
    public BrowserAccess? BrowserAccess { get; init; }

    // Removes a browser that disconnected itself, with anything waiting for it.
    public event Action<string>? BrowserRemoved;

    // This PC's MagicDNS name, looked up once when the receiver starts: a host name a browser may use.
    string? _magicDns;

    // The page's files, embedded at build time from web/ and the website's shared common.js and app.css:
    // published path -> (resource, content type).
    static readonly Dictionary<string, (string Resource, string ContentType)> WebFiles = new(StringComparer.OrdinalIgnoreCase)
    {
        ["/web"] = ("Droprr.web.index.html", "text/html; charset=utf-8"),
        ["/web/"] = ("Droprr.web.index.html", "text/html; charset=utf-8"),
        ["/web/app.js"] = ("Droprr.web.app.js", "text/javascript; charset=utf-8"),
        ["/web/common.js"] = ("Droprr.web.common.js", "text/javascript; charset=utf-8"),
        ["/web/app.css"] = ("Droprr.web.app.css", "text/css; charset=utf-8"),
        ["/web/icon.png"] = ("Droprr.web.icon.png", "image/png"),
    };

    // The endpoints a browser's cookie works on. Never /pair.
    static bool CookieAllowed(HttpRequest request)
    {
        var path = request.Path.Value ?? "";
        return (HttpMethods.IsGet(request.Method) && (path.Equals("/ping", StringComparison.OrdinalIgnoreCase)
                    || path.Equals("/inbox", StringComparison.OrdinalIgnoreCase)
                    || path.StartsWith("/inbox/", StringComparison.OrdinalIgnoreCase)))
            || (HttpMethods.IsPost(request.Method) && path.Equals("/send", StringComparison.OrdinalIgnoreCase))
            || (HttpMethods.IsDelete(request.Method) && path.StartsWith("/inbox/", StringComparison.OrdinalIgnoreCase));
    }

    static bool IsWebPath(PathString path) =>
        path.Equals("/web", StringComparison.OrdinalIgnoreCase) || path.StartsWithSegments("/web", StringComparison.OrdinalIgnoreCase);

    // Requests from the page itself, on a host name this PC answers to:
    // - the Host is an IP address, localhost, this PC's name, or its MagicDNS name (not a name an attacker's DNS
    //   could point here);
    // - an Origin, when the browser sends one, is this same origin;
    // - anything but a GET carries X-Droprr-Web, which another site can't add without a CORS preflight, and this
    //   receiver never answers preflights.
    bool IsFromPage(HttpRequest request)
    {
        var host = request.Host.Host.Trim('[', ']');
        var knownHost = IPAddress.TryParse(host, out _)
            || host.Equals("localhost", StringComparison.OrdinalIgnoreCase)
            || host.Equals(Environment.MachineName, StringComparison.OrdinalIgnoreCase)
            || (_magicDns is { } dns && (host.Equals(dns, StringComparison.OrdinalIgnoreCase)
                || host.Equals(dns.Split('.')[0], StringComparison.OrdinalIgnoreCase)));
        if (!knownHost)
            return false;
        var origin = request.Headers.Origin.ToString();
        if (origin.Length > 0 && !origin.Equals($"{request.Scheme}://{request.Host}", StringComparison.OrdinalIgnoreCase))
            return false;
        return HttpMethods.IsGet(request.Method) || request.Headers[WebHeader].ToString() == "1";
    }

    // The browser peer whose cookie this request carries, if the request may use it.
    string? CookiePeer(HttpRequest request)
    {
        if (request.Headers.Authorization.Count > 0 || !request.Cookies.TryGetValue(WebCookie, out var value) || value is not { Length: > 0 }
            || !IsFromPage(request))
            return null;
        var given = System.Text.Encoding.UTF8.GetBytes(value);
        string? peer = null;
        foreach (var p in Settings.Peers)
        {
            if (p.IsBrowser && Matches(given, p.AcceptToken))
                peer ??= p.Name;
        }
        return peer;
    }

    void SetWebCookie(HttpContext context, string token) =>
        context.Response.Cookies.Append(WebCookie, token, new CookieOptions
        {
            HttpOnly = true,
            Secure = context.Request.IsHttps,
            SameSite = SameSiteMode.Strict,
            Path = "/",
            MaxAge = WebCookieLifetime,
            IsEssential = true,
        });

    // /web and /web/signout. Returns the result to send.
    async Task<IResult> HandleWebAsync(HttpContext context)
    {
        var request = context.Request;
        var path = request.Path.Value ?? "";
        if (HttpMethods.IsGet(request.Method) && WebFiles.TryGetValue(path, out var file))
            return WebFile(context, file.Resource, file.ContentType);
        if (HttpMethods.IsPost(request.Method) && path.Equals("/web/signout", StringComparison.OrdinalIgnoreCase))
        {
            if (CookiePeer(request) is { } peer)
                BrowserRemoved?.Invoke(peer);
            context.Response.Cookies.Delete(WebCookie, new CookieOptions { Path = "/", Secure = request.IsHttps, SameSite = SameSiteMode.Strict, HttpOnly = true });
            return Results.Json(new { ok = true });
        }
        return Error("not found", StatusCodes.Status404NotFound);
    }

    static IResult WebFile(HttpContext context, string resource, string contentType)
    {
        var headers = context.Response.Headers;
        headers.CacheControl = "no-cache";
        headers.XContentTypeOptions = "nosniff";
        headers["Referrer-Policy"] = "no-referrer";
        headers.XFrameOptions = "DENY";
        headers.ContentSecurityPolicy = "default-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; "
            + "frame-ancestors 'none'; base-uri 'none'; form-action 'self'; object-src 'none'";
        var stream = typeof(ReceiverServer).Assembly.GetManifestResourceStream(resource);
        return stream is null ? Error("not found", StatusCodes.Status404NotFound) : Results.Stream(stream, contentType);
    }

    // GET /ping for a browser also says which peer it is, and keeps its cookie from expiring while it's used.
    IResult WebPing(HttpContext context, string peer)
    {
        if (context.Request.Cookies.TryGetValue(WebCookie, out var token) && token is { Length: > 0 })
            SetWebCookie(context, token);
        return Results.Json(new
        {
            name = Settings.DeviceName, version = Version, platform = OwnDevice.Platform.ToWire(), protocol = 2, you = peer,
        });
    }

    // Media a browser may show in place (View) rather than download. Never SVG or HTML, which could run script on
    // this origin.
    static readonly HashSet<string> InlineTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif", "video/mp4", "video/quicktime", "video/x-m4v",
    };
}
