using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace Droprr;

static class TailscaleNetwork
{
    // Tailscale hands out IPv4 addresses from the CGNAT range 100.64.0.0/10.
    public static IReadOnlyList<IPAddress> FindAddresses() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(n => n.OperationalStatus == OperationalStatus.Up)
        .SelectMany(n => n.GetIPProperties().UnicastAddresses)
        .Select(u => u.Address)
        .Where(a => a.AddressFamily == AddressFamily.InterNetwork && LanNetwork.IsTailscale(a))
        .Distinct()
        .ToList();

    // How a peer reaches this PC over Tailscale: its MagicDNS name, else its Tailscale address, else null.
    public static string? OwnHost() => MagicDnsName() ?? FindAddresses().FirstOrDefault()?.ToString();

    // This PC's MagicDNS name from `tailscale status --json`, or null if Tailscale's CLI isn't available.
    public static string? MagicDnsName()
    {
        var cli = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Tailscale", "tailscale.exe"),
            "tailscale.exe",
        }.FirstOrDefault(p => !Path.IsPathRooted(p) || File.Exists(p));
        try
        {
            using var process = Process.Start(new ProcessStartInfo(cli!, "status --json")
            {
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            if (process is null)
                return null;
            var output = process.StandardOutput.ReadToEndAsync();
            if (!process.WaitForExit(3000) || !output.Wait(1000))
                return null;
            using var json = JsonDocument.Parse(output.Result);
            var name = json.RootElement.GetProperty("Self").GetProperty("DNSName").GetString()?.TrimEnd('.');
            return string.IsNullOrEmpty(name) ? null : name;
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or JsonException or KeyNotFoundException or InvalidOperationException)
        {
            return null;
        }
    }
}
