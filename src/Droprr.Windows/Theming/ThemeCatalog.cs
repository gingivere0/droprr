using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Windows.Media;

namespace Droprr;

// One appearance (light or dark) of a theme: every color role from design-system/droprr/tokens.json.
public sealed record ThemeColors(
    Color Surface, Color Tile, Color Border, Color TextPrimary, Color TextSecondary,
    Color PrimaryButton, Color OnPrimaryButton, Color Accent, Color OnAccent, Color AccentText, Color AccentTint,
    Color Secondary, Color SecondaryTint, Color SecondaryText);

public sealed record ThemeDef(string Id, string Name, ThemeColors Light, ThemeColors Dark)
{
    public ThemeColors For(bool dark) => dark ? Dark : Light;
}

// The selectable Bento themes, read from design-system/droprr/tokens.json, which is embedded in the app so
// the design system stays the single source: change a theme there and rebuild.
static class ThemeCatalog
{
    public static readonly IReadOnlyList<ThemeDef> All;
    public static readonly string DefaultId;
    public static readonly (Color Light, Color Dark) SuccessFill;
    public static readonly (Color Light, Color Dark) SuccessText;

    static ThemeCatalog()
    {
        using var stream = typeof(ThemeCatalog).Assembly.GetManifestResourceStream("Droprr.tokens.json")!;
        using var json = JsonDocument.Parse(stream);
        var themes = json.RootElement.GetProperty("themes");
        var list = themes.GetProperty("list");
        DefaultId = themes.GetProperty("default").GetString()!;
        All = themes.GetProperty("order").EnumerateArray()
            .Select(id => id.GetString()!)
            .Select(id => new ThemeDef(id, list.GetProperty(id).GetProperty("name").GetString()!,
                Colors(list.GetProperty(id).GetProperty("light")), Colors(list.GetProperty(id).GetProperty("dark"))))
            .ToList();
        var bento = json.RootElement.GetProperty("bento");
        SuccessFill = (Hex(bento.GetProperty("successFill"), "light"), Hex(bento.GetProperty("successFill"), "dark"));
        SuccessText = (Hex(bento.GetProperty("successText"), "light"), Hex(bento.GetProperty("successText"), "dark"));
    }

    static Color Hex(JsonElement element, string name) =>
        (Color)ColorConverter.ConvertFromString(element.GetProperty(name).GetString()!);

    static ThemeColors Colors(JsonElement e) => new(
        Hex(e, "surface"), Hex(e, "tile"), Hex(e, "border"), Hex(e, "textPrimary"), Hex(e, "textSecondary"),
        Hex(e, "primaryButton"), Hex(e, "onPrimaryButton"), Hex(e, "accent"), Hex(e, "onAccent"), Hex(e, "accentText"),
        Hex(e, "accentTint"), Hex(e, "secondary"), Hex(e, "secondaryTint"), Hex(e, "secondaryText"));

    public static ThemeDef Find(string? id) =>
        All.FirstOrDefault(t => string.Equals(t.Id, id, StringComparison.Ordinal)) ?? All.First(t => t.Id == DefaultId);
}

// A theme as shown in the Settings swatch picker: its colors for the current light or dark mode.
public sealed class ThemeSwatch
{
    public ThemeSwatch(ThemeDef theme, bool dark)
    {
        var c = theme.For(dark);
        Id = theme.Id;
        Name = theme.Name;
        Surface = Brush(c.Surface);
        Tile = Brush(c.Tile);
        Border = Brush(c.Border);
        Accent = Brush(c.Accent);
        Secondary = Brush(c.Secondary);
    }

    public string Id { get; }
    public string Name { get; }
    public SolidColorBrush Surface { get; }
    public SolidColorBrush Tile { get; }
    public SolidColorBrush Border { get; }
    public SolidColorBrush Accent { get; }
    public SolidColorBrush Secondary { get; }

    static SolidColorBrush Brush(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}
