using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Droprr;

public sealed class Peer
{
    public string Name { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = AppSettings.DefaultPort;

    // The token this PC sends when calling the peer: the device token it got from pairing, or one entered by
    // hand. Empty for phones (they can't be called) and for computers that aren't paired yet. Never this PC's
    // own main token.
    public string Token { get; set; } = "";

    // The device token this PC minted for the peer during POST /pair and accepts from it. Re-pairing
    // replaces it; removing the peer revokes it.
    public string AcceptToken { get; set; } = "";

    // "windows", "macos", or "ios", from pairing or the peer's /ping. Empty means not known yet.
    public string Platform { get; set; } = "";

    // Phones can't listen, so sends to them are queued in the Outbox until they check in.
    [JsonIgnore]
    public bool IsPhone
    {
        get => Platform.Equals("ios", StringComparison.OrdinalIgnoreCase);
        set => Platform = value ? "ios" : (IsPhone ? "" : Platform);
    }

    // Items in this peer's outbox, filled in by whoever shows the peer.
    [JsonIgnore]
    public int Waiting { get; set; }

    [JsonIgnore]
    public bool HasWaiting => Waiting > 0;

    [JsonIgnore]
    public string WaitingLabel => $"{Waiting} waiting";

    [JsonIgnore]
    public string ClearWaitingLabel => $"Clear {Waiting} item{(Waiting == 1 ? "" : "s")} waiting for {Name}";

    // A computer needs a token to be sent to; phones are queued instead.
    [JsonIgnore]
    public bool IsPaired => IsPhone || Token.Length > 0;

    [JsonIgnore]
    public string Note => !IsPaired ? "Not paired: scan its code or enter its token"
        : !IsPhone ? Host
        : Waiting > 0 ? $"iPhone · {Waiting} waiting"
        : "iPhone";
}

public sealed class AppSettings
{
    public const int DefaultPort = 53318;

    public string DeviceName { get; set; } = Environment.MachineName;
    public int Port { get; set; } = DefaultPort;
    // The main token: in the pairing QR and Settings. Never sent to a peer.
    public string Token { get; set; } = "";
    public string? SaveFolder { get; set; }

    // Copies received text and links to the clipboard.
    public bool CopyTextToClipboard { get; set; } = true;

    // Also copies received files (and images as pictures).
    public bool CopyFilesToClipboard { get; set; }

    // The color theme's id (ThemeCatalog); Graphite & Lime unless chosen otherwise.
    public string Theme { get; set; } = ThemeCatalog.DefaultId;

    // A Start menu shortcut, which is what makes Droprr show up in Windows Search.
    public bool AddToStartMenu { get; set; } = true;

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

    // Creates the file with a fresh random token on first run. Tokens are stored encrypted for the
    // signed-in Windows user (DPAPI); plain tokens from older versions are encrypted on first load.
    public static AppSettings Load()
    {
        var exists = File.Exists(FilePath);
        var settings = exists
            ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), Options) ?? new AppSettings()
            : new AppSettings();

        var changed = !exists | RevealTokens(settings);
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
        var stored = JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(settings, Options), Options)!;
        stored.Token = Hide(stored.Token);
        foreach (var peer in stored.Peers)
        {
            peer.Token = Hide(peer.Token);
            peer.AcceptToken = Hide(peer.AcceptToken);
        }
        lock (Gate)
            File.WriteAllText(FilePath, JsonSerializer.Serialize(stored, Options));
    }

    const string ProtectedPrefix = "dpapi:";
    static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Droprr settings");

    static string Hide(string token) => token.Length == 0
        ? ""
        : ProtectedPrefix + Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(token), Entropy, DataProtectionScope.CurrentUser));

    // Decrypts every token in place. Returns true if any was still plain text, so the caller saves it encrypted.
    static bool RevealTokens(AppSettings settings)
    {
        var plain = false;
        settings.Token = Reveal(settings.Token, ref plain);
        foreach (var peer in settings.Peers)
        {
            peer.Token = Reveal(peer.Token, ref plain);
            peer.AcceptToken = Reveal(peer.AcceptToken, ref plain);
        }
        return plain;
    }

    static string Reveal(string? value, ref bool plain)
    {
        if (string.IsNullOrEmpty(value))
            return "";
        if (!value.StartsWith(ProtectedPrefix, StringComparison.Ordinal))
        {
            plain = true;
            return value;
        }
        try
        {
            return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(value[ProtectedPrefix.Length..]), Entropy, DataProtectionScope.CurrentUser));
        }
        catch (Exception ex) when (ex is CryptographicException or FormatException)
        {
            // Encrypted by another Windows user or PC: unusable here, so treat it as missing.
            return "";
        }
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

    // 32 random bytes, base64url without padding: the main token and every device token.
    public static string NewToken() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
        .TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
