using System.Collections.Generic;

namespace Droprr;

// What this PC tells other devices about itself, in one place: /ping, the /pair request and response, LAN
// advertisements, and the pairing codes all describe it the same way.
static class OwnDevice
{
    public const DevicePlatform Platform = DevicePlatform.Windows;

    // Name, platform, Tailscale host, ports, the token minted for the other device, and the local network identity
    // and addresses (only while HTTPS for the local network is listening).
    public static Dictionary<string, object?> PairFields(AppSettings settings, string? host, string acceptToken, bool lanListening) => new()
    {
        ["id"] = settings.DeviceId,
        ["name"] = settings.DeviceName,
        ["platform"] = Platform.ToWire(),
        ["host"] = host,
        ["port"] = settings.Port,
        ["token"] = acceptToken,
        ["fp"] = DeviceIdentity.Fingerprint(settings),
        ["tlsPort"] = lanListening ? LanNetwork.TlsPort(settings.Port) : null,
        ["lan"] = lanListening ? LanNetwork.OwnEndpoints(settings.Port) : new List<string>(),
    };
}
