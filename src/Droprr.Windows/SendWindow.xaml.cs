using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;
using Wpf.Ui.Controls;

namespace Droprr;

public sealed record FileEntry(string FullPath)
{
    public string Name => Path.GetFileName(FullPath);
}

public partial class SendWindow : Wpf.Ui.Controls.FluentWindow
{
    AppSettings _settings;
    readonly ObservableCollection<FileEntry> _files = new();
    readonly ObservableCollection<Peer> _peers = new();

    static readonly RoutedUICommand SendCommand = new("Send", nameof(SendCommand), typeof(SendWindow));
    static readonly RoutedUICommand PasteCommand = new("Paste", nameof(PasteCommand), typeof(SendWindow));

    public SendWindow(AppSettings settings, IEnumerable<string> files)
    {
        InitializeComponent();
        AppTheme.Setup(this, AppTitleBar);
        _settings = settings;

        // Keyboard: Ctrl+Enter sends from anywhere (Enter alone sends unless the text box takes it as a new
        // line), Ctrl+V pastes files or text when the text box doesn't take it, and Esc closes.
        CommandBindings.Add(new CommandBinding(SendCommand, (_, _) => OnSend(this, new RoutedEventArgs())));
        CommandBindings.Add(new CommandBinding(PasteCommand, (_, _) => OnPaste(this, new RoutedEventArgs())));
        CommandBindings.Add(new CommandBinding(ApplicationCommands.Close, (_, _) => Close()));
        InputBindings.Add(new KeyBinding(SendCommand, Key.Enter, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(PasteCommand, Key.V, ModifierKeys.Control));
        InputBindings.Add(new KeyBinding(ApplicationCommands.Close, Key.Escape, ModifierKeys.None));

        PeerBox.ItemsSource = _peers;
        var clipboardCheck = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        clipboardCheck.Tick += (_, _) => UpdateSendClipboard();
        Activated += (_, _) => UpdateSendClipboard();
        Loaded += (_, _) => { UpdateSendClipboard(); clipboardCheck.Start(); };
        Closed += (_, _) => clipboardCheck.Stop();
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
            ShowReceived(app.Recent);
        }
    }

    // The Received tile lists the app's recent items, kept up to date as items arrive or are removed.
    internal void ShowReceived(ObservableCollection<RecentItem> recent)
    {
        ReceivedList.ItemsSource = recent;
        void UpdateEmpty() => ReceivedEmpty.Visibility = recent.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateEmpty();
        recent.CollectionChanged += (_, _) => UpdateEmpty();
        // Recheck for moved or deleted files whenever the window comes forward.
        Activated += (_, _) =>
        {
            foreach (var item in recent)
                item.Refresh();
        };
    }

    static RecentItem? RecentFrom(object sender) => (sender as FrameworkElement)?.DataContext as RecentItem;

    // A click on the row (not one of its buttons, which handle their own clicks) opens the item.
    void OnReceivedClick(object sender, MouseButtonEventArgs e)
    {
        if (RecentFrom(sender) is { IsAvailable: true } item)
            ReceivedActions.Open(item.Item);
    }

    // Keyboard: Enter opens the selected item, Delete removes it from the list.
    void OnReceivedKeyDown(object sender, KeyEventArgs e)
    {
        if (ReceivedList.SelectedItem is not RecentItem item)
            return;
        if (e.Key == Key.Enter && item.IsAvailable)
        {
            ReceivedActions.Open(item.Item);
            e.Handled = true;
        }
        else if (e.Key == Key.Delete)
        {
            RemoveRecent(item);
            e.Handled = true;
        }
    }

    void OnCopyRecent(object sender, RoutedEventArgs e)
    {
        if (RecentFrom(sender) is { } item)
            ReceivedActions.Copy(item.Item);
    }

    void OnShowRecent(object sender, RoutedEventArgs e)
    {
        if (RecentFrom(sender) is { } item)
            ReceivedActions.ShowInFolder(item.Item);
    }

    void OnRemoveRecent(object sender, RoutedEventArgs e)
    {
        if (RecentFrom(sender) is { } item)
            RemoveRecent(item);
    }

    // Removes the item from the list only; the file itself is never deleted.
    void RemoveRecent(RecentItem item)
    {
        if (Application.Current is App app)
            app.RemoveRecent(item);
        else if (ReceivedList.ItemsSource is ObservableCollection<RecentItem> list)
            list.Remove(item);
    }

    void ShowPeers()
    {
        var selected = (PeerBox.SelectedItem as Peer)?.Name;
        _peers.Clear();
        foreach (var peer in _settings.Peers)
        {
            peer.Waiting = peer.IsPhone ? Outbox.List(peer.Name).Count : 0;
            _peers.Add(peer);
        }
        PeerBox.SelectedItem = _peers.FirstOrDefault(p => p.Name == selected) ?? _peers.FirstOrDefault();
        PeerBox.Visibility = _peers.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyState.Visibility = _peers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    // The "N waiting x" badge on a phone's card clears that phone's queue right away.
    void OnClearWaiting(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not Peer { IsPhone: true } phone)
            return;
        if (Application.Current is App app)
            app.ClearWaiting(phone.Name);
        else
            Outbox.Clear(phone.Name);
        ShowPeers();
    }

    // "Sent" shows in the success tile; everything else in the InfoBar.
    void ShowStatus(InfoBarSeverity severity, string message)
    {
        HideStatus();
        if (severity == InfoBarSeverity.Success)
        {
            SuccessText.Text = message;
            SuccessTile.Visibility = Visibility.Visible;
            return;
        }
        StatusBar.Severity = severity;
        StatusBar.Title = severity switch
        {
            InfoBarSeverity.Error => "Couldn't send",
            InfoBarSeverity.Success => "Sent",
            _ => "",
        };
        StatusBar.Message = message;
        StatusBar.IsOpen = true;
    }

