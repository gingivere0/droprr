using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Droprr;

// The app icon for the taskbar, title bars, and tray, in the current theme's colors: each theme's logo from
// file-swap-icon-pack/themes/<theme id>/logo-1024.png, the same art the Mac uses, scaled down to icon sizes
// once and cached. The exe's own icon (Explorer, Start menu) is Graphite & Lime's, made at build time by
// scripts/make-app-icon.ps1.
static class AppIcon
{
    const string DefaultTheme = "graphiteLime";
    static readonly int[] Sizes = [16, 20, 24, 32, 48, 64, 256];

    static readonly Dictionary<string, byte[]> Icons = new();
    static byte[] _current = Load(DefaultTheme);
    static string _theme = DefaultTheme;
    static ImageSource? _imageSource;

    // Raised on the UI thread when the logo changes, so every icon can be replaced.
    public static event Action? Changed;

    public static ImageSource ImageSource => _imageSource ??= Decode(_current);

    // The current theme's icon as a multi-size .ico file (16 to 256 px).
    public static byte[] IcoFile => _current;

    // The current icon at the small-icon size for the current DPI.
    public static Icon CreateTrayIcon()
    {
        using var stream = new MemoryStream(_current);
        return new Icon(stream, System.Windows.Forms.SystemInformation.SmallIconSize);
    }

    // The logo doesn't change between light and dark mode, only with the theme.
    public static void SetTheme(string themeId)
    {
        if (themeId == _theme)
            return;
        _theme = themeId;
        _current = Load(themeId);
        _imageSource = null;
        Changed?.Invoke();
    }

    // A theme without a logo uses Graphite & Lime's.
    static byte[] Load(string themeId)
    {
        if (!Icons.TryGetValue(themeId, out var ico))
        {
            var logo = Read($"logo.{themeId}.png");
            ico = logo is null ? Load(DefaultTheme) : BuildIcon(logo);
            Icons[themeId] = ico;
        }
        return ico;
    }

    static byte[]? Read(string name)
    {
        using var stream = typeof(AppIcon).Assembly.GetManifestResourceStream($"Droprr.{name}");
        if (stream is null)
            return null;
        using var copy = new MemoryStream();
        stream.CopyTo(copy);
        return copy.ToArray();
    }

    static ImageSource Decode(byte[] ico)
    {
        var decoder = new IconBitmapDecoder(new MemoryStream(ico), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        return decoder.Frames[0];
    }

    // A multi-size ICO from a 1024 px logo. Halving step by step before the last resize keeps small sizes crisp.
    static byte[] BuildIcon(byte[] logoPng)
    {
        using var logo = new Bitmap(new MemoryStream(logoPng));
        var frames = new List<(int Size, byte[] Png)>();
        foreach (var size in Sizes)
        {
            Bitmap current = new(logo);
            while (current.Width / 2 >= size * 2)
            {
                var half = Resize(current, current.Width / 2);
                current.Dispose();
                current = half;
            }
            using var final = Resize(current, size);
            current.Dispose();
            using var png = new MemoryStream();
            final.Save(png, ImageFormat.Png);
            frames.Add((size, png.ToArray()));
        }
        return WriteIco(frames);
    }

    static Bitmap Resize(Bitmap source, int size)
    {
        var result = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(result);
        g.CompositingMode = CompositingMode.SourceCopy;
        g.CompositingQuality = CompositingQuality.HighQuality;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.SmoothingMode = SmoothingMode.HighQuality;
        using var attributes = new ImageAttributes();
        attributes.SetWrapMode(WrapMode.TileFlipXY); // no dark fringe at the edges
        g.DrawImage(source, new Rectangle(0, 0, size, size), 0, 0, source.Width, source.Height, GraphicsUnit.Pixel, attributes);
        return result;
    }

    // An ICO file whose entries are PNG images, which Windows Vista and later read at every size.
    static byte[] WriteIco(List<(int Size, byte[] Png)> frames)
    {
        using var output = new MemoryStream();
        using var writer = new BinaryWriter(output);
        writer.Write((short)0);
        writer.Write((short)1);
        writer.Write((short)frames.Count);
        var offset = 6 + 16 * frames.Count;
        foreach (var (size, png) in frames)
        {
            writer.Write((byte)(size >= 256 ? 0 : size));
            writer.Write((byte)(size >= 256 ? 0 : size));
            writer.Write((byte)0);
            writer.Write((byte)0);
            writer.Write((short)1);
            writer.Write((short)32);
            writer.Write(png.Length);
            writer.Write(offset);
            offset += png.Length;
        }
        foreach (var (_, png) in frames)
            writer.Write(png);
        writer.Flush();
        return output.ToArray();
    }
}
