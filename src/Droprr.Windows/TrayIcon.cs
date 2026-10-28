using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Droprr;

sealed class TrayIcon : IDisposable
{
    // Received files with these extensions are shown in Explorer instead of being run on a click.
    static readonly HashSet<string> RunnableExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".exe", ".com", ".bat", ".cmd", ".msi", ".msix", ".appx", ".ps1", ".psm1", ".vbs", ".vbe", ".js", ".jse",
        ".wsf", ".wsh", ".scr", ".pif", ".cpl", ".hta", ".lnk", ".url", ".reg", ".jar", ".application",
    };

    readonly NotifyIcon _icon;
    readonly ToolStripMenuItem _status;
    readonly ToolStripMenuItem _recentMenu;
    readonly ToolStripMenuItem _pending = new() { Enabled = false, Visible = false };
    ReceivedItem? _lastNotified;
    string _statusText = "Starting…";
    string _pendingText = "";

    public TrayIcon(App app)
    {
        _status = new ToolStripMenuItem("Starting…") { Enabled = false };
        _recentMenu = new ToolStripMenuItem("Recent");

        var menu = new ContextMenuStrip();
        menu.Items.Add(_status);
        menu.Items.Add(_pending);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Send to device…", null, (_, _) => app.ShowSendWindow([]));
        menu.Items.Add(_recentMenu);
        menu.Items.Add("Open Droprr folder", null, (_, _) => OpenFolder(app.Settings.ResolveSaveFolder()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Settings…", null, (_, _) => app.ShowSettings());
        menu.Items.Add("Exit", null, (_, _) => app.ExitApp());

        _icon = new NotifyIcon
        {
            Icon = AppIcon.CreateTrayIcon(),
            Text = "Droprr",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _icon.DoubleClick += (_, _) => app.ShowSendWindow([]);
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        _icon.BalloonTipClicked += (_, _) => OnNotificationClicked();
        UpdateRecent([]);
    }

    public void SetStatus(string text)
    {
        _statusText = text;
        _status.Text = text;
        UpdateTooltip();
    }

    // Shows how many items are waiting for each phone to check in.
    public void SetPending(IReadOnlyList<(string Peer, int Count)> pending)
    {
        _pendingText = string.Join(", ", pending.Select(p => $"{p.Count} waiting for {p.Peer}"));
        _pending.Text = _pendingText;
        _pending.Visible = _pendingText.Length > 0;
        UpdateTooltip();
    }

    void UpdateTooltip() =>
        _icon.Text = Truncate(_pendingText.Length > 0 ? $"Droprr: {_statusText}\n{_pendingText}" : $"Droprr: {_statusText}", 127);

    public void Notify(string title, string text, ReceivedItem? item = null)
    {
        _lastNotified = item;
        _icon.ShowBalloonTip(4000, title, Truncate(text, 200), ToolTipIcon.None);
    }

    public void UpdateRecent(IReadOnlyList<ReceivedItem> items)
    {
        _recentMenu.DropDownItems.Clear();
        if (items.Count == 0)
        {
            _recentMenu.DropDownItems.Add(new ToolStripMenuItem("Nothing yet") { Enabled = false });
            return;
        }
        foreach (var item in items)
        {
            var prefix = item.Kind switch { ItemKind.File => "File", ItemKind.Url => "Link", _ => "Text" };
            var label = Truncate($"{prefix}: {item.Display.ReplaceLineEndings(" ")}", 60).Replace("&", "&&");
            _recentMenu.DropDownItems.Add(label, null, (_, _) => Open(item));
        }
    }

    // Files open, links open in the browser, and text (already on the clipboard) brings up the Recent menu.
    void OnNotificationClicked()
    {
        if (_lastNotified is null)
            return;
        if (_lastNotified.Kind == ItemKind.Text)
        {
            // NotifyIcon has no public way to open its menu, so use the method a right-click calls.
            typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic)?.Invoke(_icon, null);
            _recentMenu.ShowDropDown();
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

    // Switching between light and dark mode swaps the black and white tray artwork.
    void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (e.Category != UserPreferenceCategory.General)
            return;
        var old = _icon.Icon;
        _icon.Icon = AppIcon.CreateTrayIcon();
        old?.Dispose();
    }

    public void Dispose()
    {
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        _icon.Visible = false;
        _icon.Dispose();
    }
}
