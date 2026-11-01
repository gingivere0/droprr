using System;
using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;

namespace Droprr;

// A picture on the clipboard (a screenshot from Win+Shift+S or Print Screen, or an image copied from a browser)
// has no file behind it, so Send clipboard and Ctrl+V save it as a PNG first, the way the Mac and iPhone apps do.
static class ClipboardImage
{
    static string Folder => Path.Combine(Path.GetTempPath(), "Droprr", "Clipboard");

    // The saved PNG's path, or null when the clipboard holds no picture (or it can't be read).
    public static string? SaveToFile()
    {
        try
        {
            if (!Clipboard.ContainsImage() || Clipboard.GetImage() is not { } image)
                return null;
            Directory.CreateDirectory(Folder);
            RemoveOld();
            var path = Path.Combine(Folder, $"Clipboard {DateTime.Now:yyyy-MM-dd HHmmss}.png");
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(image));
            using (var file = File.Create(path))
                encoder.Save(file);
            return path;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            return null;
        }
    }

    // Pictures saved for earlier sends are only needed while they upload (or wait in a phone's outbox, which
    // keeps its own copy), so anything older than a day goes.
    static void RemoveOld()
    {
        foreach (var file in Directory.EnumerateFiles(Folder, "*.png"))
        {
            try
            {
                if (File.GetLastWriteTimeUtc(file) < DateTime.UtcNow.AddDays(-1))
                    File.Delete(file);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
