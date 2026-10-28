using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace Droprr;

public sealed record FileEntry(string FullPath)
{
    public string Name => Path.GetFileName(FullPath);
}

public partial class SendWindow : Window
{
    AppSettings _settings;
    readonly ObservableCollection<FileEntry> _files = new();

    public SendWindow(AppSettings settings, IEnumerable<string> files)
    {
        InitializeComponent();
        Icon = AppIcon.ImageSource;
        _settings = settings;

        FileList.ItemsSource = _files;
        _files.CollectionChanged += (_, _) => DropHint.Visibility = _files.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        AddPaths(files);

        ShowPeers();
        Loaded += async (_, _) => await LearnPlatformsAsync();

        // Pick up devices added or changed in Settings while this window is open.
        if (Application.Current is App app)
        {
            app.SettingsSaved += OnSettingsSaved;
            Closed += (_, _) => app.SettingsSaved -= OnSettingsSaved;
        }
    }

    void ShowPeers()
    {
        var selected = (PeerBox.SelectedItem as Peer)?.Name;
        foreach (var peer in _settings.Peers)
            peer.Waiting = peer.IsPhone ? Outbox.List(peer.Name).Count : 0;
        PeerBox.ItemsSource = null;
        PeerBox.ItemsSource = _settings.Peers;
        PeerBox.SelectedItem = _settings.Peers.FirstOrDefault(p => p.Name == selected) ?? _settings.Peers.FirstOrDefault();
        EmptyState.Visibility = _settings.Peers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowWaitingBadge();
    }

    void ShowWaitingBadge()
    {
        if (PeerBox.SelectedItem is Peer { IsPhone: true, Waiting: > 0 } phone)
        {
            WaitingText.Text = $"{phone.Waiting} waiting";
            WaitingBadge.Visibility = Visibility.Visible;
        }
        else
        {
            WaitingBadge.Visibility = Visibility.Collapsed;
        }
    }

    void OnClearWaiting(object sender, RoutedEventArgs e)
    {
        if (PeerBox.SelectedItem is not Peer { IsPhone: true } phone)
            return;
        ((App)Application.Current).ClearWaiting(phone.Name);
        ShowPeers();
    }

    void OnSettingsSaved()
    {
        _settings = SettingsStore.Load();
        ShowPeers();
    }

    void OnSettings(object sender, RoutedEventArgs e) => ((App)Application.Current).ShowSettings();

    // Ask desktops what they are, so phones (which never answer) are the only ones queued.
    async System.Threading.Tasks.Task LearnPlatformsAsync()
    {
        foreach (var peer in _settings.Peers.Where(p => p.Platform.Length == 0 && p.Host.Length > 0).ToList())
        {
            var platform = await Sender.PingAsync(peer, TokenFor(peer));
            if (string.IsNullOrEmpty(platform))
                continue;
            peer.Platform = platform;
            SettingsStore.Update(s =>
            {
                if (s.FindPeer(peer.Name) is { } saved)
                    saved.Platform = platform;
            });
        }
        PeerBox.Items.Refresh();
    }

    string TokenFor(Peer peer) => string.IsNullOrEmpty(peer.Token) ? _settings.Token : peer.Token;

    void OnPeerChanged(object sender, SelectionChangedEventArgs e) => ShowWaitingBadge();

    internal void AddPaths(IEnumerable<string> paths)
    {
        var skippedFolders = false;
        foreach (var path in paths)
        {
            if (Directory.Exists(path))
                skippedFolders = true;
            else if (File.Exists(path) && _files.All(f => f.FullPath != path))
                _files.Add(new FileEntry(path));
        }
        if (skippedFolders)
            Status.Text = "Folders aren't supported yet, so they were skipped.";
    }

    void OnDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) || e.Data.GetDataPresent(DataFormats.UnicodeText)
            ? DragDropEffects.Copy
            : DragDropEffects.None;
        e.Handled = true;
    }

    void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths)
            AddPaths(paths);
        else if (e.Data.GetData(DataFormats.UnicodeText) is string text)
            MessageText.Text = text;
        e.Handled = true;
    }

    void OnAddFiles(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Multiselect = true, Title = "Choose files to send" };
        if (dialog.ShowDialog(this) == true)
            AddPaths(dialog.FileNames);
    }

    void OnClearFiles(object sender, RoutedEventArgs e) => _files.Clear();

    void OnPaste(object sender, RoutedEventArgs e)
    {
        if (Clipboard.ContainsFileDropList())
            AddPaths(Clipboard.GetFileDropList().Cast<string>());
        else if (Clipboard.ContainsText())
            MessageText.Text = Clipboard.GetText();
    }

    async void OnSend(object sender, RoutedEventArgs e)
    {
        if (PeerBox.SelectedItem is not Peer peer)
        {
            Status.Text = "Pick a device first.";
            return;
        }
        var text = MessageText.Text.Trim();
        if (_files.Count == 0 && text.Length == 0)
        {
            Status.Text = "Add files or type some text first.";
            return;
        }

        var paths = _files.Select(f => f.FullPath).ToList();
        var total = Math.Max(1, paths.Sum(p => new FileInfo(p).Length));
        long done = 0;
        var progress = new Progress<long>(n =>
        {
            done += n;
            Progress.Value = 100.0 * done / total;
        });

        SendButton.IsEnabled = false;
        Progress.Value = 0;
        Progress.Visibility = paths.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        // Queuing for a phone is quiet: its "N waiting" badge and the tray count show the result.
        Status.Text = peer.IsPhone ? "" : $"Sending to {peer.Name}…";
        try
        {
            if (peer.IsPhone)
            {
                foreach (var path in paths)
                    await Outbox.EnqueueFileAsync(peer.Name, path, progress);
                if (text.Length > 0)
                    Outbox.EnqueueText(peer.Name, Sender.TextType(text), text);
                ShowPeers();
            }
            else
            {
                if (paths.Count > 0)
                    await Sender.SendFilesAsync(peer, TokenFor(peer), paths, progress);
                if (text.Length > 0)
                    await Sender.SendTextAsync(peer, TokenFor(peer), text);
                Status.Text = $"Sent to {peer.Name}.";
            }
            _files.Clear();
            MessageText.Clear();
        }
        catch (Exception ex)
        {
            Status.Text = $"Couldn't send to {peer.Name}: {ex.Message}";
        }
        finally
        {
            SendButton.IsEnabled = true;
            Progress.Visibility = Visibility.Collapsed;
        }
    }
}
