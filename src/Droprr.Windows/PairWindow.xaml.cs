using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows;
using System.Windows.Media.Imaging;
using QRCoder;

namespace Droprr;

// Shows the pairing QR code described in docs/PROTOCOL.md ("Pairing QR"). The code holds the token, so it's
// only ever built in memory while this window is open: never written to disk or logged.
public partial class PairWindow : Window
{
    public PairWindow(AppSettings settings)
    {
        InitializeComponent();
        Icon = AppIcon.ImageSource;

        var host = TailscaleNetwork.FindAddresses().FirstOrDefault()?.ToString();
        if (host is null)
        {
            Error.Text = "Tailscale isn't connected on this PC, so a phone couldn't reach it. Connect Tailscale and try again.";
            Error.Visibility = Visibility.Visible;
            return;
        }

        var dns = MagicDnsName();
        Code.Source = Render(PairingUri(settings, host, dns));
        Details.Text = $"{settings.DeviceName} · {dns ?? host} · port {settings.Port}";

        if (Application.Current is App app)
        {
            app.DevicePaired += OnPaired;
            Closed += (_, _) => app.DevicePaired -= OnPaired;
        }
    }

    // The phone called POST /pair: confirm, and drop the code (it holds the token) before closing.
    void OnPaired(Peer peer)
    {
        Code.Source = null;
        CodePanel.Visibility = Visibility.Collapsed;
        ScanHint.Visibility = Visibility.Collapsed;
        PairedPanel.Visibility = Visibility.Visible;
        PairedText.Text = $"Paired with {peer.Name} ✓";
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2.5) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            Close();
        };
        timer.Start();
    }

    public static string PairingUri(AppSettings settings, string host, string? dns)
    {
        var fields = new List<(string Key, string Value)>
        {
            ("v", "1"),
            ("name", settings.DeviceName),
            ("host", host),
            ("port", settings.Port.ToString()),
            ("token", settings.Token),
            ("platform", "windows"),
        };
        if (!string.IsNullOrEmpty(dns))
            fields.Add(("dns", dns));
        // Uri.EscapeDataString percent-encodes everything outside RFC 3986's unreserved characters.
        return "droprr://pair?" + string.Join("&", fields.Select(f => $"{f.Key}={Uri.EscapeDataString(f.Value)}"));
    }

    static BitmapImage Render(string text)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(text, QRCodeGenerator.ECCLevel.M);
        var png = new PngByteQRCode(data).GetGraphic(10);
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = new MemoryStream(png);
        image.EndInit();
        image.Freeze();
        return image;
    }

    // This PC's MagicDNS name from `tailscale status --json`, or null if Tailscale's CLI isn't available.
    static string? MagicDnsName()
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
