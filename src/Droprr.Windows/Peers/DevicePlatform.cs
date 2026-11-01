using System;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Droprr;

// What kind of device a peer is. On the wire and in settings.json it's "windows", "macos", "ios", or "web"
// (docs/PROTOCOL.md); anything else, or nothing, is Unknown.
[JsonConverter(typeof(DevicePlatformJsonConverter))]
public enum DevicePlatform { Unknown, Windows, MacOS, IOS, Web }

public static class DevicePlatforms
{
    public static string ToWire(this DevicePlatform platform) => platform switch
    {
        DevicePlatform.Windows => "windows",
        DevicePlatform.MacOS => "macos",
        DevicePlatform.IOS => "ios",
        DevicePlatform.Web => "web",
        _ => "",
    };

    public static DevicePlatform FromWire(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        "windows" => DevicePlatform.Windows,
        "macos" => DevicePlatform.MacOS,
        "ios" => DevicePlatform.IOS,
        "web" => DevicePlatform.Web,
        _ => DevicePlatform.Unknown,
    };

    // The platforms a device may pair as with POST /pair or LAN pairing. Browsers connect with Browser access instead.
    public static bool CanPair(this DevicePlatform platform) =>
        platform is DevicePlatform.Windows or DevicePlatform.MacOS or DevicePlatform.IOS;

    // What Settings' Test calls it: "Windows PC", "Mac", "iPhone", or "Browser".
    public static string Label(this DevicePlatform platform) => platform switch
    {
        DevicePlatform.Windows => "Windows PC",
        DevicePlatform.MacOS => "Mac",
        DevicePlatform.IOS => "iPhone",
        DevicePlatform.Web => "Browser",
        _ => "Droprr",
    };
}

sealed class DevicePlatformJsonConverter : JsonConverter<DevicePlatform>
{
    public override DevicePlatform Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.String ? DevicePlatforms.FromWire(reader.GetString()) : DevicePlatform.Unknown;

    public override void Write(Utf8JsonWriter writer, DevicePlatform value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToWire());
}

// How a send reached a peer. Stored as "lan" or "tailscale" ("" before the first send).
[JsonConverter(typeof(SendPathJsonConverter))]
public enum SendPath { None, Lan, Tailscale }

public static class SendPaths
{
    public static string Label(this SendPath path) => path switch
    {
        SendPath.Lan => "Wi-Fi",
        SendPath.Tailscale => "Tailscale",
        _ => "",
    };
}

sealed class SendPathJsonConverter : JsonConverter<SendPath>
{
    public override SendPath Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.TokenType == JsonTokenType.String
            ? reader.GetString() switch { "lan" => SendPath.Lan, "tailscale" => SendPath.Tailscale, _ => SendPath.None }
            : SendPath.None;

    public override void Write(Utf8JsonWriter writer, SendPath value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value switch { SendPath.Lan => "lan", SendPath.Tailscale => "tailscale", _ => "" });
}
