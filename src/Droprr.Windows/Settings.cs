using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json;

namespace Droprr;

public sealed class Peer
{
    public string Name { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = AppSettings.DefaultPort;

    // The receiving device's token. Empty means "same as this device's token".
    public string Token { get; set; } = "";
}

public sealed class AppSettings
{
    public const int DefaultPort = 53318;

    public string DeviceName { get; set; } = Environment.MachineName;
    public int Port { get; set; } = DefaultPort;
    public string Token { get; set; } = "";
    public string? SaveFolder { get; set; }
    public List<Peer> Peers { get; set; } = new();

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
        File.WriteAllText(FilePath, JsonSerializer.Serialize(settings, Options));
    }

    static string NewToken() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
        .TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
