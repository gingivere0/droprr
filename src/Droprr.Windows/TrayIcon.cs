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
using System.Windows.Media;
using Forms = System.Windows.Forms;

namespace Droprr;

sealed class TrayIcon : IDisposable
{
    // Received files with these extensions are shown in Explorer instead of being run on a click.
    static readonly HashSet<string> RunnableExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".exe", ".com", ".bat", ".cmd", ".msi", ".msix", ".appx", ".ps1", ".psm1", ".vbs", ".vbe", ".js", ".jse",
        ".wsf", ".wsh", ".scr", ".pif", ".cpl", ".hta", ".lnk", ".url", ".reg", ".jar", ".application",
    };

    readonly Forms.NotifyIcon _icon;
    // A WPF menu rather than a WinForms one, so it gets the Fluent theme's rounded corners and light or dark colors.
    readonly ContextMenu _menu = new();
    readonly MenuItem _status = new() { IsEnabled = false };
    readonly MenuItem _pending = new() { IsEnabled = false, Visibility = Visibility.Collapsed };
    readonly MenuItem _recentMenu = MenuEntry("Recent", "");
    // Invisible window the menu opens from: a tray menu only closes on an outside click when its window has focus.
    readonly Window _anchor = new()
    {
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
        _status.Header = _statusText;
        _menu.Items.Add(_status);
        _menu.Items.Add(_pending);
        _menu.Items.Add(new Separator());
        _menu.Items.Add(MenuEntry("Send to device…", "", () => app.ShowSendWindow([])));
        _menu.Items.Add(_recentMenu);
        _menu.Items.Add(MenuEntry("Open Droprr folder", "", () => OpenFolder(app.Settings.ResolveSaveFolder())));
        _menu.Items.Add(new Separator());
        _menu.Items.Add(MenuEntry("Settings…", "", app.ShowSettings));
        _menu.Items.Add(MenuEntry("Exit", "", app.ExitApp));
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
        UpdateRecent([]);
    }

    static MenuItem MenuEntry(string text, string glyph, Action? onClick = null)
    {
        var item = new MenuItem
        {
            Header = new TextBlock { Text = text },
            Icon = new TextBlock { Text = glyph, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontSize = 14 },
        };
        if (onClick is not null)
            item.Click += (_, _) => onClick();
        return item;
    }

    void ShowMenu()
    {
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

    public void UpdateRecent(IReadOnlyList<ReceivedItem> items)
    {
        _recentMenu.Items.Clear();
        if (items.Count == 0)
        {
            _recentMenu.Items.Add(new MenuItem { Header = new TextBlock { Text = "Nothing yet" }, IsEnabled = false });
            return;
        }
        foreach (var item in items)
        {
            var (prefix, glyph) = item.Kind switch
            {
                ItemKind.File => ("File", ""),
                ItemKind.Url => ("Link", ""),
                _ => ("Text", ""),
            };
            _recentMenu.Items.Add(MenuEntry(Truncate($"{prefix}: {item.Display.ReplaceLineEndings(" ")}", 60), glyph, () => Open(item)));
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
        Open(_lastNotified);
    }

    static void Open(ReceivedItem item)
    {
        switch (item.Kind)
        {
            case ItemKind.File when item.Path is not null && File.Exists(item.Path):
                if (RunnableExtensions.Contains(Path.GetExtension(item.Path)))
                    Launch("explorer.exe", $"/select,\"{item.Path}\"");
                else
                    Process.Start(new ProcessStartInfo(item.Path) { UseShellExecute = true });
                break;
            case ItemKind.Url when Uri.TryCreate(item.Content, UriKind.Absolute, out var uri)
                                   && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps):
                Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
                break;
            default:
                if (item.Content is not null)
                    ClipboardHelper.TrySetText(item.Content);
                break;
        }
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

    public void Dispose()
    {
        _menu.IsOpen = false;
        _anchor.Close();
        _icon.Visible = false;
        _icon.Dispose();
    }
}
