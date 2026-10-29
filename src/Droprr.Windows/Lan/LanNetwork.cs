using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace Droprr;

// Which addresses the local network transport (docs/PROTOCOL.md, "Local network (LAN) transport") talks to, and
// which of this PC's networks count as private.
static class LanNetwork
{
    public const string ServiceType = "_droprr._tcp";

    // The HTTPS port is always the HTTP port + 1.
    public static int TlsPort(int httpPort) => httpPort + 1;

    // Loopback, Tailscale, and private LAN ranges: who may connect to the HTTPS port.
    public static bool IsAllowedRemote(IPAddress? address)
    {
        if (address is null)
            return false;
        if (address.IsIPv4MappedToIPv6)
            address = address.MapToIPv4();
        return IPAddress.IsLoopback(address) || IsTailscale(address) || IsPrivateLan(address);
    }

    public static bool IsTailscale(IPAddress address)
    {
        var b = address.GetAddressBytes();
        return address.AddressFamily == AddressFamily.InterNetwork
            ? b[0] == 100 && (b[1] & 0xC0) == 0x40
            : b.Length == 16 && b[0] == 0xFD && b[1] == 0x7A && b[2] == 0x11 && b[3] == 0x5C && b[4] == 0xA1 && b[5] == 0xE0;
    }

    // 10/8, 172.16/12, 192.168/16, fe80::/10, and fd00::/8.
    public static bool IsPrivateLan(IPAddress address)
    {
        var b = address.GetAddressBytes();
        if (address.AddressFamily == AddressFamily.InterNetwork)
            return b[0] == 10 || (b[0] == 172 && (b[1] & 0xF0) == 16) || (b[0] == 192 && b[1] == 168);
        return b.Length == 16 && ((b[0] == 0xFE && (b[1] & 0xC0) == 0x80) || b[0] == 0xFD);
    }

    // This PC's private LAN IPv4 addresses on networks Windows doesn't treat as Public, with the interface each
    // is on. Public networks (a café, an airport) are left out: Droprr doesn't advertise or listen there. So are
    // virtual adapters (Hyper-V, VM, and VPN switches), whose addresses other devices can't reach. Adapters with a
    // default gateway (the real Wi-Fi or Ethernet) come first.
    public static IReadOnlyList<(IPAddress Address, int InterfaceIndex)> LocalAddresses()
    {
        var publicAdapters = PublicAdapterIds();
        var result = new List<(IPAddress Address, int Index, bool Gateway)>();
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up || nic.NetworkInterfaceType == NetworkInterfaceType.Loopback
                || publicAdapters.Contains(nic.Id.Trim('{', '}').ToLowerInvariant()) || IsVirtual(nic))
                continue;
            var properties = nic.GetIPProperties();
            if (IPv4Index(properties) is not { } index)
                continue;
            var gateway = properties.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any));
            foreach (var unicast in properties.UnicastAddresses)
            {
                if (unicast.Address.AddressFamily == AddressFamily.InterNetwork && IsPrivateLan(unicast.Address))
                    result.Add((unicast.Address, index, gateway));
            }
        }
        return result.OrderBy(r => r.Gateway ? 0 : 1).Select(r => (r.Address, r.Index)).ToList();
    }

    static readonly string[] VirtualNames = ["Hyper-V", "vEthernet", "Virtual", "VMware", "VirtualBox", "TAP-", "WireGuard", "Tailscale", "VPN", "Wintun"];

    static bool IsVirtual(NetworkInterface nic) =>
        nic.NetworkInterfaceType is NetworkInterfaceType.Tunnel or NetworkInterfaceType.Ppp
        || VirtualNames.Any(v => nic.Description.Contains(v, StringComparison.OrdinalIgnoreCase) || nic.Name.Contains(v, StringComparison.OrdinalIgnoreCase));

    // Throws for adapters without IPv4 (such as IPv6-only tunnels) rather than returning null.
    static int? IPv4Index(IPInterfaceProperties properties)
    {
        try
        {
            return properties.GetIPv4Properties()?.Index;
        }
        catch (NetworkInformationException)
        {
            return null;
        }
    }

    // Adapters on networks whose category is Public, from the Network List Manager. If it can't be read, none
    // are excluded; the firewall rule (Private profile only) still keeps Public networks out.
    static HashSet<string> PublicAdapterIds()
    {
        var ids = new HashSet<string>();
        try
        {
            dynamic manager = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("DCB00C01-570F-4A9B-8D69-199FDBA5723B"))!)!;
            foreach (dynamic connection in manager.GetNetworkConnections())
            {
                if ((int)connection.GetNetwork().GetCategory() == 0 /* NLM_NETWORK_CATEGORY_PUBLIC */)
                    ids.Add(((Guid)connection.GetAdapterId()).ToString().ToLowerInvariant());
            }
        }
        catch (Exception ex)
        {
            RequestLog.Note($"local network: couldn't read network categories: {ex.Message.ReplaceLineEndings(" ")}");
        }
        return ids;
    }
}
