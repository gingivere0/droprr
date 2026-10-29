using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;
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

    public static bool TrySetText(string text)
    {
        var data = new System.Windows.DataObject();
        data.SetText(text);
        return TrySet(data);
    }

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

    // The clipboard can be briefly locked by another app, so retry a few times. Everything Droprr puts there
    // (received items, the token) is kept out of clipboard history, cloud clipboard, and clipboard monitors.
    static bool TrySet(System.Windows.DataObject data)
    {
        data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[] { 0 }));
        data.SetData("CanIncludeInClipboardHistory", new MemoryStream(BitConverter.GetBytes(0)));
        data.SetData("CanUploadToCloudClipboard", new MemoryStream(BitConverter.GetBytes(0)));
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
            key.SetValue(ValueName, $"\"{exe}\" --background");
        else
            key.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}
