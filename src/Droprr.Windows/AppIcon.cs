using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace Droprr;

// The app icon for the taskbar, title bars, and tray, in the current theme's colors: each theme's logo from
// file-swap-icon-pack/themes/<theme id>/logo-1024.png, the same art the Mac uses, scaled down to icon sizes
// once and cached. The exe's own icon (Explorer, Start menu) is Graphite & Lime's, made at build time by
// scripts/make-app-icon.ps1.
//
// On a dark taskbar, a logo half with less than 3:1 contrast against it is recolored so the whole logo reads:
// a near-neutral half (Graphite & Lime's graphite) takes the theme's dark-mode textSecondary, and a colored half
// keeps its hue, lightened just enough to reach 3:1. Shading is kept. A light taskbar gets the true art.
static class AppIcon
{
    const string DefaultTheme = "graphiteLime";
    static readonly int[] Sizes = [16, 20, 24, 32, 48, 64, 256];

    // Windows 11's dark taskbar.
    static readonly Rgb DarkTaskbar = new(0x20 / 255.0, 0x20 / 255.0, 0x20 / 255.0);

    static readonly Dictionary<(string Theme, bool Dark), byte[]> Icons = new();
    static bool _darkTaskbar = TaskbarIsDark();
    static byte[] _current = Load(DefaultTheme, _darkTaskbar);
    static string _theme = DefaultTheme;
    static ImageSource? _imageSource;

