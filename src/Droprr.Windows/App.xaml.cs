using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace Droprr;

public partial class App : Application
{
    const int MaxRecent = 10;
    const long LargeTransferBytes = 8 * 1024 * 1024;

    readonly Dictionary<Guid, ReceiveProgressWindow> _receiving = new();
    SettingsWindow? _settingsWindow;
    SendWindow? _sendWindow;

    readonly List<ReceivedItem> _recent = new();
    Mutex? _instanceMutex;
    ReceiverServer? _receiver;
    TrayIcon? _tray;
    DispatcherTimer? _networkDebounce;
    DispatcherTimer? _outboxRefresh;
    DispatcherTimer? _outboxPurge;
    DispatcherTimer? _updateCheck;
    DispatcherTimer? _clipboardBatch;
    readonly List<string> _clipboardFiles = new();
    FileSystemWatcher? _outboxWatcher;

    internal AppSettings Settings { get; private set; } = null!;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        try { Shortcuts.SetProcessAppId(); } catch { /* only affects taskbar grouping and notification branding */ }
        try
        {
            Settings = SettingsStore.Load();
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Couldn't read {SettingsStore.FilePath}:\n{ex.Message}", "Droprr");
            Shutdown(1);
            return;
        }

        // Launched from Explorer's Send To menu: show the send window only, no tray or receiver.
        var sendIndex = Array.IndexOf(e.Args, "--send");
        if (sendIndex >= 0)
        {
            ShowSendWindow(e.Args.Skip(sendIndex + 1), exitOnClose: true);
            return;
        }

        if (e.Args.Contains("--settings"))
        {
            ShowSettings();
            _settingsWindow!.Closed += (_, _) => Shutdown();
            return;
        }

        // When taking over from an older build, let it finish exiting and release the lock and port first.
        await Task.Run(() => LiveUpdate.WaitForReplaced(e.Args));

        _instanceMutex = new Mutex(true, @"Local\Droprr.Tray", out var isFirstInstance);
        if (!isFirstInstance)
        {
            MessageBox.Show("Droprr is already running in the system tray.", "Droprr");
            Shutdown();
            return;
        }

        // Conveniences: Droprr keeps running without them.
        try { Shortcuts.RegisterSendTo(); } catch { }
        try { Shortcuts.SyncStartMenu(Settings.AddToStartMenu); } catch { }
        // Keep the sign-in entry pointing at this exe if Droprr was moved or rebuilt elsewhere.
        try { if (StartWithWindows.IsEnabled) StartWithWindows.Set(true); } catch { /* not fatal */ }

        _tray = new TrayIcon(this);
        WatchOutbox();
        _updateCheck = new DispatcherTimer(TimeSpan.FromSeconds(5), DispatcherPriority.Background, (_, _) => CheckForUpdate(), Dispatcher);
        await StartReceiverAsync();
        NetworkChange.NetworkAddressChanged += OnNetworkAddressChanged;

