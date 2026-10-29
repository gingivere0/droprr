using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;

namespace Droprr;

public partial class SettingsWindow : Wpf.Ui.Controls.FluentWindow
{
    readonly App _app;
    readonly AppSettings _settings;
    readonly ObservableCollection<Peer> _peers;
    readonly Dictionary<string, string> _originalTokens;
    readonly string _originalTheme;
    readonly string _originalMode;
    readonly string _originalStyle;
    // Set while the pickers are refilled, so their selection events don't apply anything.
    bool _refilling;
    bool _tokenVisible;
    bool _saved;

    internal SettingsWindow(App app)
    {
        InitializeComponent();
        AppTheme.Setup(this, AppTitleBar);
        _app = app;

        // Edit a fresh copy from disk; nothing changes until Save.
        _settings = SettingsStore.Load();
        DeviceName.Text = _settings.DeviceName;
        Port.Text = _settings.Port.ToString();
        SaveFolder.Text = _settings.SaveFolder ?? "";
        SaveFolder.ToolTip = $"Leave empty to use {_settings.ResolveSaveFolder()}";
        StartWithWindowsBox.IsChecked = StartWithWindows.IsEnabled;
        StartMenuBox.IsChecked = _settings.AddToStartMenu;
        CopyFilesBox.IsChecked = _settings.CopyFilesToClipboard;
        CopyTextBox.IsChecked = _settings.CopyTextToClipboard;
        LocalNetworkBox.IsChecked = _settings.LocalNetwork;
        _peers = new ObservableCollection<Peer>(_settings.Peers);
        _originalTokens = _settings.Peers.GroupBy(p => p.Name.Trim(), StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.First().Token, StringComparer.OrdinalIgnoreCase);
        PeerGrid.ItemsSource = _peers;
        DeviceCountChip.Text = _peers.Count == 1 ? "1 device" : $"{_peers.Count} devices";
        ShowToken();

        // Appearance: picking a swatch restyles every window at once; Cancel (or closing) puts it back.
        _originalTheme = AppTheme.Current.Id;
        _originalMode = AppTheme.Mode;
        _originalStyle = AppTheme.Look.Id;
        ShowSwatches();
        ModeBox.SelectedItem = ModeBox.Items.Cast<ComboBoxItem>().First(i => (string)i.Tag == _originalMode);
        // The swatches preview each style and theme in the current mode.
        Action rebuild = ShowSwatches;
        AppTheme.ModeChanged += rebuild;
        Closed += (_, _) =>
        {
            AppTheme.ModeChanged -= rebuild;
            if (!_saved)
            {
                AppTheme.SetTheme(_originalTheme);
                AppTheme.SetStyle(_originalStyle);
                AppTheme.SetMode(_originalMode);
            }
        };

        // Esc closes without saving, unless something inside used it first (like cancelling a cell edit).
        CommandBindings.Add(new CommandBinding(ApplicationCommands.Close, (_, _) => Close()));
        InputBindings.Add(new KeyBinding(ApplicationCommands.Close, Key.Escape, ModifierKeys.None));

        // Show a device the moment it pairs, without losing edits made here that aren't saved yet.
        app.DevicePaired += OnDevicePaired;
        Closed += (_, _) => app.DevicePaired -= OnDevicePaired;

        // Local network: devices found nearby, and whether the firewall lets them in.
        app.NearbyChanged += ShowNearby;
        Closed += (_, _) => app.NearbyChanged -= ShowNearby;
        ShowNearby();
        Loaded += async (_, _) => await ShowFirewallAsync();
    }

    // Test: /ping the selected device, Wi-Fi first (pinned) and then Tailscale, as a send would.
    async void OnTestPeer(object sender, RoutedEventArgs e)
    {
        PeerGrid.CommitEdit(DataGridEditingUnit.Row, true);
        if (PeerGrid.SelectedItem is not Peer peer)
        {
            TestResult.Text = "Select a device first.";
            return;
        }
        if (peer.IsPhone && peer.Token.Length == 0)
        {
            TestResult.Text = $"{peer.Name}: phones collect items when Droprr opens.";
            return;
        }
        TestButton.IsEnabled = false;
        TestResult.Text = $"Testing {peer.Name}…";
        try
        {
            var (_, text) = await Sender.TestAsync(peer);
            TestResult.Text = $"{peer.Name}: {text}";
        }
        finally
        {
            TestButton.IsEnabled = true;
        }
    }

