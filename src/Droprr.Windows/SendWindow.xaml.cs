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

    async void OnSend(object sender, RoutedEventArgs e)
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
        var text = MessageText.Text.Trim();
        if (_files.Count == 0 && text.Length == 0)
        {
            ShowStatus(InfoBarSeverity.Informational, "Add files or type some text first.");
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
            _files.Clear();
            MessageText.Clear();
        }
        catch (Exception ex)
        {
            ShowStatus(InfoBarSeverity.Error, $"{peer.Name}: {ex.Message}");
        }
        finally
        {
            SendButton.IsEnabled = true;
            Progress.Visibility = Visibility.Collapsed;
        }
    }
}
