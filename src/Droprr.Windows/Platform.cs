using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

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

static class SendToMenu
{
    // Adds "Droprr" to Explorer's Send To menu; Explorer passes the selected files after --send.
    public static void Register()
    {
        var exe = Environment.ProcessPath;
        if (exe is null || Path.GetFileName(exe).Equals("dotnet.exe", StringComparison.OrdinalIgnoreCase))
            return;

        var shellType = Type.GetTypeFromProgID("WScript.Shell");
        if (shellType is null)
            return;

        var link = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.SendTo), "Droprr.lnk");
        dynamic shell = Activator.CreateInstance(shellType)!;
        try
        {
            dynamic shortcut = shell.CreateShortcut(link);
            shortcut.TargetPath = exe;
            shortcut.Arguments = "--send";
            shortcut.WorkingDirectory = Path.GetDirectoryName(exe);
            shortcut.Description = "Send to another device with Droprr";
            shortcut.Save();
        }
        finally
        {
            Marshal.FinalReleaseComObject(shell);
        }
    }
}

static class ClipboardHelper
{
    // The clipboard can be briefly locked by another app, so retry a few times.
    public static bool TrySetText(string text)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                System.Windows.Clipboard.SetDataObject(text, copy: true);
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
    // Drawn at runtime so the repo needs no binary icon file.
    public static Icon Create()
    {
        using var bitmap = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using var background = new SolidBrush(System.Drawing.Color.FromArgb(37, 99, 235));
            g.FillEllipse(background, 1, 1, 30, 30);
            using var pen = new System.Drawing.Pen(System.Drawing.Color.White, 3.5f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            g.DrawLine(pen, 16, 8, 16, 23);
            g.DrawLine(pen, 10, 17, 16, 23);
            g.DrawLine(pen, 22, 17, 16, 23);
        }
        var handle = bitmap.GetHicon();
        try
        {
            using var temporary = Icon.FromHandle(handle);
            return (Icon)temporary.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    public static ImageSource CreateImageSource()
    {
        using var icon = Create();
        return Imaging.CreateBitmapSourceFromHIcon(icon.Handle, System.Windows.Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
    }

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr handle);
}