    void ShowNearby()
    {
        var nearby = _app.UnpairedNearby().Where(d => !_peers.Any(p => p.Id == d.Id)).ToList();
        NearbyList.ItemsSource = nearby;
        NearbyPanel.Visibility = nearby.Count > 0 && LocalNetworkBox.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
    }

    async void OnPairNearby(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: LanDevice device })
            return;
        ((UIElement)sender).IsEnabled = false;
        try
        {
            await _app.PairOverLanAsync(device);
        }
        finally
        {
            ((UIElement)sender).IsEnabled = true;
            ShowNearby();
        }
    }

    async void OnLocalNetworkToggled(object sender, RoutedEventArgs e)
    {
        ShowNearby();
        await ShowFirewallAsync();
    }

    // The rule is read off the UI thread: Windows Firewall can have hundreds of rules.
    async System.Threading.Tasks.Task ShowFirewallAsync()
    {
        if (LocalNetworkBox.IsChecked != true)
        {
            FirewallPanel.Visibility = Visibility.Collapsed;
            return;
        }
        var port = LanNetwork.TlsPort(_settings.Port);
        var (hasRule, blocked) = await System.Threading.Tasks.Task.Run(() => (LanFirewall.HasRule(port), LanFirewall.BlockRules().Count));
        FirewallText.Text = (hasRule, blocked) switch
        {
            (false, 0) => "Windows Firewall needs to let nearby devices reach Droprr. This asks for permission once, for private networks only.",
            (false, _) => "Windows Firewall needs to let nearby devices reach Droprr, and it's blocking an older copy. This asks for permission once and fixes both.",
            _ => "Windows Firewall is blocking an older copy of Droprr. This asks for permission once to remove the block.",
        };
        FirewallPanel.Visibility = hasRule && blocked == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    async void OnAllowFirewall(object sender, RoutedEventArgs e)
    {
        FirewallButton.IsEnabled = false;
        try
        {
            if (!await _app.AllowLocalNetworkAsync())
                FirewallText.Text = "Windows didn't allow it. Try again, and choose Yes when Windows asks.";
            else
                await ShowFirewallAsync();
        }
        finally
        {
            FirewallButton.IsEnabled = true;
        }
    }

    void OnDevicePaired(Peer paired)
    {
        var existing = _peers.FirstOrDefault(p => p.Name.Trim().Equals(paired.Name.Trim(), StringComparison.OrdinalIgnoreCase));
        if (existing is not null)
            _peers[_peers.IndexOf(existing)] = paired;
        else
            _peers.Add(paired);
    }

    void ShowToken()
    {
        TokenText.Text = _tokenVisible ? _settings.Token : new string('•', 24);
        ShowTokenButton.Content = _tokenVisible ? "Hide" : "Show";
        ShowTokenButton.Icon = new Wpf.Ui.Controls.SymbolIcon(_tokenVisible ? Wpf.Ui.Controls.SymbolRegular.EyeOff24 : Wpf.Ui.Controls.SymbolRegular.Eye24);
    }

    void OnThemeChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_refilling || ThemeList.SelectedItem is not ThemeSwatch swatch)
            return;
        AppTheme.SetTheme(swatch.Id);
        // The style drawings use the theme's colors.
        ShowSwatches();
    }

    void OnStyleChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (!_refilling && StyleList.SelectedItem is StyleSwatch swatch)
            AppTheme.SetStyle(swatch.Id);
    }

    void ShowSwatches()
    {
        _refilling = true;
        try
        {
            var styles = LookCatalog.All.Select(l => new StyleSwatch(l, AppTheme.Current, AppTheme.IsDark)).ToList();
            StyleList.ItemsSource = styles;
            StyleList.SelectedItem = styles.First(s => s.Id == AppTheme.Look.Id);
            var themes = ThemeCatalog.All.Select(t => new ThemeSwatch(t, AppTheme.IsDark)).ToList();
            ThemeList.ItemsSource = themes;
            ThemeList.SelectedItem = themes.First(t => t.Id == AppTheme.Current.Id);
            // Spatial is always dark, so Light, Dark, or System waits until another style is picked.
            ModeBox.IsEnabled = !AppTheme.Look.ForcesDark;
        }
        finally
        {
            _refilling = false;
        }
    }

    void OnModeChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (ModeBox.SelectedItem is ComboBoxItem { Tag: string mode })
            AppTheme.SetMode(mode);
    }

    void OnShowToken(object sender, RoutedEventArgs e)
    {
        _tokenVisible = !_tokenVisible;
        ShowToken();
    }

    void OnCopyToken(object sender, RoutedEventArgs e) => ClipboardHelper.TrySetText(_settings.Token);

    async void OnNewToken(object sender, RoutedEventArgs e)
    {
        var box = new Wpf.Ui.Controls.MessageBox
        {
            Title = "Make a new token?",
            Content = "Every device and shortcut that sends to this PC will need the new one. Phones can get it by pairing again.",
            PrimaryButtonText = "Make new token",
            CloseButtonText = "Cancel",
            Owner = this,
        };
        if (await box.ShowDialogAsync() != Wpf.Ui.Controls.MessageBoxResult.Primary)
            return;
        _settings.Token = SettingsStore.NewToken();
        _tokenVisible = true;
        ShowToken();
    }

    // IsCancel only closes windows opened with ShowDialog, and Settings opens as a normal window.
    void OnCancel(object sender, RoutedEventArgs e) => Close();

    void OnBrowse(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Save received items to", InitialDirectory = _settings.ResolveSaveFolder() };
        if (dialog.ShowDialog(this) == true)
            SaveFolder.Text = dialog.FolderName;
    }

    void OnAddPeer(object sender, RoutedEventArgs e)
    {
        var peer = new Peer { Name = "New device" };
        _peers.Add(peer);
        EditCell(peer, NameColumn);
    }

    // Peer tokens show as dots until revealed here.
    public static readonly DependencyProperty PeerTokensVisibleProperty =
        DependencyProperty.Register(nameof(PeerTokensVisible), typeof(bool), typeof(SettingsWindow));

    public bool PeerTokensVisible
    {
        get => (bool)GetValue(PeerTokensVisibleProperty);
        set => SetValue(PeerTokensVisibleProperty, value);
    }

    void OnShowPeerTokens(object sender, RoutedEventArgs e)
    {
        PeerTokensVisible = !PeerTokensVisible;
        ShowPeerTokensButton.Content = PeerTokensVisible ? "Hide tokens" : "Show tokens";
        ShowPeerTokensButton.Icon = new Wpf.Ui.Controls.SymbolIcon(PeerTokensVisible ? Wpf.Ui.Controls.SymbolRegular.EyeOff24 : Wpf.Ui.Controls.SymbolRegular.Eye24);
    }

    // From the Send window's "Missing Token" tile: start editing that device's token.
    internal void FocusPeerToken(string name)
    {
        if (!IsLoaded)
        {
            void OnLoaded(object s, RoutedEventArgs e)
            {
                Loaded -= OnLoaded;
                FocusPeerToken(name);
            }
            Loaded += OnLoaded;
            return;
        }
        if (_peers.FirstOrDefault(p => p.Name.Trim().Equals(name.Trim(), StringComparison.OrdinalIgnoreCase)) is { } peer)
            EditCell(peer, TokenColumn);
    }

    // Selects the cell, starts editing it, and puts the cursor in its text box with the text selected.
    void EditCell(Peer peer, DataGridColumn column)
    {
        PeerGrid.SelectedItem = peer;
        PeerGrid.ScrollIntoView(peer, column);
        PeerGrid.UpdateLayout();
        PeerGrid.CurrentCell = new DataGridCellInfo(peer, column);
        PeerGrid.Focus();
        PeerGrid.BeginEdit();
        Dispatcher.BeginInvoke(DispatcherPriority.Input, () =>
        {
            if (FindTextBox(column.GetCellContent(peer)) is not { } box)
                return;
            box.Focus();
            box.SelectAll();
            box.BringIntoView();
        });
    }

    static System.Windows.Controls.TextBox? FindTextBox(DependencyObject? element)
    {
        if (element is System.Windows.Controls.TextBox box)
            return box;
        for (var i = 0; element is not null && i < VisualTreeHelper.GetChildrenCount(element); i++)
            if (FindTextBox(VisualTreeHelper.GetChild(element, i)) is { } found)
                return found;
        return null;
    }

    // Uses the saved settings, so the code carries the token and port this PC is actually using.
    void OnPair(object sender, RoutedEventArgs e) =>
        new PairWindow(SettingsStore.Load()) { Owner = this }.ShowDialog();

    void OnRemovePeer(object sender, RoutedEventArgs e)
    {
        if (PeerGrid.SelectedItem is Peer peer)
            _peers.Remove(peer);
    }

    // Opens settings.json in the default .json editor, or Notepad when nothing is associated with .json.
    void OnOpenFile(object sender, RoutedEventArgs e)
    {
        var path = SettingsStore.FilePath;
        if (!System.IO.File.Exists(path))
            SettingsStore.Save(_settings);
        try
        {
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch (System.ComponentModel.Win32Exception)
        {
            Process.Start(new ProcessStartInfo("notepad.exe", $"\"{path}\"") { UseShellExecute = true });
        }
    }

    async void OnSave(object sender, RoutedEventArgs e)
    {
        PeerGrid.CommitEdit(System.Windows.Controls.DataGridEditingUnit.Row, true);
        if (string.IsNullOrWhiteSpace(DeviceName.Text))
        {
            Error.Text = "Give this PC a name.";
            return;
        }
        if (!int.TryParse(Port.Text, out var port) || port is < 1 or > 65535)
        {
            Error.Text = "Port must be a number from 1 to 65535.";
            return;
        }
        // A computer paired over Wi-Fi may have no Tailscale host.
        if (_peers.Any(p => string.IsNullOrWhiteSpace(p.Name) || (!p.IsPhone && string.IsNullOrWhiteSpace(p.Host) && p.Fingerprint.Length == 0)))
        {
            Error.Text = "Each device needs a name, and computers need a Tailscale host unless they were paired over Wi-Fi.";
            return;
        }

        _settings.DeviceName = DeviceName.Text.Trim();
        _settings.Port = port;
        _settings.SaveFolder = string.IsNullOrWhiteSpace(SaveFolder.Text) ? null : SaveFolder.Text.Trim();
        // Computers that are new or have a new token get paired properly once saved (see App.PairWithComputersAsync).
        var toPair = _peers
            .Where(p => !p.IsPhone && p.Token.Length > 0 && p.Host.Length > 0)
            .Where(p => _originalTokens.TryGetValue(p.Name.Trim(), out var before) ? before != p.Token : true)
            .Select(p => p.Name)
            .ToList();
        _settings.Peers = _peers.ToList();
        _settings.AddToStartMenu = StartMenuBox.IsChecked == true;
        _settings.CopyFilesToClipboard = CopyFilesBox.IsChecked == true;
        _settings.LocalNetwork = LocalNetworkBox.IsChecked == true;
        _settings.CopyTextToClipboard = CopyTextBox.IsChecked == true;
        _settings.Theme = AppTheme.Current.Id;
        _settings.Mode = AppTheme.Mode;
        _settings.Style = AppTheme.Look.Id;
        try
        {
            SettingsStore.Save(_settings);
            StartWithWindows.Set(StartWithWindowsBox.IsChecked == true);
            Shortcuts.SyncStartMenu(_settings.AddToStartMenu);
        }
        catch (Exception ex)
        {
            Error.Text = ex.Message;
            return;
        }
        _saved = true;
        Close();
        await _app.ReloadAsync();
        if (toPair.Count > 0)
            await _app.PairWithComputersAsync(toPair);
    }
}
