using System;
using System.Linq;
using System.Net.Sockets;
using System.Threading.Tasks;
using System.Windows;

namespace Droprr;

// Browser access (docs/PROTOCOL.md, "Browser access"): a QR code of this PC's page with a one-time code in its
// fragment, plus the address and code to type by hand. The code works only while this window is open.
public partial class BrowserWindow : Wpf.Ui.Controls.FluentWindow
{
    readonly App _app;
    string? _wifiHost;
    string? _tailscaleHost;

    public BrowserWindow(App app)
    {
        InitializeComponent();
        AppTheme.Setup(this, AppTitleBar);
        _app = app;
        app.BrowserConnected += OnConnected;
        app.BrowserAccess.Ended += OnCodeEnded;
        if (app.BrowserHost is { } host)
            host.Ready += OnHostReady;
        Closed += (_, _) =>
        {
            app.BrowserConnected -= OnConnected;
            app.BrowserAccess.Ended -= OnCodeEnded;
            if (app.BrowserHost is { } host)
                host.Ready -= OnHostReady;
            app.BrowserAccess.Close();
            app.BrowserHost?.ConfigChanged();
        };
        Loaded += async (_, _) => await FindHostsAsync();
    }

    // Wi-Fi: this PC's first private LAN address, over HTTPS. Tailscale: its MagicDNS name (or address) over HTTP,
    // which Tailscale already encrypts. Wi-Fi first, since any phone on the network can use it.
    async Task FindHostsAsync()
    {
        var lanListening = _app.LanListening;
        _wifiHost = lanListening ? LanNetwork.LocalAddresses().Select(a => a.Address.ToString()).FirstOrDefault() : null;
        var tailscale = TailscaleNetwork.FindAddresses().FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork)?.ToString();
        _tailscaleHost = tailscale is null ? null : await Task.Run(PairWindow.MagicDnsName) ?? tailscale;

        WifiPanel.Visibility = Visibility.Collapsed;
        if (!lanListening)
        {
            var settings = _app.Settings;
            var (title, text, canAllow) = !settings.LocalNetwork
                ? ("Wi-Fi is off", "Turn on Local network in Settings to open Droprr in a browser over Wi-Fi.", false)
                : ("Windows Firewall is blocking Wi-Fi", "To open Droprr in a phone's browser over Wi-Fi, let it reach this PC on your private network. Windows asks for permission once.", true);
            WifiTitle.Text = _tailscaleHost is null ? title : "Tailscale only";
            WifiText.Text = _tailscaleHost is null ? text : text + " The code below works on a phone with Tailscale connected.";
            AllowButton.Visibility = canAllow ? Visibility.Visible : Visibility.Collapsed;
            WifiPanel.Visibility = Visibility.Visible;
        }

