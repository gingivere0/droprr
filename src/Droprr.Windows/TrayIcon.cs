using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows.Forms;

namespace Droprr;

sealed class TrayIcon : IDisposable
{
    readonly App _app;
    readonly NotifyIcon _icon;
    readonly ToolStripMenuItem _status;
    readonly ToolStripMenuItem _recentMenu;
    readonly ToolStripMenuItem _pending = new() { Enabled = false, Visible = false };
    ReceivedItem? _lastNotified;
    string _statusText = "Starting…";
    string _pendingText = "";

    public TrayIcon(App app)
    {
        _app = app;
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
        menu.Items.Add("Copy token", null, (_, _) => ClipboardHelper.TrySetText(app.Settings.Token));
        menu.Items.Add("Edit settings", null, (_, _) => Launch("notepad.exe", $"\"{SettingsStore.FilePath}\""));
        menu.Items.Add("Reload settings", null, async (_, _) => await app.ReloadAsync());
        menu.Items.Add("Exit", null, (_, _) => app.ExitApp());

        _icon = new NotifyIcon
        {
            Icon = AppIcon.Create(),
            Text = "Droprr",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _icon.DoubleClick += (_, _) => app.ShowSendWindow([]);
        _icon.BalloonTipClicked += (_, _) =>
        {
            if (_lastNotified is not null)
                Open(_lastNotified);
        };
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
        _icon.ShowBalloonTip(4000, title, Truncate(text, 200), ToolTipIcon.Info);
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

    // Files are shown in Explorer, links open in the browser, and text goes back on the clipboard.
    static void Open(ReceivedItem item)
    {
        switch (item.Kind)
        {
            case ItemKind.File when item.Path is not null && File.Exists(item.Path):
                Launch("explorer.exe", $"/select,\"{item.Path}\"");
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

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
