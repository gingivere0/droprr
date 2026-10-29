using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Media;

namespace Droprr;

// The window styles, the same four as the Mac and iPhone (apple/Shared/Looks.swift), with the same ids, names,
// order, and values, so a style picked on one device looks the same on another. The color theme (ThemeCatalog)
// still supplies the accent and secondary colors; the style decides surfaces, shapes, type, and controls.
public sealed record LookDef(string Id, string Name, string Detail)
{
    public bool IsAtelier => Id == "atelier";
    public bool IsClay => Id == "clay";
    public bool IsSpatial => Id == "spatial";
    public bool IsMaterial => Id == "material";

    // Spatial is always dark glass.
    public bool ForcesDark => IsSpatial;

    static Color Hex(uint rgb) => Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
    static Color White(double opacity) => Color.FromArgb((byte)(opacity * 255), 255, 255, 255);
    static Color Pick(bool dark, uint light, uint darkValue) => Hex(dark ? darkValue : light);

    public Color Background(bool dark) => Id switch
    {
        "clay" => Pick(dark, 0xF3F0FA, 0x1C1925),
        "spatial" => Color.FromRgb(36, 36, 36),
        "atelier" => Pick(dark, 0xFBFAF6, 0x1A1916),
        _ => Pick(dark, 0xF8F8F3, 0x131411),
    };

    // The fill behind grouped content (tiles, fields, the drop zone).
    public Color Container(bool dark) => Id switch
    {
        "clay" => Pick(dark, 0xFBF9FF, 0x272333),
        "spatial" => White(0.08),
        "atelier" => Pick(dark, 0xFBFAF6, 0x1A1916),
        _ => Pick(dark, 0xECEDE5, 0x1F211C),
    };

    public Color Ink(bool dark) => Id switch
    {
        "clay" => Pick(dark, 0x37324C, 0xECE8F8),
        "spatial" => Colors.White,
        "atelier" => Pick(dark, 0x1C1B19, 0xEDEAE3),
        _ => Pick(dark, 0x1B1C18, 0xE4E4DC),
    };

    public Color Muted(bool dark) => Id switch
    {
        "clay" => Pick(dark, 0x7A7495, 0xA7A1C2),
        "spatial" => White(0.62),
        "atelier" => Pick(dark, 0x7D776B, 0xA29C90),
        _ => Pick(dark, 0x5C5E55, 0xA9AAA1),
    };

    public Color Hairline(bool dark) => Id switch
    {
        "clay" => Pick(dark, 0xECE8F6, 0x332E42),
        "spatial" => White(0.08),
        "atelier" => Pick(dark, 0xE6E1D6, 0x2F2D28),
        _ => Pick(dark, 0xDADBD2, 0x30322B),
    };

    public double CardRadius => Id switch
    {
        "clay" => 22,
        "atelier" => 0,
        _ => 24,
    };

    // The main action's corners: a crisp block (Atelier), a rounded block (Material), or a pill.
    public double PrimaryRadius => Id switch
    {
        "atelier" => 3,
        "material" => 16,
        _ => 100,
    };

    // Display type (page titles): Atelier's serif, Clay's heavy, Spatial's bold, Material's regular. Windows has
    // no rounded system face, so Clay is heavy Segoe UI.
    public FontFamily DisplayFont => IsAtelier ? new FontFamily("Georgia, Cambria, Times New Roman") : new FontFamily("Segoe UI Variable Display, Segoe UI");

    public FontWeight DisplayWeight => Id switch
    {
        "clay" => FontWeights.Black,
        "spatial" => FontWeights.Bold,
        _ => FontWeights.Normal,
    };

    // Spatial floats over a soft, dim room (the iPhone's stand-in for the blurred desktop), with a faint glow of
    // the theme's second color. Material adds a 3% wash of the accent.
    public Brush WindowBrush(bool dark, Color accent, Color secondary)
    {
        if (IsSpatial)
        {
            var room = new LinearGradientBrush(Color.FromRgb(107, 99, 89), Color.FromRgb(61, 69, 77), new Point(0, 0), new Point(1, 1));
            var glow = new RadialGradientBrush(Color.FromArgb(46, secondary.R, secondary.G, secondary.B), Colors.Transparent)
            {
                Center = new Point(0, 0), GradientOrigin = new Point(0, 0), RadiusX = 0.9, RadiusY = 0.7,
            };
            var bounds = new RectangleGeometry(new Rect(0, 0, 1, 1));
            var group = new DrawingGroup();
            group.Children.Add(new GeometryDrawing(room, null, bounds));
            group.Children.Add(new GeometryDrawing(new SolidColorBrush(Color.FromArgb(46, 0, 0, 0)), null, bounds));
            group.Children.Add(new GeometryDrawing(glow, null, bounds));
            return new DrawingBrush(group) { Stretch = Stretch.Fill };
        }
        var background = Background(dark);
        return new SolidColorBrush(IsMaterial ? Blend(background, accent, 0.03) : background);
    }

