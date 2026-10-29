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
public partial class PairWindow : Wpf.Ui.Controls.FluentWindow
{
    readonly AppSettings _settings;

    public PairWindow(AppSettings settings)
    {
        InitializeComponent();
        AppTheme.Setup(this, AppTitleBar);
        _settings = settings;
        ShowCode();

        if (Application.Current is App app)
        {
            app.DevicePaired += OnPaired;
            Closed += (_, _) => app.DevicePaired -= OnPaired;
        }
    }

    // Tailscale when it's connected; otherwise this PC's first private LAN address, which the phone reaches over
    // HTTPS pinned to the code's fingerprint (the same as the Mac). Wi-Fi needs the local network listener, so
    // when it isn't running, the window says why and offers the firewall fix instead of a code that can't connect.
    void ShowCode()
    {
        var lanListening = Application.Current is App { LanListening: true };
        var tailscale = TailscaleNetwork.FindAddresses().FirstOrDefault()?.ToString();
        var lan = lanListening ? LanNetwork.LocalAddresses().Select(a => a.Address.ToString()).FirstOrDefault() : null;
        var host = tailscale ?? lan;

        WifiPanel.Visibility = Visibility.Collapsed;
        if (!lanListening)
        {
            var (title, text, canAllow) = !_settings.LocalNetwork
                ? ("Wi-Fi pairing is off", "Turn on Local network in Settings to pair over Wi-Fi.", false)
                : ("Windows Firewall is blocking Wi-Fi", "To pair over Wi-Fi without Tailscale, let your iPhone reach Droprr on your private network. Windows asks for permission once.", true);
            WifiTitle.Text = tailscale is null ? title : "Pairing over Tailscale only";
            WifiText.Text = tailscale is null ? text : text + " The code below works while Tailscale is connected on both devices.";
            AllowButton.Visibility = canAllow ? Visibility.Visible : Visibility.Collapsed;
            WifiPanel.Visibility = Visibility.Visible;
        }

        if (host is null)
        {
            if (lanListening)
            {
                Error.Message = "This PC isn't connected to Tailscale or a private Wi-Fi or Ethernet network, so a phone couldn't reach it.";
                Error.IsOpen = true;
            }
            Code.Source = null;
            CodePanel.Visibility = Visibility.Collapsed;
            ScanHint.Visibility = Visibility.Collapsed;
            Details.Visibility = Visibility.Collapsed;
            PrivacyNote.IsOpen = false;
            return;
        }

        Error.IsOpen = false;
        var dns = tailscale is null ? null : MagicDnsName();
        Code.Source = Render(PairingUri(_settings, host, dns));
        CodePanel.Visibility = Visibility.Visible;
        ScanHint.Visibility = Visibility.Visible;
        Details.Visibility = Visibility.Visible;
        PrivacyNote.IsOpen = true;
        Details.Text = tailscale is null
            ? $"{_settings.DeviceName} · Wi-Fi · {host}"
            : $"{_settings.DeviceName} · {dns ?? host} · port {_settings.Port}";
    }

    async void OnAllow(object sender, RoutedEventArgs e)
    {
        if (Application.Current is not App app)
            return;
        AllowButton.IsEnabled = false;
        try
        {
            if (await app.AllowLocalNetworkAsync())
                ShowCode();
            else
                WifiText.Text = "Windows didn't allow it. Try again, and choose Yes when Windows asks.";
        }
        finally
        {
            AllowButton.IsEnabled = true;
        }
    }

    // The phone called POST /pair: confirm, and drop the code (it holds the token) before closing.
    void OnPaired(Peer peer)
    {
        Code.Source = null;
        CodePanel.Visibility = Visibility.Collapsed;
        ScanHint.Visibility = Visibility.Collapsed;
        Details.Visibility = Visibility.Collapsed;
        PrivacyNote.IsOpen = false;
        PairedPanel.Visibility = Visibility.Visible;
        PairedText.Text = $"Paired with {peer.Name}";
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
        // Local network (protocol 2): optional fields older apps ignore. The phone pins the fingerprint.
        fields.Add(("id", settings.DeviceId));
        fields.Add(("fp", DeviceIdentity.Fingerprint(settings)));
        if (Application.Current is App { LanListening: true })
        {
            var tlsPort = LanNetwork.TlsPort(settings.Port);
            var lan = string.Join(",", LanNetwork.LocalAddresses().Select(a => $"{a.Address}:{tlsPort}"));
            if (lan.Length > 0)
                fields.Add(("lan", lan));
        }
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
    internal static string? MagicDnsName()
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
