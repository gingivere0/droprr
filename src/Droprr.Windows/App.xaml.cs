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

    readonly List<ReceivedItem> _recent = new();
    Mutex? _instanceMutex;
    ReceiverServer? _receiver;
    TrayIcon? _tray;
    DispatcherTimer? _networkDebounce;
    DispatcherTimer? _outboxRefresh;
    DispatcherTimer? _outboxPurge;
    FileSystemWatcher? _outboxWatcher;

    internal AppSettings Settings { get; private set; } = null!;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
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

        _instanceMutex = new Mutex(true, @"Local\Droprr.Tray", out var isFirstInstance);
        if (!isFirstInstance)
        {
            MessageBox.Show("Droprr is already running in the system tray.", "Droprr");
            Shutdown();
            return;
        }

        try { SendToMenu.Register(); } catch { /* the Send To entry is a convenience; keep running without it */ }
        // Keep the sign-in entry pointing at this exe if Droprr was moved or rebuilt elsewhere.
        try { if (StartWithWindows.IsEnabled) StartWithWindows.Set(true); } catch { /* not fatal */ }

        _tray = new TrayIcon(this);
        WatchOutbox();
        await StartReceiverAsync();
        NetworkChange.NetworkAddressChanged += OnNetworkAddressChanged;
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

    // A phone that checks in under an unknown name becomes an iPhone peer, so the Send window offers it.
    void OnInboxPolled(string device)
    {
        var known = Settings.FindPeer(device);
        if (known is { IsPhone: true })
            return;
        Settings = SettingsStore.Update(s =>
        {
            if (s.FindPeer(device) is { } peer)
                peer.IsPhone = true;
            else
                s.Peers.Add(new Peer { Name = device, Platform = "ios" });
        });
        if (known is null)
            _tray?.Notify("New device", $"{device} checked in and can now receive from this PC.");
    }

    internal void ShowSendWindow(IEnumerable<string> files, bool exitOnClose = false)
    {
        var window = new SendWindow(SettingsStore.Load(), files);
        if (exitOnClose)
            window.Closed += (_, _) => Shutdown();
        window.Show();
        window.Activate();
    }

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

        _recent.Insert(0, item);
        if (_recent.Count > MaxRecent)
            _recent.RemoveRange(MaxRecent, _recent.Count - MaxRecent);
        _tray?.UpdateRecent(_recent);

        var title = item.Kind switch
        {
            ItemKind.File => "File received",
            ItemKind.Url => "Link received and copied",
            _ => "Text received and copied",
        };
        _tray?.Notify(title, item.Display, item);
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