    void HideStatus()
    {
        StatusBar.IsOpen = false;
        SuccessTile.Visibility = Visibility.Collapsed;
    }

    void OnSettingsSaved()
    {
        _settings = SettingsStore.Load();
        ShowPeers();
    }

    void OnSettings(object sender, RoutedEventArgs e) => ((App)Application.Current).ShowSettings();

    // A "Missing Token" tile opens Settings at that device's token.
    void OnPeerTileClick(object sender, MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: Peer { IsPaired: false } peer })
            ((App)Application.Current).ShowSettings(peer.Name);
    }

    // Ask desktops what they are, so phones (which never answer) are the only ones queued.
    async System.Threading.Tasks.Task LearnPlatformsAsync()
    {
        foreach (var peer in _settings.Peers.Where(p => p.Platform.Length == 0 && p.Host.Length > 0 && p.Token.Length > 0).ToList())
        {
            var platform = await Sender.PingAsync(peer, peer.Token);
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
            ShowStatus(InfoBarSeverity.Warning, "Folders aren't supported yet, so they were skipped.");
    }

    static bool CanDrop(DragEventArgs e) =>
        e.Data.GetDataPresent(DataFormats.FileDrop) || e.Data.GetDataPresent(DataFormats.UnicodeText);

    // The drop zone's dashed border turns accent-colored, with an accent tint, while something droppable is over the window.
    void HighlightDropZone(bool on)
    {
        DropBorder.SetResourceReference(System.Windows.Shapes.Shape.StrokeProperty,
            on ? "AccentFillColorDefaultBrush" : "ThemeBorderBrush");
        DropBorder.SetResourceReference(System.Windows.Shapes.Shape.FillProperty,
            on ? "AccentTintBrush" : "ThemeTileBrush");
    }

    void OnDragEnter(object sender, DragEventArgs e) => HighlightDropZone(CanDrop(e));

    void OnDragLeave(object sender, DragEventArgs e) => HighlightDropZone(false);

    void OnDragOver(object sender, DragEventArgs e)
    {
        e.Effects = CanDrop(e) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    void OnDrop(object sender, DragEventArgs e)
    {
        HighlightDropZone(false);
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

    // Send clipboard: whatever is on the clipboard (files, or else text) goes straight to the selected device,
    // leaving the files and text already in this window alone.
    async void OnSendClipboard(object sender, RoutedEventArgs e)
    {
        var paths = Clipboard.ContainsFileDropList()
            ? Clipboard.GetFileDropList().Cast<string>().Where(File.Exists).ToList()
            : new List<string>();
        var text = paths.Count == 0 && Clipboard.ContainsText() ? Clipboard.GetText().Trim() : "";
        if (paths.Count == 0 && text.Length == 0)
        {
            ShowStatus(InfoBarSeverity.Informational, "The clipboard is empty.");
            return;
        }
        await SendAsync(paths, text, clearWindow: false);
    }

    // Enabled only when the clipboard holds files or text.
    void UpdateSendClipboard()
    {
        try
        {
            SendClipboardButton.IsEnabled = Clipboard.ContainsFileDropList() || Clipboard.ContainsText();
        }
        catch (System.Runtime.InteropServices.COMException)
        {
            // Another app has the clipboard open; check again on the next tick.
        }
    }

    async void OnSend(object sender, RoutedEventArgs e)
    {
        var text = MessageText.Text.Trim();
        if (_files.Count == 0 && text.Length == 0)
        {
            ShowStatus(InfoBarSeverity.Informational, "Add files or type some text first.");
            return;
        }
        await SendAsync(_files.Select(f => f.FullPath).ToList(), text, clearWindow: true);
    }

    async System.Threading.Tasks.Task SendAsync(List<string> paths, string text, bool clearWindow)
    {
        if (!SendButton.IsEnabled)
            return;
        if (PeerBox.SelectedItem is not Peer peer)
        {
            ShowStatus(InfoBarSeverity.Informational, "Pick a device first.");
            return;
        }
        // This PC's own token is never sent to a peer, so an unpaired computer can't be sent to.
        if (!peer.IsPaired)
        {
            ShowStatus(InfoBarSeverity.Warning, $"{peer.Name} isn't paired. Scan its code or enter its token in Settings.");
            return;
        }

        var total = Math.Max(1, paths.Sum(p => new FileInfo(p).Length));
        long done = 0;
        var progress = new Progress<long>(n =>
        {
            done += n;
            Progress.Value = 100.0 * done / total;
        });

        SendButton.IsEnabled = false;
        SendClipboardButton.IsEnabled = false;
        Progress.Value = 0;
        Progress.Visibility = paths.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        // Queuing for a phone is quiet: its "N waiting" badge and the tray count show the result.
        HideStatus();
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
                    await Sender.SendFilesAsync(peer, peer.Token, paths, progress);
                if (text.Length > 0)
                    await Sender.SendTextAsync(peer, peer.Token, text);
                ShowStatus(InfoBarSeverity.Success, $"Sent to {peer.Name}.");
            }
            if (clearWindow)
            {
                _files.Clear();
                MessageText.Clear();
            }
        }
        catch (Exception ex)
        {
            ShowStatus(InfoBarSeverity.Error, $"{peer.Name}: {ex.Message}");
        }
        finally
        {
            SendButton.IsEnabled = true;
            UpdateSendClipboard();
            Progress.Visibility = Visibility.Collapsed;
        }
    }
}
