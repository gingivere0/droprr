using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using Wpf.Ui.Controls;
using Forms = System.Windows.Forms;
using MenuItem = Wpf.Ui.Controls.MenuItem;
using TextBlock = System.Windows.Controls.TextBlock;

namespace Droprr;

sealed class TrayIcon : IDisposable
{
    readonly Forms.NotifyIcon _icon;
    // A WPF menu rather than a WinForms one, so WPF UI styles it: rounded corners, light or dark, Fluent icons.
    readonly ContextMenu _menu = new();
    readonly MenuItem _status = new() { IsEnabled = false };
    readonly MenuItem _pending = new() { IsEnabled = false, Visibility = Visibility.Collapsed };
    readonly List<MenuItem> _clearItems = new();
    readonly App _app;
    readonly MenuItem _recentMenu = MenuEntry("Recent", SymbolRegular.History24);
    // Invisible window the menu opens from: a tray menu only closes on an outside click when its window has focus.
    readonly Window _anchor = new()
    {
        // An explicit empty style keeps WPF UI's window style off it, which would try to change
        // AllowsTransparency after the window is shown and throw.
        Style = new Style(typeof(Window)),
        WindowStyle = WindowStyle.None,
        ResizeMode = ResizeMode.NoResize,
        ShowInTaskbar = false,
        Width = 0,
        Height = 0,
        Left = -32000,
        Top = -32000,
    };
    ReceivedItem? _lastNotified;
    string _statusText = "Starting…";
    string _pendingText = "";

