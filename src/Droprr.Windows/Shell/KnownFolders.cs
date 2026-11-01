using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace Droprr;

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
