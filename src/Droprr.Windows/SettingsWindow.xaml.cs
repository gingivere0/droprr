using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Input;
using Microsoft.Win32;

namespace Droprr;

public partial class SettingsWindow : Wpf.Ui.Controls.FluentWindow
{
    readonly App _app;
    readonly AppSettings _settings;
    readonly ObservableCollection<Peer> _peers;
    readonly Dictionary<string, string> _originalTokens;
    readonly string _originalTheme;
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
        _peers = new ObservableCollection<Peer>(_settings.Peers);
        _originalTokens = _settings.Peers.GroupBy(p => p.Name.Trim(), StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.First().Token, StringComparer.OrdinalIgnoreCase);
        PeerGrid.ItemsSource = _peers;
        DeviceCountChip.Text = _peers.Count == 1 ? "1 device" : $"{_peers.Count} devices";
        ShowToken();

        // Appearance: picking a swatch restyles every window at once; Cancel (or closing) puts it back.
        _originalTheme = AppTheme.Current.Id;
        ThemeList.ItemsSource = ThemeCatalog.All.Select(t => new ThemeSwatch(t, AppTheme.IsDark)).ToList();
        ThemeList.SelectedItem = ((IEnumerable<ThemeSwatch>)ThemeList.ItemsSource).First(t => t.Id == _originalTheme);
        Closed += (_, _) =>
        {
            if (!_saved)
                AppTheme.SetTheme(_originalTheme);
        };

        // Esc closes without saving, unless something inside used it first (like cancelling a cell edit).
        CommandBindings.Add(new CommandBinding(ApplicationCommands.Close, (_, _) => Close()));
        InputBindings.Add(new KeyBinding(ApplicationCommands.Close, Key.Escape, ModifierKeys.None));

        // Show a device the moment it pairs, without losing edits made here that aren't saved yet.
        app.DevicePaired += OnDevicePaired;
        Closed += (_, _) => app.DevicePaired -= OnDevicePaired;
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
        if (ThemeList.SelectedItem is ThemeSwatch swatch)
            AppTheme.SetTheme(swatch.Id);
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
        PeerGrid.SelectedItem = peer;
        PeerGrid.ScrollIntoView(peer);
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
        if (_peers.Any(p => string.IsNullOrWhiteSpace(p.Name) || (!p.IsPhone && string.IsNullOrWhiteSpace(p.Host))))
        {
            Error.Text = "Each device needs a name, and computers need a host.";
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
        _settings.CopyTextToClipboard = CopyTextBox.IsChecked == true;
        _settings.Theme = AppTheme.Current.Id;
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
