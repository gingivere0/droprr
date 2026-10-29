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

    // Local network (protocol 2): the peer's device id, its pinned certificate fingerprint, its HTTPS port, its
    // last known LAN addresses ("host:port"), and the path the last send took ("lan" or "tailscale").
    public string Id { get; set; } = "";
    public string Fingerprint { get; set; } = "";
    public int TlsPort { get; set; }
    public List<string> Lan { get; set; } = new();
    public string LastPath { get; set; } = "";

    [JsonIgnore]
    public string PathLabel => LastPath switch
    {
        "lan" => "Wi-Fi",
        "tailscale" => "Tailscale",
        _ => "",
    };

    // Phones can't listen, so sends to them are queued in the Outbox until they check in. Browsers ("web", from
    // Browser access) are queued the same way.
    [JsonIgnore]
    public bool IsPhone
    {
        get => Platform.Equals("ios", StringComparison.OrdinalIgnoreCase) || IsBrowser;
        set => Platform = value ? (IsBrowser ? Platform : "ios") : (IsPhone ? "" : Platform);
    }

    [JsonIgnore]
    public bool IsBrowser => Platform.Equals("web", StringComparison.OrdinalIgnoreCase);

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
    public string Note => !IsPaired ? "Missing Token"
        : !IsPhone ? Address
        : Waiting > 0 ? $"{(IsBrowser ? "Browser" : "iPhone")} · {Waiting} waiting"
        : IsBrowser ? "Browser"
        : "iPhone";

    // Where the device is: its Tailscale host, or for a device paired over Wi-Fi, its Wi-Fi address. Never an
    // empty host.
    [JsonIgnore]
    public string Address => Host.Length > 0 ? Host : LanAddress ?? "Wi-Fi";

    // The first LAN address without its port ("192.168.1.20" from "192.168.1.20:53319", "fe80::1" from
    // "[fe80::1]:53319"), or null.
    [JsonIgnore]
    public string? LanAddress => Lan.Count == 0 ? null
        : Lan[0].StartsWith('[') ? Lan[0][1..Math.Max(1, Lan[0].IndexOf(']'))]
        : Lan[0].LastIndexOf(':') is var colon and > 0 ? Lan[0][..colon]
        : Lan[0];
}

// The Send window's last device tile, which opens the one code (Pair a phone).
public sealed class AddDeviceTile
{
    public static readonly AddDeviceTile Instance = new();

    public string Name => "Add a device";
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

    // The color theme's id (ThemeCatalog); the default theme in tokens.json (Sage) unless chosen otherwise.
    public string Theme { get; set; } = ThemeCatalog.DefaultId;

    // The window style's id (LookCatalog): "material", "clay", "spatial", or "atelier", as on the Mac and iPhone.
    // Atelier unless chosen otherwise.
    public string Style { get; set; } = LookCatalog.DefaultId;

    // "system" follows Windows' light or dark setting; "light" or "dark" overrides it. Light unless chosen otherwise.
    public string Mode { get; set; } = AppTheme.LightMode;

    // A Start menu shortcut, which is what makes Droprr show up in Windows Search.
    public bool AddToStartMenu { get; set; } = true;

    // Send and receive over the local network too (docs/PROTOCOL.md, "Local network (LAN) transport").
    public bool LocalNetwork { get; set; } = true;

    // This PC's device id and its TLS certificate (base64 PKCS #12, stored encrypted). Made on first run.
    public string DeviceId { get; set; } = "";
    public string Identity { get; set; } = "";

    // Browser access over the internet: this PC's secret key for its room on the relay (stored encrypted), and the
    // relay and website to use, when not the defaults (BrowserHost).
    public string HostKey { get; set; } = "";
    public string? RelayUrl { get; set; }
    public string? SiteUrl { get; set; }

    public List<Peer> Peers { get; set; } = new();

    // `name`, or "name (2)", "name (3)", and so on if a peer already has it.
    public string UniqueName(string name)
    {
        name = name.Trim();
        var unique = name;
        for (var i = 2; FindPeer(unique) is not null; i++)
            unique = $"{name} ({i})";
        return unique;
    }

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
        var settings = exists ? Read(FilePath) : new AppSettings();

        var changed = !exists | RevealTokens(settings);
        if (string.IsNullOrWhiteSpace(settings.Token))
        {
            settings.Token = NewToken();
            changed = true;
        }
        if (string.IsNullOrWhiteSpace(settings.DeviceId))
        {
            settings.DeviceId = DeviceIdentity.NewId();
            changed = true;
        }
        if (string.IsNullOrWhiteSpace(settings.HostKey))
        {
            settings.HostKey = BrowserHost.NewHostKey();
            changed = true;
        }
        if (string.IsNullOrWhiteSpace(settings.Identity))
        {
            settings.Identity = DeviceIdentity.NewCertificate(settings.DeviceId);
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
        stored.Identity = Hide(stored.Identity);
        stored.HostKey = Hide(stored.HostKey);
        foreach (var peer in stored.Peers)
        {
            peer.Token = Hide(peer.Token);
            peer.AcceptToken = Hide(peer.AcceptToken);
        }
        // Written to a temporary file and swapped in, keeping the previous file as a backup, so a crash or power cut
        // mid-write never leaves a half-written settings.json.
        var temp = FilePath + ".tmp";
        lock (Gate)
        {
            File.WriteAllText(temp, JsonSerializer.Serialize(stored, Options));
            if (File.Exists(FilePath))
                Retry(() => File.Replace(temp, FilePath, BackupPath, ignoreMetadataErrors: true));
            else
                File.Move(temp, FilePath);
        }
    }

    static string BackupPath => FilePath + ".bak";

    // The settings file, or its backup if the file can't be parsed. Another Droprr process writing at the same
    // moment can briefly hold the file, so reading retries.
    static AppSettings Read(string path)
    {
        string text = "";
        Retry(() => text = File.ReadAllText(path));
        try
        {
            return JsonSerializer.Deserialize<AppSettings>(text, Options) ?? new AppSettings();
        }
        catch (JsonException) when (File.Exists(BackupPath))
        {
            return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(BackupPath), Options) ?? new AppSettings();
        }
    }

    static void Retry(Action action)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                action();
                return;
            }
            catch (IOException) when (attempt < 10)
            {
                System.Threading.Thread.Sleep(50);
            }
        }
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
        settings.Identity = Reveal(settings.Identity, ref plain);
        settings.HostKey = Reveal(settings.HostKey, ref plain);
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
