using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace Droprr;

// The local API (docs/PROTOCOL.md, "Local API"): tools on this computer, such as the Droprr MCP server for AI
// assistants, list this PC's devices and send to them through the app. It answers only this PC, and only with
// the local token, which works for nothing else. This file is the part that needs no app: the request's shape,
// the answers, and the connection file. ReceiverServer.Local.cs serves it.
public static class LocalApi
{
    // Where the app writes its address and the local token, next to settings.json. Readable only by this
    // Windows account, like the rest of %APPDATA%.
    public const string ConnectionFileName = "local-api.json";

    // A JSON text item may be up to 16 MB (docs/PROTOCOL.md, "Errors"); the rest of the request is small.
    public const long MaxSendBody = 17 * 1024 * 1024;

    public const string SendShape = """{"to": "<device name>", "text": "...", "files": ["<absolute path>"]}""";

    public sealed record SendRequest(Peer Peer, string Text, IReadOnlyList<string> Files);

    public sealed record Failure(int Status, string Error);

    // Writes the connection file the MCP server reads: the plain HTTP address on loopback and the local token.
    public static void WriteConnectionFile(string folder, int port, string token)
    {
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, ConnectionFileName);
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(new { url = $"http://127.0.0.1:{port}", token }));
        File.Move(temp, path, overwrite: true);
    }

    // GET /local/devices: this device's name, and each device it knows. "kind" says how a send reaches it:
    // a computer directly, a phone or browser usually through its queue ("waiting" items so far).
    public static object Devices(string ownName, IEnumerable<Peer> peers, Func<Peer, int> waiting) => new
    {
        ok = true,
        name = ownName,
        devices = peers.Select(peer => new
        {
            name = peer.Name,
            platform = peer.Platform == DevicePlatform.Unknown ? "unknown" : peer.Platform.ToWire(),
            kind = peer.IsBrowser ? "browser" : peer.IsPhone ? "phone" : "computer",
            paired = peer.IsPaired,
            waiting = peer.IsPhone ? waiting(peer) : 0,
        }).ToList(),
    };

    // POST /local/send's body, {"to": "<device name>", "text": "...", "files": ["<absolute path>", ...]}, checked
    // against this PC's devices and files. Text that is a single http(s) link is sent as a link.
    public static (SendRequest? Request, Failure? Failure) ParseSend(JsonElement body, PeerList peers)
    {
        if (body.ValueKind != JsonValueKind.Object)
            return Fail(400, $"body must be JSON: {SendShape}");
        if (!body.TryGetProperty("to", out var to) || to.ValueKind != JsonValueKind.String || to.GetString()!.Trim().Length == 0)
            return Fail(400, "missing \"to\": the name of the device to send to");
        var name = to.GetString()!.Trim();
        if (peers.FindByName(name) is not { } peer)
            return Fail(404, peers.Count == 0
                ? $"no device named \"{name}\": this computer has no devices yet. Pair one in Droprr first."
                : $"no device named \"{name}\". Devices: {string.Join(", ", peers.Select(p => p.Name))}");
        if (!peer.IsPaired)
            return Fail(409, $"{peer.Name} isn't paired. Scan its code or enter its token in Droprr's Settings.");

        var text = "";
        if (body.TryGetProperty("text", out var textValue) && textValue.ValueKind != JsonValueKind.Null)
        {
            if (textValue.ValueKind != JsonValueKind.String)
                return Fail(400, "\"text\" must be a string");
            text = textValue.GetString()!.Trim();
        }

        var files = new List<string>();
        if (body.TryGetProperty("files", out var filesValue) && filesValue.ValueKind != JsonValueKind.Null)
        {
            if (filesValue.ValueKind != JsonValueKind.Array)
                return Fail(400, "\"files\" must be an array of absolute paths");
            foreach (var file in filesValue.EnumerateArray())
            {
                if (file.ValueKind != JsonValueKind.String || !Path.IsPathFullyQualified(file.GetString()!))
                    return Fail(400, "each of \"files\" must be an absolute path");
                var path = file.GetString()!;
                if (Directory.Exists(path))
                    return Fail(400, $"{path} is a folder. Only files can be sent.");
                if (!File.Exists(path))
                    return Fail(400, $"no file at {path}");
                files.Add(path);
            }
        }

        if (text.Length == 0 && files.Count == 0)
            return Fail(400, "nothing to send: give \"text\", \"files\", or both");
        return (new SendRequest(peer, text, files), null);
    }

    static (SendRequest?, Failure?) Fail(int status, string error) => (null, new Failure(status, error));
}
