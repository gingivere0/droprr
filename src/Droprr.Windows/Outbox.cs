using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Droprr;

public sealed record OutboxItem(string Id, string Peer, string Type, string Name, long Size, string? Content, DateTime Created);

// Items queued for phones, which pull them through the /inbox endpoints (docs/PROTOCOL.md, "Inbox").
// Lives in %APPDATA%\Droprr\outbox\<peer>\ as <id>.json metadata plus <id>.data for files, so the
// Send To process and the tray process can share it.
static class Outbox
{
    public static readonly TimeSpan Lifetime = TimeSpan.FromDays(7);

    static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public static string Root => Path.Combine(SettingsStore.Folder, "outbox");

    static string PeerFolder(string peer) => Path.Combine(Root, FileNames.Sanitize(peer.Trim().ToLowerInvariant()));

    public static async Task<OutboxItem> EnqueueFileAsync(string peer, string sourcePath, IProgress<long>? progress = null, CancellationToken cancel = default)
    {
        var folder = PeerFolder(peer);
        Directory.CreateDirectory(folder);
        var id = Guid.NewGuid().ToString();
        var dataPath = Path.Combine(folder, id + ".data");
        try
        {
            await using var source = File.OpenRead(sourcePath);
            await using var target = File.Create(dataPath);
            await new ProgressStream(source, n => progress?.Report(n)).CopyToAsync(target, cancel);
        }
        catch
        {
            TryDelete(dataPath);
            throw;
        }

        var item = new OutboxItem(id, peer, "file", Path.GetFileName(sourcePath), new FileInfo(dataPath).Length, null, DateTime.UtcNow);
        WriteMetadata(folder, item);
        return item;
    }

    public static OutboxItem EnqueueText(string peer, string type, string content)
    {
        var folder = PeerFolder(peer);
        Directory.CreateDirectory(folder);
        var item = new OutboxItem(Guid.NewGuid().ToString(), peer, type, type == "url" ? "Link" : "Text",
            Encoding.UTF8.GetByteCount(content), content, DateTime.UtcNow);
        WriteMetadata(folder, item);
        return item;
    }

    // Oldest first, after dropping anything past its lifetime.
    public static IReadOnlyList<OutboxItem> List(string peer)
    {
        var folder = PeerFolder(peer);
        if (!Directory.Exists(folder))
            return [];
        return Directory.EnumerateFiles(folder, "*.json")
            .Select(ReadLive)
            .OfType<OutboxItem>()
            .OrderBy(i => i.Created)
            .ThenBy(i => i.Id, StringComparer.Ordinal)
            .ToList();
    }

    public static (OutboxItem Item, string DataPath)? Find(string id)
    {
        if (!Guid.TryParse(id, out var guid) || !Directory.Exists(Root))
            return null;
        id = guid.ToString();
        foreach (var folder in Directory.EnumerateDirectories(Root))
        {
            var metadata = Path.Combine(folder, id + ".json");
            if (File.Exists(metadata) && ReadLive(metadata) is { } item)
                return (item, Path.Combine(folder, id + ".data"));
        }
        return null;
    }

    public static bool Delete(string id)
    {
        if (Find(id) is not { } found)
            return false;
        TryDelete(Path.ChangeExtension(found.DataPath, ".json"));
        TryDelete(found.DataPath);
        return true;
    }

    public static void PurgeExpired()
    {
        if (!Directory.Exists(Root))
            return;
        foreach (var folder in Directory.EnumerateDirectories(Root))
        {
            foreach (var metadata in Directory.EnumerateFiles(folder, "*.json"))
                ReadLive(metadata);
            // Data left behind by an interrupted copy has no metadata.
            foreach (var data in Directory.EnumerateFiles(folder, "*.data"))
            {
                if (!File.Exists(Path.ChangeExtension(data, ".json")) && File.GetLastWriteTimeUtc(data) < DateTime.UtcNow.AddDays(-1))
                    TryDelete(data);
            }
        }
    }

    public static IReadOnlyList<(string Peer, int Count)> PendingByPeer()
    {
        if (!Directory.Exists(Root))
            return [];
        return Directory.EnumerateDirectories(Root)
            .SelectMany(folder => Directory.EnumerateFiles(folder, "*.json"))
            .Select(ReadLive)
            .OfType<OutboxItem>()
            .GroupBy(i => i.Peer, StringComparer.OrdinalIgnoreCase)
            .Select(g => (g.First().Peer, g.Count()))
            .ToList();
    }

    // Reads one item, deleting it instead if it has expired or can't be read.
    static OutboxItem? ReadLive(string metadataPath)
    {
        OutboxItem? item = null;
        try
        {
            item = JsonSerializer.Deserialize<OutboxItem>(File.ReadAllText(metadataPath), Json);
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            if (ex is IOException && !File.Exists(metadataPath))
                return null;
        }
        if (item is not null && item.Created.ToUniversalTime() + Lifetime > DateTime.UtcNow)
            return item;

        TryDelete(metadataPath);
        TryDelete(Path.ChangeExtension(metadataPath, ".data"));
        return null;
    }

    static void WriteMetadata(string folder, OutboxItem item)
    {
        var temporary = Path.Combine(folder, item.Id + ".tmp");
        File.WriteAllText(temporary, JsonSerializer.Serialize(item, Json));
        File.Move(temporary, Path.Combine(folder, item.Id + ".json"), overwrite: true);
    }

    static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}
