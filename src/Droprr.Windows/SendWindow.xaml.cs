using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Windows;
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
        if (severity == InfoBarSeverity.Success)
        {
            StatusBar.IsOpen = false;
            ShowTile(SymbolRegular.CheckmarkCircle24, message);
            return;
        }
        HideStatus();
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

    // Shown or updated in place, never collapsed and reopened, so the window keeps its height.
    void ShowTile(SymbolRegular icon, string message, bool busy = false)
    {
        SuccessIcon.Symbol = icon;
        SuccessText.Text = message;
        SuccessTile.Visibility = Visibility.Visible;
        // Busy: the plain tile colors (it isn't a success yet), with Cancel.
        var (fill, text) = busy ? ("ThemeTileBrush", "TextFillColorPrimaryBrush") : ("SuccessFillBrush", "SuccessTextBrush");
        SuccessTile.SetResourceReference(System.Windows.Controls.Border.BackgroundProperty, fill);
        SuccessTile.SetResourceReference(System.Windows.Controls.Border.BorderBrushProperty, busy ? "ThemeBorderBrush" : fill);
        SuccessIcon.SetResourceReference(ForegroundProperty, text);
        SuccessText.SetResourceReference(TextBlock.ForegroundProperty, text);
        CancelSendButton.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
    }

    System.Threading.CancellationTokenSource? _sendCancel;

    void OnCancelSend(object sender, RoutedEventArgs e) => _sendCancel?.Cancel();

    // After a failed send: another device that's probably the same computer and can be reached right now.
    string SimilarReachableHint(Peer failed)
    {
        static bool Overlap(string a, string b) => a.Contains(b, StringComparison.OrdinalIgnoreCase) || b.Contains(a, StringComparison.OrdinalIgnoreCase);
        var tailscale = TailscaleNetwork.FindAddresses().Count > 0;
        var other = _peers.FirstOrDefault(p => p != failed && p.IsPaired && !p.IsPhone && Overlap(p.Name, failed.Name)
            && (p.Platform.Length == 0 || failed.Platform.Length == 0 || p.Platform == failed.Platform)
            && (LanDiscovery.Find(p) is not null || (p.Host.Length > 0 && tailscale)));
        return other is null ? "" : $" Try \u201c{other.Name}\u201d.";
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

    // Ask desktops what they are (so phones, which never answer, are the only ones queued), learn their device
    // ids and certificates over Tailscale, and merge a device paired both over Tailscale and over Wi-Fi.
    async System.Threading.Tasks.Task LearnPlatformsAsync()
    {
        if (Application.Current is not App app)
            return;
        await app.LearnAndMergePeersAsync();
        _settings = SettingsStore.Load();
        ShowPeers();
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

    // Saved per device, so Settings can show which path it last took.
    static void RememberPath(Peer peer, string path)
    {
        if (peer.LastPath == path)
            return;
        peer.LastPath = path;
        SettingsStore.Update(s =>
        {
            if (s.FindPeer(peer.Name) is { } saved)
                saved.LastPath = path;
        });
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

        if (paths.FirstOrDefault(p => !File.Exists(p)) is { } missing)
        {
            ShowStatus(InfoBarSeverity.Warning, $"{Path.GetFileName(missing)} isn't there anymore. Remove it and try again.");
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
        // Something shows the moment Send is clicked: the status tile (in place of any previous "Sent", so a send
        // after a send changes no heights), with the path being tried, a moving bar, and Cancel. Files show bytes.
        StatusBar.IsOpen = false;
        Progress.Value = 0;
        Progress.IsIndeterminate = paths.Count == 0;
        Progress.Visibility = Visibility.Visible;
        ShowTile(SymbolRegular.ArrowSync24, $"Sending to {peer.Name}…", busy: true);
        using var cancel = new System.Threading.CancellationTokenSource();
        _sendCancel = cancel;
        // An update waits for this send to finish.
        var app = (App)Application.Current;
        app.ActiveSends++;
        var stage = new Progress<string>(message =>
        {
            if (!cancel.IsCancellationRequested)
                SuccessText.Text = message;
        });
        try
        {
            async System.Threading.Tasks.Task SendDirectAsync()
            {
                SendOutcome? outcome = null;
                if (paths.Count > 0)
                    outcome = await Sender.SendFilesAsync(peer, peer.Token, paths, progress, cancel.Token, stage);
                if (text.Length > 0)
                    outcome = await Sender.SendTextAsync(peer, peer.Token, text, cancel.Token, stage);
                if (outcome is not null)
                    RememberPath(peer, outcome.Path);
                ShowStatus(InfoBarSeverity.Success, $"Sent to {peer.Name} ({outcome?.Label}).");
                if (outcome is { IdentityChanged: true })
                    app.Notify($"{peer.Name}'s identity changed", "Droprr used Tailscale instead of Wi-Fi. Pair again to use Wi-Fi.");
            }

            // A phone that gave this PC a token and is open on this network takes the items directly. It can close
            // Droprr at any moment, so if nothing got through, the items are queued for it instead.
            var queue = peer.IsPhone && !(peer.Token.Length > 0 && await Sender.IsOnLanAsync(peer, cancel.Token));
            if (!queue)
            {
                try
                {
                    await SendDirectAsync();
                }
                catch (System.Net.Http.HttpRequestException) when (peer.IsPhone && !cancel.IsCancellationRequested && done == 0)
                {
                    queue = true;
                }
            }
            if (queue)
            {
                foreach (var path in paths)
                    await Outbox.EnqueueFileAsync(peer.Name, path, progress, cancel.Token);
                if (text.Length > 0)
                    Outbox.EnqueueText(peer.Name, Sender.TextType(text), text);
                // Queuing for a phone is quiet: its "N waiting" badge and the tray count show the result.
                HideStatus();
                ShowPeers();
            }
            if (clearWindow)
            {
                _files.Clear();
                MessageText.Clear();
            }
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            ShowTile(SymbolRegular.Dismiss24, "Canceled. Nothing was sent.", busy: false);
            CancelSendButton.Visibility = Visibility.Collapsed;
        }
        catch (Exception ex) when (cancel.IsCancellationRequested)
        {
            ShowTile(SymbolRegular.Dismiss24, "Canceled.", busy: false);
            CancelSendButton.Visibility = Visibility.Collapsed;
            System.Diagnostics.Debug.WriteLine(ex);
        }
        catch (Exception ex)
        {
            ShowStatus(InfoBarSeverity.Error, ex.Message.Contains(peer.Name, StringComparison.Ordinal)
                ? ex.Message + SimilarReachableHint(peer)
                : $"{peer.Name}: {ex.Message}{SimilarReachableHint(peer)}");
        }
        finally
        {
            app.ActiveSends--;
            _sendCancel = null;
            SendButton.IsEnabled = true;
            UpdateSendClipboard();
            Progress.IsIndeterminate = false;
            Progress.Visibility = Visibility.Collapsed;
        }
    }
}
