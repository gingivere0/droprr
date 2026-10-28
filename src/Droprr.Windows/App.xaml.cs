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

    // Running state
    Mutex? _instanceMutex;
    readonly CancellationTokenSource _stopListening = new();
    ReceiverServer? _receiver;
    TrayIcon? _tray;

    // Windows
    SendWindow? _sendWindow;
    SettingsWindow? _settingsWindow;
    readonly Dictionary<Guid, ReceiveProgressWindow> _receiving = new();

    // Received items and the clipboard
    readonly List<ReceivedItem> _recent = new();
    readonly List<string> _clipboardFiles = new();
    DispatcherTimer? _clipboardBatch;

    // Background checks
    FileSystemWatcher? _outboxWatcher;
    DispatcherTimer? _outboxRefresh;
    DispatcherTimer? _outboxPurge;
    DispatcherTimer? _networkDebounce;
    DispatcherTimer? _updateCheck;

    internal AppSettings Settings { get; private set; } = null!;

    // Raised on the UI thread after settings change (saved in Settings, or a device paired), so open windows can refresh.
    internal event Action? SettingsSaved;

    // Raised on the UI thread after a device pairs, with its saved peer entry.
    internal event Action<Peer>? DevicePaired;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        try { Shortcuts.SetProcessAppId(); } catch { /* only affects taskbar grouping and notification branding */ }
        AppTheme.Initialize();
        try
        {
            Settings = SettingsStore.Load();
        }
        catch (Exception ex)
        {
            await AppTheme.ShowMessageAsync("Droprr couldn't start", $"Couldn't read {SettingsStore.FilePath}:\n{ex.Message}");
            Shutdown(1);
            return;
        }

        // When taking over from an older build, let it finish exiting and release the lock and port first.
        await Task.Run(() => LiveUpdate.WaitForReplaced(e.Args));

        // Ownership decides, not whether the lock exists: a handle left open by another launch keeps it
        // existing after the old tray exits, and an exited owner leaves it abandoned, which counts as free.
        _instanceMutex = new Mutex(false, @"Local\Droprr.Tray");
        bool isFirstInstance;
        try
        {
            isFirstInstance = _instanceMutex.WaitOne(0);
        }
        catch (AbandonedMutexException)
        {
            isFirstInstance = true;
        }
        if (!isFirstInstance)
        {
            // Already running: hand this launch to it (open Send, with any Send To files), then exit quietly.
            if (!SingleInstance.TryForward(e.Args))
                await AppTheme.ShowMessageAsync("Droprr", "Droprr is already running in the system tray.");
            Shutdown();
            return;
        }
        SingleInstance.Listen(args => Dispatcher.BeginInvoke(() => HandleLaunch(args)), _stopListening.Token);

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
        // Started by the user rather than at sign-in or by an update: show something.
        if (!e.Args.Contains("--background") && !e.Args.Contains("--replace"))
            HandleLaunch(e.Args);
        try { LiveUpdate.RemoveOldVersions(); } catch { /* old folders are only clutter */ }
    }

    // A launch's command line: "--send <files>" from Explorer's Send To, "--settings", or nothing (Search,
    // the Start menu, a double-click), which opens the Send window.
    void HandleLaunch(string[] args)
    {
        if (args.Contains("--background"))
            return;
        if (args.Contains("--settings"))
        {
            ShowSettings();
            return;
        }
        var sendIndex = Array.IndexOf(args, "--send");
        ShowSendWindow(sendIndex >= 0 ? args.Skip(sendIndex + 1) : []);
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
        if (_settingsWindow is not { IsLoaded: true })
        {
            _settingsWindow = new SettingsWindow(this);
            _settingsWindow.Show();
        }
        BringToFront(_settingsWindow);
    }

    // Fallback for phones that never called POST /pair: one that checks its inbox under an unknown name
    // becomes an iPhone peer, so the Send window offers it.
    void OnInboxPolled(string device)
    {
        var known = Settings.FindPeer(device);
        if (known is { IsPhone: true })
            return;
        SavePeer(new PairRequest(device, "ios", null, null, null, null));
        if (known is null)
            _tray?.Notify("New device", $"{device} checked in and can now receive from this PC.");
    }

    // Removes everything waiting for the phone (files too) and updates the tray at once.
    internal void ClearWaiting(string peer)
    {
        Outbox.Clear(peer);
        _tray?.SetPending(Outbox.PendingByPeer());
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
            // Pairing again replaces the device token, so the previous one stops working.
            if (request.AcceptToken is not null)
                peer.AcceptToken = request.AcceptToken;
            // The token this PC sends to the peer: from the caller for computers; phones can't be called.
            if (peer.IsPhone)
                peer.Token = "";
            else if (request.SendToken is not null)
                peer.Token = request.SendToken;
        });
        SettingsSaved?.Invoke();
        return Settings.FindPeer(request.Name)!;
    }

    // Pairs with computers just added or given a new token in Settings: mints a device token for each, calls
    // its POST /pair with the token the user entered, and from then on uses the token it returns. If that
    // fails (for example, an older app), the entered token keeps working.
    internal async Task PairWithComputersAsync(IEnumerable<string> names)
    {
        var host = PairWindow.MagicDnsName() ?? TailscaleNetwork.FindAddresses().FirstOrDefault()?.ToString();
        if (host is null)
            return;
        foreach (var name in names)
        {
            if (Settings.FindPeer(name) is not { IsPhone: false } peer || peer.Token.Length == 0 || peer.Host.Length == 0)
                continue;
            var minted = SettingsStore.NewToken();
            // Accept the new token before asking, since the computer may call back right away.
            Settings = SettingsStore.Update(s => { if (s.FindPeer(name) is { } p) p.AcceptToken = minted; });
            var returned = await Sender.PairAsync(peer, peer.Token, Settings.DeviceName, host, Settings.Port, minted);
            Settings = SettingsStore.Update(s =>
            {
                if (s.FindPeer(name) is not { } p)
                    return;
                if (returned is null)
                    p.AcceptToken = "";
                else
                    p.Token = returned;
            });
            SettingsSaved?.Invoke();
            _tray?.Notify(returned is null ? $"Couldn't pair with {name}" : $"{name} paired",
                returned is null ? "Using the token you entered instead." : "Each of you can now send to the other.");
        }
    }

    // There's one Send window: opening it again adds any files to it and brings it to the front.
    internal void ShowSendWindow(IEnumerable<string> files)
    {
        var paths = files.ToList();
        if (_sendWindow is { IsLoaded: true })
        {
            _sendWindow.AddPaths(paths);
        }
        else
        {
            _sendWindow = new SendWindow(SettingsStore.Load(), paths);
            _sendWindow.Show();
        }
        BringToFront(_sendWindow);
    }

    static void BringToFront(Window window)
    {
        if (window.WindowState == WindowState.Minimized)
            window.WindowState = WindowState.Normal;
        window.Activate();
        // Flipping Topmost raises it even when Windows declines to give it focus.
        window.Topmost = true;
        window.Topmost = false;
        window.Focus();
    }

    // Called after Settings saves: picks up the new settings and restarts the receiver in case the port or token changed.
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
        await StartReceiverAsync();
    }

    internal async Task StartReceiverAsync()
    {
        if (_receiver is not null)
        {
            await _receiver.DisposeAsync();
            _receiver = null;
        }

        var receiver = new ReceiverServer(() => Settings);
        receiver.ItemReceived += item => Dispatcher.BeginInvoke(() => OnItemReceived(item));
        receiver.InboxPolled += device => Dispatcher.BeginInvoke(() => OnInboxPolled(device));
        // Saved before /pair responds, so the caller can use its new token immediately.
        receiver.PairRequested += request => Dispatcher.Invoke(() => OnPairRequested(request));
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
        {
            if (Settings.CopyTextToClipboard)
                ClipboardHelper.TrySetText(item.Content!);
        }
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
            ItemKind.Url => Settings.CopyTextToClipboard ? "Link received and copied" : "Link received",
            _ => Settings.CopyTextToClipboard ? "Text received and copied" : "Text received",
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
        _stopListening.Cancel();
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
