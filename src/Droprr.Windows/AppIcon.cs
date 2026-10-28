using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Color = System.Windows.Media.Color;

namespace Droprr;

// The two colors a theme gives the logo, replacing its purple and red halves.
public readonly record struct LogoColors(Color Purple, Color Red);

// The app icon from file-swap-icon-pack/windows/app.ico, for the taskbar, title bars, and tray. The pack is
// raster only (no vector source), so a theme recolors each ICO frame (16 to 256 px) by remapping the purple
// and red hues while keeping each pixel's lightness and transparency; white arrows and highlights stay white.
static class AppIcon
{
    static readonly byte[] Original = Read("app.ico");
    static readonly Dictionary<LogoColors, byte[]> Recolored = new();
    static byte[] _current = Original;
    static ImageSource? _imageSource;

    // Raised on the UI thread when the logo's colors change, so every icon can be replaced.
    public static event Action? Changed;

    public static ImageSource ImageSource => _imageSource ??= Decode(_current);

    // The current icon at the small-icon size for the current DPI.
    public static Icon CreateTrayIcon()
    {
        using var stream = new MemoryStream(_current);
        return new Icon(stream, System.Windows.Forms.SystemInformation.SmallIconSize);
    }

    // Null keeps the original purple and red logo.
    public static void SetColors(LogoColors? colors)
    {
        var next = colors is { } c
            ? Recolored.TryGetValue(c, out var cached) ? cached : Recolored[c] = Recolor(Original, c)
            : Original;
        if (ReferenceEquals(next, _current))
            return;
        _current = next;
        _imageSource = null;
        Changed?.Invoke();
    }

    static byte[] Read(string name)
    {
        using var stream = typeof(AppIcon).Assembly.GetManifestResourceStream($"Droprr.{name}")!;
        using var copy = new MemoryStream();
        stream.CopyTo(copy);
        return copy.ToArray();
    }

    static ImageSource Decode(byte[] ico)
    {
        var decoder = new IconBitmapDecoder(new MemoryStream(ico), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        return decoder.Frames[0];
    }

    // The logo's own colors, from the icon pack (sampled from app-256.png).
    static readonly Hsl SourcePurple = Hsl.From(Color.FromRgb(0x59, 0x1F, 0xFA));
    static readonly Hsl SourceRed = Hsl.From(Color.FromRgb(0xFB, 0x5A, 0x56));

    static byte[] Recolor(byte[] ico, LogoColors colors)
    {
        var purple = Hsl.From(colors.Purple);
        var red = Hsl.From(colors.Red);
        var decoder = new IconBitmapDecoder(new MemoryStream(ico), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        var frames = new List<(int Size, byte[] Png)>();
        foreach (var frame in decoder.Frames)
        {
            var bgra = new FormatConvertedBitmap(frame, PixelFormats.Bgra32, null, 0);
            var width = bgra.PixelWidth;
            var height = bgra.PixelHeight;
            var pixels = new byte[width * height * 4];
            bgra.CopyPixels(pixels, width * 4, 0);
            for (var i = 0; i < pixels.Length; i += 4)
            {
                if (pixels[i + 3] == 0)
                    continue;
                var hsl = Hsl.From(Color.FromRgb(pixels[i + 2], pixels[i + 1], pixels[i]));
                if (hsl.S < 0.25)
                    continue; // white arrows, light highlights, and grays keep their color
                var toPurple = HueDistance(hsl.H, SourcePurple.H);
                var toRed = HueDistance(hsl.H, SourceRed.H);
                if (Math.Min(toPurple, toRed) > 60)
                    continue;
                var (source, target) = toPurple <= toRed ? (SourcePurple, purple) : (SourceRed, red);
                var mapped = new Hsl(
                    (target.H + (hsl.H - source.H) + 360) % 360,
                    Math.Clamp(hsl.S * (target.S / Math.Max(source.S, 0.01)), 0, 1),
                    Math.Clamp(target.L + (hsl.L - source.L), 0, 1)).ToColor();
                pixels[i] = mapped.B;
                pixels[i + 1] = mapped.G;
                pixels[i + 2] = mapped.R;
            }
            var recolored = BitmapSource.Create(width, height, 96, 96, PixelFormats.Bgra32, null, pixels, width * 4);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(recolored));
            using var png = new MemoryStream();
            encoder.Save(png);
            frames.Add((width, png.ToArray()));
        }
        return WriteIco(frames);
    }

    static double HueDistance(double a, double b)
    {
        var d = Math.Abs(a - b) % 360;
        return d > 180 ? 360 - d : d;
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

    readonly record struct Hsl(double H, double S, double L)
    {
        public static Hsl From(Color c)
        {
            double r = c.R / 255.0, g = c.G / 255.0, b = c.B / 255.0;
            var max = Math.Max(r, Math.Max(g, b));
            var min = Math.Min(r, Math.Min(g, b));
            var l = (max + min) / 2;
            if (max == min)
                return new Hsl(0, 0, l);
            var d = max - min;
            var s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
            var h = max == r ? (g - b) / d + (g < b ? 6 : 0) : max == g ? (b - r) / d + 2 : (r - g) / d + 4;
            return new Hsl(h * 60, s, l);
        }

        public Color ToColor()
        {
            if (S == 0)
                return Color.FromRgb(Byte(L), Byte(L), Byte(L));
            var q = L < 0.5 ? L * (1 + S) : L + S - L * S;
            var p = 2 * L - q;
            var h = H / 360;
            return Color.FromRgb(Byte(Channel(p, q, h + 1.0 / 3)), Byte(Channel(p, q, h)), Byte(Channel(p, q, h - 1.0 / 3)));
        }

        static double Channel(double p, double q, double t)
        {
            if (t < 0) t += 1;
            if (t > 1) t -= 1;
            return t < 1.0 / 6 ? p + (q - p) * 6 * t : t < 0.5 ? q : t < 2.0 / 3 ? p + (q - p) * (2.0 / 3 - t) * 6 : p;
        }

        static byte Byte(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255);
    }
}