    public TrayIcon(App app)
    {
        _app = app;
        _status.Header = _statusText;
        _menu.Items.Add(_status);
        _menu.Items.Add(_pending);
        _menu.Items.Add(new Separator());
        _menu.Items.Add(MenuEntry("Send to device…", SymbolRegular.Send24, () => app.ShowSendWindow([])));
        _menu.Items.Add(_recentMenu);
        _menu.Items.Add(MenuEntry("Open in a browser…", SymbolRegular.Globe24, app.ShowBrowserAccess));
        _menu.Items.Add(MenuEntry("Open Droprr folder", SymbolRegular.FolderOpen24, () => OpenFolder(app.Settings.ResolveSaveFolder())));
        _menu.Items.Add(new Separator());
        _menu.Items.Add(MenuEntry("Settings…", SymbolRegular.Settings24, () => app.ShowSettings()));
        _menu.Items.Add(MenuEntry("Exit", SymbolRegular.Power24, app.ExitApp));
        _menu.Placement = PlacementMode.MousePoint;
        _menu.PlacementTarget = _anchor;
        _menu.Closed += (_, _) => _anchor.Hide();

        _icon = new Forms.NotifyIcon
        {
            Icon = AppIcon.CreateTrayIcon(),
            Text = "Droprr",
            Visible = true,
        };
        // A left click opens the Send window; a right click opens the menu.
        _icon.MouseUp += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left)
                app.ShowSendWindow([]);
            else if (e.Button == Forms.MouseButtons.Right)
                ShowMenu();
        };
        _icon.BalloonTipClicked += (_, _) => OnNotificationClicked();
        AppIcon.Changed += OnLogoChanged;
        UpdateRecent([]);
    }

    static MenuItem MenuEntry(string text, SymbolRegular symbol, Action? onClick = null)
    {
        var item = new MenuItem
        {
            Header = new TextBlock { Text = text },
            Icon = new SymbolIcon(symbol),
        };
        if (onClick is not null)
            item.Click += (_, _) => onClick();
        return item;
    }

    void ShowMenu()
    {
        UpdateRecent(_recentItems); // recheck for moved or deleted files
        _anchor.Show();
        SetForegroundWindow(new WindowInteropHelper(_anchor).Handle);
        _menu.IsOpen = true;
    }

    public void SetStatus(string text)
    {
        _statusText = text;
        _status.Header = new TextBlock { Text = text };
        UpdateTooltip();
    }

    // Shows how many items are waiting for each phone to check in.
    public void SetPending(IReadOnlyList<(string Peer, int Count)> pending)
    {
        // One "Clear…" entry per phone with items waiting, right under the count.
        foreach (var item in _clearItems)
            _menu.Items.Remove(item);
        _clearItems.Clear();
        var at = _menu.Items.IndexOf(_pending) + 1;
        foreach (var (peer, _) in pending)
        {
            var label = pending.Count == 1 ? "Clear waiting items" : $"Clear items waiting for {peer}";
            var clear = MenuEntry(label, SymbolRegular.Delete24, () => _app.ClearWaiting(peer));
            _clearItems.Add(clear);
            _menu.Items.Insert(at++, clear);
        }

        _pendingText = string.Join(", ", pending.Select(p => $"{p.Count} waiting for {p.Peer}"));
        _pending.Header = new TextBlock { Text = _pendingText };
        _pending.Visibility = _pendingText.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateTooltip();
    }

    void UpdateTooltip() =>
        _icon.Text = Truncate(_pendingText.Length > 0 ? $"Droprr: {_statusText}\n{_pendingText}" : $"Droprr: {_statusText}", 127);

    public void Notify(string title, string text, ReceivedItem? item = null)
    {
        _lastNotified = item;
        _icon.ShowBalloonTip(4000, title, Truncate(text, 200), Forms.ToolTipIcon.None);
    }

    IReadOnlyList<RecentItem> _recentItems = [];

    // Each recent item gets a submenu: Open, Copy, and (for files) Show in folder. A file that has been moved
    // or deleted shows that instead, with its actions disabled.
    public void UpdateRecent(IReadOnlyList<RecentItem> items)
    {
        _recentItems = items;
        _recentMenu.Items.Clear();
        if (items.Count == 0)
        {
            _recentMenu.Items.Add(new MenuItem { Header = new TextBlock { Text = "Nothing yet" }, IsEnabled = false });
            return;
        }
        foreach (var recent in items)
        {
            var item = recent.Item;
            var entry = MenuEntry(Truncate($"{recent.KindLabel}: {recent.Name}", 60), recent.Symbol);
            if (recent.IsMissing)
                entry.Items.Add(new MenuItem { Header = new TextBlock { Text = "File moved or deleted" }, IsEnabled = false });
            var open = MenuEntry("Open", SymbolRegular.Open24, () => ReceivedActions.Open(item));
            var copy = MenuEntry("Copy", SymbolRegular.Copy24, () => ReceivedActions.Copy(item));
            open.IsEnabled = copy.IsEnabled = recent.IsAvailable;
            entry.Items.Add(open);
            entry.Items.Add(copy);
            if (recent.IsFile)
            {
                var show = MenuEntry("Show in folder", SymbolRegular.FolderOpen24, () => ReceivedActions.ShowInFolder(item));
                show.IsEnabled = recent.IsAvailable;
                entry.Items.Add(show);
            }
            _recentMenu.Items.Add(entry);
        }
    }

    // Files open, links open in the browser, and text (already on the clipboard) brings up the Recent menu.
    void OnNotificationClicked()
    {
        if (_lastNotified is null)
            return;
        if (_lastNotified.Kind == ItemKind.Text)
        {
            ShowMenu();
            _recentMenu.IsSubmenuOpen = true;
            return;
        }
        ReceivedActions.Open(_lastNotified);
    }

    static void OpenFolder(string folder)
    {
        Directory.CreateDirectory(folder);
        Launch("explorer.exe", $"\"{folder}\"");
    }

    static void Launch(string file, string arguments) =>
        Process.Start(new ProcessStartInfo(file, arguments) { UseShellExecute = true });

    static string Truncate(string text, int max) => text.Length <= max ? text : text[..(max - 1)] + "…";

    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr window);

    // The tray icon follows the theme's logo colors.
    void OnLogoChanged()
    {
        var old = _icon.Icon;
        _icon.Icon = AppIcon.CreateTrayIcon();
        old?.Dispose();
    }

    public void Dispose()
    {
        AppIcon.Changed -= OnLogoChanged;
        _menu.IsOpen = false;
        _anchor.Close();
        _icon.Visible = false;
        _icon.Dispose();
    }
}
