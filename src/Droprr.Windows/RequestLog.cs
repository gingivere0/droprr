using System;
using System.IO;
using Microsoft.AspNetCore.Http;

namespace Droprr;

// One line per request in %APPDATA%\Droprr\requests.log, for diagnosing clients like iOS Shortcuts.
// Never logs headers or bodies, so tokens and content stay out of it.
static class RequestLog
{
    const long MaxBytes = 256 * 1024;
    static readonly object Gate = new();

    static string FilePath => Path.Combine(SettingsStore.Folder, "requests.log");

    public static void Write(HttpContext context)
    {
        var request = context.Request;
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {request.Method} {request.Path} -> {context.Response.StatusCode} " +
                   $"type={request.ContentType ?? "-"} length={request.ContentLength?.ToString() ?? "-"} " +
                   $"agent={request.Headers.UserAgent}{Environment.NewLine}";
        try
        {
            lock (Gate)
            {
                var file = new FileInfo(FilePath);
                if (file.Exists && file.Length > MaxBytes)
                    file.Delete();
                File.AppendAllText(FilePath, line);
            }
        }
        catch (IOException)
        {
            // Logging is best effort.
        }
    }
}