        // The website comes first: any phone on the same Wi-Fi, with no app and no certificate warning.
        var website = _app.BrowserHost is not null;
        WebsiteChoice.Visibility = website ? Visibility.Visible : Visibility.Collapsed;
        WifiChoice.Visibility = _wifiHost is not null ? Visibility.Visible : Visibility.Collapsed;
        TailscaleChoice.Visibility = _tailscaleHost is not null ? Visibility.Visible : Visibility.Collapsed;
        var choices = (website ? 1 : 0) + (_wifiHost is not null ? 1 : 0) + (_tailscaleHost is not null ? 1 : 0);
        PathPanel.Visibility = choices > 1 ? Visibility.Visible : Visibility.Collapsed;
        if (WebsiteChoice.IsChecked != true && WifiChoice.IsChecked != true && TailscaleChoice.IsChecked != true)
        {
            if (website)
                WebsiteChoice.IsChecked = true;
            else if (_wifiHost is not null)
                WifiChoice.IsChecked = true;
            else if (_tailscaleHost is not null)
                TailscaleChoice.IsChecked = true;
        }
        if (website && WebsiteChoice.IsChecked == true)
            WifiPanel.Visibility = Visibility.Collapsed;
        ShowCode();
    }

    void OnPathChanged(object sender, RoutedEventArgs e)
    {
        if (IsLoaded)
            ShowCode();
    }

    void OnHostReady() => Dispatcher.BeginInvoke(() =>
    {
        if (WebsiteChoice.IsChecked == true)
            ShowCode();
    });

    // The website's QR: a link to the site with this PC's room, the code, and the page's key. Browsers that use it
    // are added once they connect; they can come back later without it.
    bool ShowWebsiteCode()
    {
        if (_app.BrowserHost is not { } host)
            return false;
        Error.IsOpen = false;
        if (_app.BrowserAccess.Secret is null)
        {
            _app.BrowserAccess.Open();
            host.ConfigChanged();
        }
        AddressHint.Text = "Or open this website on the phone and tap Scan code:";
        Address.Text = BrowserHost.Site(_app.Settings).Replace("https://", "");
        CodeText.Visibility = Visibility.Collapsed;
        Expiry.Text = "Works on any phone on the same Wi-Fi as this PC, with no app and no warning. The code works while this window is open, for 10 minutes; phones that connect can come back later without it.";
        CertificateNote.IsOpen = false;
        NewCodeButton.Visibility = Visibility.Collapsed;
        CodeDetails.Visibility = Visibility.Visible;
        if (host.JoinLink() is { } link)
        {
            Code.Source = PairWindow.Render(link);
            CodePanel.Visibility = Visibility.Visible;
        }
        else
        {
            // The page hasn't reported its key yet (WebView2 is still starting).
            Code.Source = null;
            CodePanel.Visibility = Visibility.Collapsed;
            Error.Message = "Getting ready… This takes a few seconds after Droprr starts.";
            Error.IsOpen = true;
        }
        return true;
    }

    void OnNewCode(object sender, RoutedEventArgs e) => ShowCode();

    // A fresh code for the chosen path. Each one replaces the last.
    void ShowCode()
    {
        ConnectedPanel.Visibility = Visibility.Collapsed;
        if (WebsiteChoice.IsChecked == true && ShowWebsiteCode())
            return;
        AddressHint.Text = "Or open this address and type the code:";
        CodeText.Visibility = Visibility.Visible;
        Expiry.Text = "Works once, while this window is open, for 10 minutes.";
        var wifi = WifiChoice.IsChecked == true && _wifiHost is not null;
        var host = wifi ? _wifiHost : _tailscaleHost;
        ConnectedPanel.Visibility = Visibility.Collapsed;
        if (host is null)
        {
            _app.BrowserAccess.Close();
            Code.Source = null;
            CodePanel.Visibility = Visibility.Collapsed;
            CodeDetails.Visibility = Visibility.Collapsed;
            NewCodeButton.Visibility = Visibility.Collapsed;
            if (WifiPanel.Visibility != Visibility.Visible)
            {
                Error.Message = "This PC isn't connected to Tailscale or a private Wi-Fi or Ethernet network, so a phone couldn't reach it.";
                Error.IsOpen = true;
            }
            return;
        }

        Error.IsOpen = false;
        var port = _app.Settings.Port;
        var address = wifi ? $"https://{host}:{LanNetwork.TlsPort(port)}/web" : $"http://{host}:{port}/web";
        var code = _app.BrowserAccess.Open();
        _app.BrowserHost?.ConfigChanged();
        Code.Source = PairWindow.Render($"{address}#{code}");
        Address.Text = address;
        CodeText.Text = BrowserAccess.Format(code);
        CertificateNote.IsOpen = wifi;
        CodePanel.Visibility = Visibility.Visible;
        CodeDetails.Visibility = Visibility.Visible;
        NewCodeButton.Visibility = Visibility.Visible;
    }

    async void OnAllow(object sender, RoutedEventArgs e)
    {
        AllowButton.IsEnabled = false;
        try
        {
            if (await _app.AllowLocalNetworkAsync())
                await FindHostsAsync();
            else
                WifiText.Text = "Windows didn't allow it. Try again, and choose Yes when Windows asks.";
        }
        finally
        {
            AllowButton.IsEnabled = true;
        }
    }

    // Raised on a server thread: the code was used, or too many wrong codes closed it.
    void OnCodeEnded(bool accepted)
    {
        if (accepted)
            return;
        Dispatcher.BeginInvoke(() =>
        {
            Code.Source = null;
            CodePanel.Visibility = Visibility.Collapsed;
            CodeDetails.Visibility = Visibility.Collapsed;
            Error.Message = "Someone typed too many wrong codes, so this one stopped working. Choose New code to try again.";
            Error.IsOpen = true;
        });
    }

    void OnConnected(Peer peer)
    {
        Code.Source = null;
        CodePanel.Visibility = Visibility.Collapsed;
        CodeDetails.Visibility = Visibility.Collapsed;
        PathPanel.Visibility = Visibility.Collapsed;
        NewCodeButton.Visibility = Visibility.Collapsed;
        ConnectedPanel.Visibility = Visibility.Visible;
        ConnectedText.Text = $"Connected {peer.Name}";
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2.5) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            Close();
        };
        timer.Start();
    }
}
