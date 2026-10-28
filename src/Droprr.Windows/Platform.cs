using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace Droprr;

static class TailscaleNetwork
{
    // Tailscale hands out IPv4 addresses from the CGNAT range 100.64.0.0/10.
    public static IReadOnlyList<IPAddress> FindAddresses() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(n => n.OperationalStatus == OperationalStatus.Up)
        .SelectMany(n => n.GetIPProperties().UnicastAddresses)
        .Select(u => u.Address)
        .Where(IsTailscale)
        .Distinct()
        .ToList();

    static bool IsTailscale(IPAddress address)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork)
            return false;
        var bytes = address.GetAddressBytes();
        return bytes[0] == 100 && (bytes[1] & 0xC0) == 0x40;
    }
}

static class KnownFolders
{
    static readonly Guid DownloadsId = new("374DE290-123F-4565-9164-39C4925E467B");

    public static string Downloads
    {
        get
        {
            if (SHGetKnownFolderPath(DownloadsId, 0, IntPtr.Zero, out var path) == 0)
                return path;
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHGetKnownFolderPath(
        [MarshalAs(UnmanagedType.LPStruct)] Guid folderId, uint flags, IntPtr token,
        [MarshalAs(UnmanagedType.LPWStr)] out string path);
}

static class ClipboardHelper
{
    static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".heic", ".heif",
    };

    public static bool TrySetText(string text) => TrySet(text);

    // Files go on as a drop list marked "copy", so pasting in Explorer or a chat app pastes the files. If one
    // of them is an image Windows can decode (HEIC needs Microsoft's HEIF extension), it goes on as a picture
    // too, so pasting into Paint or a chat box gives the image.
    public static bool TrySetFiles(IReadOnlyList<string> paths)
    {
        var data = new System.Windows.DataObject();
        var drop = new System.Collections.Specialized.StringCollection();
        drop.AddRange(paths.ToArray());
        data.SetFileDropList(drop);
        data.SetData("Preferred DropEffect", new MemoryStream(BitConverter.GetBytes((int)System.Windows.DragDropEffects.Copy)));
        if (paths.Where(p => ImageExtensions.Contains(Path.GetExtension(p))).Select(LoadImage).FirstOrDefault(i => i is not null) is { } image)
            data.SetImage(image);
        return TrySet(data);
    }

    static BitmapSource? LoadImage(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            var frame = BitmapFrame.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            frame.Freeze();
            return frame;
        }
        catch (Exception ex) when (ex is NotSupportedException or FileFormatException or IOException or ArgumentException or COMException)
        {
            return null;
        }
    }

    // The clipboard can be briefly locked by another app, so retry a few times.
    static bool TrySet(object data)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                System.Windows.Clipboard.SetDataObject(data, copy: true);
                return true;
            }
            catch (COMException)
            {
                Thread.Sleep(50);
            }
        }
        return false;
    }
}

static class AppIcon
{
    // Artwork from file-swap-icon-pack/windows, embedded so tray and windows match the exe.
    static Stream Open(string name) => typeof(AppIcon).Assembly.GetManifestResourceStream($"Droprr.{name}")!;

    // The colored app icon at the small-icon size for the current DPI.
    public static Icon CreateTrayIcon()
    {
        using var stream = Open("app.ico");
        return new Icon(stream, System.Windows.Forms.SystemInformation.SmallIconSize);
    }

    static ImageSource? _imageSource;

    public static ImageSource ImageSource => _imageSource ??= LoadImageSource();

    static ImageSource LoadImageSource()
    {
        using var stream = Open("app.ico");
        var decoder = new IconBitmapDecoder(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        return decoder.Frames[0];
    }
}

static class StartWithWindows
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ValueName = "Droprr";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(ValueName) is string;
        }
    }

    public static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled && Environment.ProcessPath is { } exe)
            key.SetValue(ValueName, $"\"{exe}\"");
        else
            key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}