    public Color TileColor(bool dark, Color accent) => IsMaterial ? Blend(Container(dark), accent, 0.03) : Container(dark);

    // The tile as text actually sits on it, opaque. Spatial's glass is taken at the room's lightest corner, where
    // light text has the least contrast.
    public Color EffectiveTile(bool dark, Color accent)
    {
        if (!IsSpatial)
            return TileColor(dark, accent);
        var room = Blend(Color.FromRgb(107, 99, 89), Colors.Black, 0.18);
        return Blend(room, Colors.White, 0.08);
    }

    // `color` (flattened onto `background`), moved toward black or white until it has `ratio` contrast with
    // `background`. MASTER.md asks 4.5:1 of all text; a few of the style values copied from the Mac fall short.
    public static Color EnsureContrast(Color color, Color background, double ratio = 4.5)
    {
        var c = Blend(background, Color.FromRgb(color.R, color.G, color.B), color.A / 255.0);
        var target = Luminance(background) > 0.18 ? Colors.Black : Colors.White;
        for (var i = 0; i < 50 && Contrast(c, background) < ratio; i++)
            c = Blend(c, target, 0.04);
        return Color.FromRgb(c.R, c.G, c.B);
    }

    static double Luminance(Color c)
    {
        static double Channel(byte v) => v / 255.0 <= 0.04045 ? v / 255.0 / 12.92 : System.Math.Pow((v / 255.0 + 0.055) / 1.055, 2.4);
        return 0.2126 * Channel(c.R) + 0.7152 * Channel(c.G) + 0.0722 * Channel(c.B);
    }

    static double Contrast(Color a, Color b)
    {
        var (x, y) = (Luminance(a), Luminance(b));
        return (System.Math.Max(x, y) + 0.05) / (System.Math.Min(x, y) + 0.05);
    }

    // An overlay of `over` at `amount` opacity on top of `color` (accent.hoverOverlay and accent.pressedOverlay).
    public static Color Blend(Color color, Color over, double amount) => Color.FromArgb(color.A,
        (byte)(color.R + (over.R - color.R) * amount),
        (byte)(color.G + (over.G - color.G) * amount),
        (byte)(color.B + (over.B - color.B) * amount));
}

// A style in the Settings picker: a tiny drawing of it (its surface, a chip, and its main button) in the current
// theme's colors, like the Mac's StyleSwatch.
public sealed class StyleSwatch
{
    public StyleSwatch(LookDef look, ThemeDef theme, bool dark)
    {
        var c = theme.For(look.ForcesDark || dark);
        Id = look.Id;
        Name = look.Name;
        Detail = look.Detail;
        Back = look.WindowBrush(look.ForcesDark || dark, c.Accent, c.Secondary);
        Back.Freeze();
        Chip = new SolidColorBrush(look.IsSpatial ? Color.FromArgb(64, 255, 255, 255) : look.TileColor(dark, c.Accent));
        Button = new SolidColorBrush(look.IsSpatial ? c.Secondary : c.PrimaryButton);
        Edge = new SolidColorBrush(look.Hairline(dark));
        Radius = new CornerRadius(look.CardRadius / 2.4);
        ButtonRadius = new CornerRadius(Math.Min(look.PrimaryRadius, 9));
        TitleFont = look.DisplayFont;
        TitleWeight = look.DisplayWeight;
    }

    public string Id { get; }
    public string Name { get; }
    public string Detail { get; }
    public Brush Back { get; }
    public Brush Chip { get; }
    public Brush Button { get; }
    public Brush Edge { get; }
    public CornerRadius Radius { get; }
    public CornerRadius ButtonRadius { get; }
    public FontFamily TitleFont { get; }
    public FontWeight TitleWeight { get; }
}

public static class LookCatalog
{
    public static readonly IReadOnlyList<LookDef> All =
    [
        new("material", "Material You", "Tonal surfaces, big rounded shapes"),
        new("clay", "Clay", "Soft, puffy 3D shapes"),
        new("spatial", "Spatial", "Dark frosted glass"),
        new("atelier", "Atelier", "Ivory paper, serif titles"),
    ];

    public const string DefaultId = "material";

    public static LookDef Find(string? id) => All.FirstOrDefault(l => l.Id == id) ?? All[0];
}
