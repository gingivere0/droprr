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