    static AppIcon()
    {
        // Follow the taskbar when Windows switches between light and dark.
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category == UserPreferenceCategory.General)
                System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => Update(_theme, TaskbarIsDark()));
        };
    }

    // Raised on the UI thread when the logo changes, so every icon can be replaced.
    public static event Action? Changed;

    public static ImageSource ImageSource => _imageSource ??= Decode(_current);

    // The current icon at the small-icon size for the current DPI.
    public static Icon CreateTrayIcon()
    {
        using var stream = new MemoryStream(_current);
        return new Icon(stream, System.Windows.Forms.SystemInformation.SmallIconSize);
    }

    public static void SetTheme(string themeId) => Update(themeId, _darkTaskbar);

    static void Update(string themeId, bool darkTaskbar)
    {
        if (themeId == _theme && darkTaskbar == _darkTaskbar)
            return;
        _theme = themeId;
        _darkTaskbar = darkTaskbar;
        _current = Load(themeId, darkTaskbar);
        _imageSource = null;
        Changed?.Invoke();
    }

    // A theme without a logo uses Graphite & Lime's.
    static byte[] Load(string themeId, bool darkTaskbar)
    {
        if (!Icons.TryGetValue((themeId, darkTaskbar), out var ico))
        {
            if (Read($"logo.{themeId}.png") is not { } png)
                ico = Load(DefaultTheme, darkTaskbar);
            else
            {
                using var logo = new Bitmap(new MemoryStream(png));
                if (darkTaskbar)
                    ForDarkTaskbar(logo, ThemeCatalog.Find(themeId));
                ico = BuildIcon(logo);
            }
            Icons[(themeId, darkTaskbar)] = ico;
        }
        return ico;
    }

    static bool TaskbarIsDark()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is 0;
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

    // The logo's halves are the theme's light-mode accent (top) and secondary (bottom). A half that fails 3:1 against the taskbar moves to its replacement color, keeping the
    // pixel's lightness and saturation relative to the half's own color.
    static void ForDarkTaskbar(Bitmap logo, ThemeDef theme)
    {
        Rgb[] halves = [Rgb.From(theme.Light.Accent), Rgb.From(theme.Light.Secondary)];
        var bases = halves.Select(h => h.ToHsl()).ToArray();
        var targets = halves.Select((h, i) => Contrast(h, DarkTaskbar) >= 3 ? (Hsl?)null
            : bases[i].S < 0.15 ? Rgb.From(theme.Dark.TextSecondary).ToHsl()
            : Lighten(bases[i])).ToArray();
        if (targets.All(t => t is null))
            return;

        var data = logo.LockBits(new Rectangle(0, 0, logo.Width, logo.Height), ImageLockMode.ReadWrite,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        var pixels = new byte[data.Stride * data.Height];
        Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
        for (var o = 0; o < pixels.Length; o += 4)
        {
            if (pixels[o + 3] == 0)
                continue;
            var p = new Rgb(pixels[o + 2] / 255.0, pixels[o + 1] / 255.0, pixels[o] / 255.0);
            var hsl = p.ToHsl();
            // White and near-white (the arrows' edges, the folded corner's highlight) stay.
            if (hsl.L > 0.85 && hsl.S < 0.25)
                continue;
            var i = Half(hsl, bases);
            if (targets[i] is not { } target)
                continue;
            var b = bases[i];
            var n = new Hsl(target.H, Math.Min(1, b.S < 0.01 ? target.S : target.S * hsl.S / b.S),
                Math.Clamp(target.L + (hsl.L - b.L), 0.03, 0.97)).ToRgb();
            pixels[o + 2] = (byte)Math.Round(n.R * 255);
            pixels[o + 1] = (byte)Math.Round(n.G * 255);
            pixels[o] = (byte)Math.Round(n.B * 255);
        }
        Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
        logo.UnlockBits(data);
    }

    // Which half a pixel belongs to: by hue, which holds through the art's shading, or for a near-neutral half
    // (graphite), by saturation.
    static int Half(Hsl p, Hsl[] bases)
    {
        if (bases[0].S < 0.15 || bases[1].S < 0.15)
        {
            var neutral = bases[0].S < 0.15 ? 0 : 1;
            return p.S < 0.3 ? neutral : 1 - neutral;
        }
        static double HueGap(double a, double b) => Math.Min(Math.Abs(a - b), 360 - Math.Abs(a - b));
        return HueGap(p.H, bases[0].H) <= HueGap(p.H, bases[1].H) ? 0 : 1;
    }

    // The same hue and saturation, lightened until it reaches 3:1 against the dark taskbar.
    static Hsl Lighten(Hsl c)
    {
        while (c.L < 0.95 && Contrast(c.ToRgb(), DarkTaskbar) < 3)
            c = c with { L = c.L + 0.01 };
        return c;
    }

    // WCAG contrast ratio.
    static double Contrast(Rgb a, Rgb b)
    {
        static double Channel(double c) => c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
        static double Luminance(Rgb c) => 0.2126 * Channel(c.R) + 0.7152 * Channel(c.G) + 0.0722 * Channel(c.B);
        var (x, y) = (Luminance(a), Luminance(b));
        return (Math.Max(x, y) + 0.05) / (Math.Min(x, y) + 0.05);
    }

    readonly record struct Rgb(double R, double G, double B)
    {
        public static Rgb From(System.Windows.Media.Color c) => new(c.R / 255.0, c.G / 255.0, c.B / 255.0);

        public Hsl ToHsl()
        {
            double max = Math.Max(R, Math.Max(G, B)), min = Math.Min(R, Math.Min(G, B)), l = (max + min) / 2, d = max - min;
            if (d == 0)
                return new(0, 0, l);
            var s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
            var h = max == R ? (G - B) / d + (G < B ? 6 : 0) : max == G ? (B - R) / d + 2 : (R - G) / d + 4;
            return new(h * 60, s, l);
        }
    }

    readonly record struct Hsl(double H, double S, double L)
    {
        public Rgb ToRgb()
        {
            var (h, s, l) = (H, S, L);
            double F(double n)
            {
                var k = (n + h / 30) % 12;
                return l - s * Math.Min(l, 1 - l) * Math.Max(-1, Math.Min(k - 3, Math.Min(9 - k, 1)));
            }
            return new(F(0), F(8), F(4));
        }
    }

    // A multi-size ICO from a 1024 px logo. Halving step by step before the last resize keeps small sizes crisp.
    static byte[] BuildIcon(Bitmap logo)
    {
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
