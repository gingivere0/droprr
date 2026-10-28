using System;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Security.Cryptography;
using System.Windows;
using Microsoft.Win32;

namespace Droprr;

public partial class SettingsWindow : Window
{
    readonly App _app;
    readonly AppSettings _settings;
    readonly ObservableCollection<Peer> _peers;
    bool _tokenVisible;

    internal SettingsWindow(App app)
    {
        InitializeComponent();
        Icon = AppIcon.ImageSource;
        _app = app;

        // Edit a fresh copy from disk; nothing changes until Save.
        _settings = SettingsStore.Load();
        DeviceName.Text = _settings.DeviceName;
        Port.Text = _settings.Port.ToString();
        SaveFolder.Text = _settings.SaveFolder ?? "";
        SaveFolder.ToolTip = $"Leave empty to use {_settings.ResolveSaveFolder()}";
        StartWithWindowsBox.IsChecked = StartWithWindows.IsEnabled;
        StartMenuBox.IsChecked = _settings.AddToStartMenu;
        _peers = new ObservableCollection<Peer>(_settings.Peers);
        PeerGrid.ItemsSource = _peers;
        ShowToken();
    }

    void ShowToken()
    {
        TokenText.Text = _tokenVisible ? _settings.Token : new string('•', 24);
        ShowTokenButton.Content = _tokenVisible ? "Hide" : "Show";
    }

    void OnShowToken(object sender, RoutedEventArgs e)
    {
        _tokenVisible = !_tokenVisible;
        ShowToken();
    }

    void OnCopyToken(object sender, RoutedEventArgs e) => ClipboardHelper.TrySetText(_settings.Token);

    void OnNewToken(object sender, RoutedEventArgs e)
    {
        var answer = MessageBox.Show(this,
            "Make a new token? Every device and shortcut that sends to this PC will need the new one.",
            "New token", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (answer != MessageBoxResult.OK)
            return;
        _settings.Token = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        _tokenVisible = true;
        ShowToken();
    }

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
        _settings.Peers = _peers.ToList();
        _settings.AddToStartMenu = StartMenuBox.IsChecked == true;
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
        Close();
        await _app.ReloadAsync();
    }
}
