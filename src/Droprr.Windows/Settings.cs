using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Droprr;

public sealed class Peer
{
    public string Name { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = AppSettings.DefaultPort;

    // The receiving device's token. Empty means "same as this device's token".
    public string Token { get; set; } = "";

    // "windows", "macos", or "ios", as reported by the peer's /ping. Empty means not known yet.
    public string Platform { get; set; } = "";

    // Phones can't listen, so sends to them are queued in the Outbox until they check in.
    [JsonIgnore]
    public bool IsPhone
    {
        get => Platform.Equals("ios", StringComparison.OrdinalIgnoreCase);
        set => Platform = value ? "ios" : (IsPhone ? "" : Platform);
    }

    [JsonIgnore]
    public string Note => IsPhone ? "Queued until your phone checks in" : Host;
}

public sealed class AppSettings
{
    public const int DefaultPort = 53318;

    public string DeviceName { get; set; } = Environment.MachineName;
    public int Port { get; set; } = DefaultPort;
    public string Token { get; set; } = "";
    public string? SaveFolder { get; set; }
    public List<Peer> Peers { get; set; } = new();

    public Peer? FindPeer(string name) =>
        Peers.Find(p => p.Name.Trim().Equals(name.Trim(), StringComparison.OrdinalIgnoreCase));

    public string ResolveSaveFolder() => string.IsNullOrWhiteSpace(SaveFolder)
        ? Path.Combine(KnownFolders.Downloads, "Droprr")
        : Environment.ExpandEnvironmentVariables(SaveFolder);
}

static class SettingsStore
{
    static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static string Folder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Droprr");

    public static string FilePath => Path.Combine(Folder, "settings.json");

    // Creates the file with a fresh random token on first run.
    public static AppSettings Load()
    {
        var exists = File.Exists(FilePath);
        var settings = exists
            ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), Options) ?? new AppSettings()
            : new AppSettings();

        var changed = !exists;
        if (string.IsNullOrWhiteSpace(settings.Token))
        {
            settings.Token = NewToken();
            changed = true;
        }
        if (changed)
            Save(settings);
        return settings;
    }

    public static void Save(AppSettings settings)
    {
        Directory.CreateDirectory(Folder);
        lock (Gate)
            File.WriteAllText(FilePath, JsonSerializer.Serialize(settings, Options));
    }

    // Applies a small change to the file on disk, so changes made by the other Droprr process or by
    // hand aren't overwritten. Returns the updated settings.
    public static AppSettings Update(Action<AppSettings> change)
    {
        lock (Gate)
        {
            var settings = Load();
            change(settings);
            Save(settings);
            return settings;
        }
    }

    static readonly object Gate = new();

    static string NewToken() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
        .TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