        foreach (var window in LiveUpdate.WindowsToReopen(e.Args))
        {
            if (window == "send")
                ShowSendWindow([]);
            else if (window == "settings")
                ShowSettings();
        }
        try { LiveUpdate.RemoveOldVersions(); } catch { /* old folders are only clutter */ }
    }

    // Keeps the tray's pending count current, whichever Droprr process queued or a phone fetched an item.
    void WatchOutbox()
    {
        Directory.CreateDirectory(Outbox.Root);
        _outboxRefresh = new DispatcherTimer(TimeSpan.FromMilliseconds(500), DispatcherPriority.Background, (_, _) =>
        {
            _outboxRefresh!.Stop();
            _tray?.SetPending(Outbox.PendingByPeer());
        }, Dispatcher);
        _outboxWatcher = new FileSystemWatcher(Outbox.Root, "*.json") { IncludeSubdirectories = true, EnableRaisingEvents = true };
        FileSystemEventHandler changed = (_, _) => Dispatcher.BeginInvoke(() =>
        {
            _outboxRefresh.Stop();
            _outboxRefresh.Start();
        });
        _outboxWatcher.Created += changed;
        _outboxWatcher.Deleted += changed;
        _outboxWatcher.Renamed += (s, e) => changed(s, e);

        // Expired items are also dropped whenever a phone lists its inbox; this catches phones that never return.
        _outboxPurge = new DispatcherTimer(TimeSpan.FromHours(1), DispatcherPriority.Background, (_, _) =>
        {
            Outbox.PurgeExpired();
            _tray?.SetPending(Outbox.PendingByPeer());
        }, Dispatcher);
        Outbox.PurgeExpired();
        _tray?.SetPending(Outbox.PendingByPeer());
    }

    // Hands over to a newer deployed build (see LiveUpdate), waiting until nothing is being received.
    void CheckForUpdate()
    {
        if (_receiving.Count > 0 || LiveUpdate.NewerVersion() is not { } exe)
            return;
        _updateCheck?.Stop();
        var reopen = new List<string>();
        if (_sendWindow is { IsLoaded: true })
            reopen.Add("send");
        if (_settingsWindow is { IsLoaded: true })
            reopen.Add("settings");
        try
        {
            LiveUpdate.StartReplacement(exe, reopen);
        }
        catch (Exception ex)
        {
            _tray?.Notify("Couldn't update Droprr", ex.Message);
            return;
        }
        ExitApp();
    }

    // Large or unknown-size transfers get a progress window; small ones finish before it would be useful.
    void OnReceiveProgress(TransferProgress progress)
    {
        _receiving.TryGetValue(progress.Id, out var window);
        if (progress.Done)
        {
            window?.Close();
            _receiving.Remove(progress.Id);
            return;
        }
        if (window is null)
        {
            if (progress.Total is { } total && total < LargeTransferBytes)
                return;
            window = new ReceiveProgressWindow();
            _receiving[progress.Id] = window;
            window.Show();
        }
        window.Update(progress);
    }

    internal void ShowSettings()
    {
        if (_settingsWindow is { IsLoaded: true })
        {
            _settingsWindow.Activate();
            return;
        }
        _settingsWindow = new SettingsWindow(this);
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    // Fallback for phones that never called POST /pair: one that checks its inbox under an unknown name
    // becomes an iPhone peer, so the Send window offers it.
    void OnInboxPolled(string device)
    {
        var known = Settings.FindPeer(device);
        if (known is { IsPhone: true })
            return;
        SavePeer(new PairRequest(device, "ios", null, null));
        if (known is null)
            _tray?.Notify("New device", $"{device} checked in and can now receive from this PC.");
    }

    // A device scanned this PC's pairing QR and introduced itself, so pairing works in both directions.
    void OnPairRequested(PairRequest request)
    {
        var peer = SavePeer(request);
        _tray?.Notify($"{peer.Name} paired", peer.IsPhone
            ? "Items you send to it wait here until it checks in."
            : "You can now send to it from this PC.");
        DevicePaired?.Invoke(peer);
    }

    // Adds the peer or updates the one with the same name. A host this PC already has (often a MagicDNS
    // name the user typed) is kept for computers; phones never have one.
    Peer SavePeer(PairRequest request)
    {
        Settings = SettingsStore.Update(s =>
        {
            var peer = s.FindPeer(request.Name);
            if (peer is null)
            {
                peer = new Peer { Name = request.Name };
                s.Peers.Add(peer);
            }
            peer.Platform = request.Platform;
            if (peer.IsPhone)
                peer.Host = "";
            else if (peer.Host.Length == 0 && request.Host is not null)
                peer.Host = request.Host;
            if (request.Port is { } port)
                peer.Port = port;
        });
        SettingsSaved?.Invoke();
        return Settings.FindPeer(request.Name)!;
    }

    // Raised on the UI thread after a device pairs, with its saved peer entry.
    internal event Action<Peer>? DevicePaired;

    internal void ShowSendWindow(IEnumerable<string> files, bool exitOnClose = false)
    {
        // Opening it again from the tray brings the open one to the front instead of stacking windows.
        var paths = files.ToList();
        if (paths.Count == 0 && _sendWindow is { IsLoaded: true })
        {
            _sendWindow.Activate();
            return;
        }
        var window = new SendWindow(SettingsStore.Load(), paths);
        if (paths.Count == 0)
            _sendWindow = window;
        if (exitOnClose)
            window.Closed += (_, _) => Shutdown();
        window.Show();
        window.Activate();
    }

    // Raised on the UI thread after Settings saves, so open windows can refresh.
    internal event Action? SettingsSaved;

    internal async Task ReloadAsync()
    {
        try
        {
            Settings = SettingsStore.Load();
        }
        catch (Exception ex)
        {
            _tray?.Notify("Settings error", ex.Message);
            return;
        }
        SettingsSaved?.Invoke();
        // Only the tray instance runs the receiver; a standalone --settings window just saves.
        if (_tray is not null)
            await StartReceiverAsync();
    }

    internal async Task StartReceiverAsync()
    {
        if (_receiver is not null)
        {
            await _receiver.DisposeAsync();
            _receiver = null;
        }

        var receiver = new ReceiverServer(Settings);
        receiver.ItemReceived += item => Dispatcher.BeginInvoke(() => OnItemReceived(item));
        receiver.InboxPolled += device => Dispatcher.BeginInvoke(() => OnInboxPolled(device));
        receiver.PairRequested += request => Dispatcher.BeginInvoke(() => OnPairRequested(request));
        receiver.ReceiveProgress += progress => Dispatcher.BeginInvoke(() => OnReceiveProgress(progress));
        try
        {
            await receiver.StartAsync();
            _receiver = receiver;
            _tray?.SetStatus(receiver.TailscaleAddresses.Count > 0
                ? $"Receiving on port {Settings.Port}"
                : $"Tailscale not found; localhost only (port {Settings.Port})");
        }
        catch (Exception ex)
        {
            await receiver.DisposeAsync();
            _tray?.SetStatus("Receiver stopped");
            _tray?.Notify("Droprr couldn't start receiving", ex.Message);
        }
    }

    void OnItemReceived(ReceivedItem item)
    {
        if (item.Kind is ItemKind.Text or ItemKind.Url)
            ClipboardHelper.TrySetText(item.Content!);
        else if (Settings.CopyFilesToClipboard && item.Path is not null)
            QueueFileForClipboard(item.Path);

        _recent.Insert(0, item);
        if (_recent.Count > MaxRecent)
            _recent.RemoveRange(MaxRecent, _recent.Count - MaxRecent);
        _tray?.UpdateRecent(_recent);

        var title = item.Kind switch
        {
            ItemKind.File when Settings.CopyFilesToClipboard => "File received and copied",
            ItemKind.File => "File received",
            ItemKind.Url => "Link received and copied",
            _ => "Text received and copied",
        };
        _tray?.Notify(title, item.Display, item);
    }

    // Files from one request are announced one after another once all of them are on disk, so gather them
    // briefly and put them on the clipboard together.
    void QueueFileForClipboard(string path)
    {
        _clipboardFiles.Add(path);
        _clipboardBatch ??= new DispatcherTimer(TimeSpan.FromMilliseconds(400), DispatcherPriority.Normal, (_, _) =>
        {
            _clipboardBatch!.Stop();
            ClipboardHelper.TrySetFiles(_clipboardFiles.ToList());
            _clipboardFiles.Clear();
        }, Dispatcher);
        _clipboardBatch.Stop();
        _clipboardBatch.Start();
    }

    // Tailscale's address can appear or change after startup (sign-in, reconnect), so rebind when it does.
    void OnNetworkAddressChanged(object? sender, EventArgs e)
    {
        Dispatcher.BeginInvoke(() =>
        {
            _networkDebounce ??= new DispatcherTimer(TimeSpan.FromSeconds(2), DispatcherPriority.Background, OnNetworkSettled, Dispatcher);
            _networkDebounce.Stop();
            _networkDebounce.Start();
        });
    }

    async void OnNetworkSettled(object? sender, EventArgs e)
    {
        _networkDebounce!.Stop();
        var current = TailscaleNetwork.FindAddresses();
        var bound = _receiver?.TailscaleAddresses ?? [];
        if (_receiver is null || !current.OrderBy(a => a.ToString()).SequenceEqual(bound.OrderBy(a => a.ToString())))
            await StartReceiverAsync();
    }

    internal async void ExitApp()
    {
        NetworkChange.NetworkAddressChanged -= OnNetworkAddressChanged;
        _outboxWatcher?.Dispose();
        _outboxPurge?.Stop();
        _tray?.Dispose();
        _tray = null;
        if (_receiver is not null)
            await _receiver.DisposeAsync();
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        _instanceMutex?.Dispose();
        base.OnExit(e);
    }
}
