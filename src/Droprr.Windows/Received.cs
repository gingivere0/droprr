using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using Wpf.Ui.Controls;

namespace Droprr;

// One received item in the Recent list (the Send window's Received tile and the tray's Recent menu).
public sealed class RecentItem : INotifyPropertyChanged
{
    public RecentItem(ReceivedItem item)
    {
        Item = item;
        Received = DateTime.Now;
    }

    public ReceivedItem Item { get; }
    public DateTime Received { get; }

    public event PropertyChangedEventHandler? PropertyChanged;

    public string Name => Item.Kind == ItemKind.File ? Item.Display : Truncate(Item.Display.ReplaceLineEndings(" "), 120);

    public string KindLabel => Item.Kind switch { ItemKind.File => "File", ItemKind.Url => "Link", _ => "Text" };

    // Glyphs from the design system's shared meanings (MASTER.md, Iconography).
    public SymbolRegular Symbol => Item.Kind switch
    {
        ItemKind.File => SymbolRegular.Document24,
        ItemKind.Url => SymbolRegular.Link24,
        _ => SymbolRegular.TextAlignLeft24,
    };

    public bool IsFile => Item.Kind == ItemKind.File;

    public bool IsMissing => IsFile && (Item.Path is null || !File.Exists(Item.Path));

    public bool IsAvailable => !IsMissing;

    public string Detail => IsMissing ? "File moved or deleted" : $"{KindLabel} · {Relative(Received)}";

    // Rechecks the file and the relative time ("2 min ago").
    public void Refresh()
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsMissing)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsAvailable)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Detail)));
    }

    static string Relative(DateTime time)
    {
        var age = DateTime.Now - time;
        return age.TotalMinutes < 1 ? "just now"
            : age.TotalHours < 1 ? $"{(int)age.TotalMinutes} min ago"
            : age.TotalDays < 1 ? $"{(int)age.TotalHours} hr ago"
            : time.ToString("MMM d");
    }

    static string Truncate(string text, int max) => text.Length <= max ? text : text[..(max - 1)] + "…";
}

// What a received item can do, shared by the Received tile, the tray's Recent menu, and notifications.
static class ReceivedActions
{
    // Received files of these types open directly; anything else is shown in Explorer instead.
    static readonly HashSet<string> OpenableExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".heic", ".heif",
        ".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi",
        ".mp3", ".m4a", ".wav", ".flac", ".aac", ".ogg",
        ".pdf", ".txt", ".md", ".csv",
    };

    // Files open (or are shown in Explorer), links open in the browser (http and https only), and text is copied.
    public static void Open(ReceivedItem item)
    {
        switch (item.Kind)
        {
            case ItemKind.File when item.Path is not null && File.Exists(item.Path):
                if (OpenableExtensions.Contains(Path.GetExtension(item.Path)))
                    Process.Start(new ProcessStartInfo(item.Path) { UseShellExecute = true });
                else
                    ShowInFolder(item);
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

    // Files go on the clipboard as files (images also as pictures); text and links as text.
    public static void Copy(ReceivedItem item)
    {
        if (item.Kind == ItemKind.File)
        {
            if (item.Path is not null && File.Exists(item.Path))
                ClipboardHelper.TrySetFiles([item.Path]);
        }
        else if (item.Content is not null)
        {
            ClipboardHelper.TrySetText(item.Content);
        }
    }

    public static void ShowInFolder(ReceivedItem item)
    {
        if (item.Path is not null && File.Exists(item.Path))
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{item.Path}\"") { UseShellExecute = true });
    }
}
