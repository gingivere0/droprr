using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;

namespace Droprr;

// Light or dark (following Windows unless Settings picks one), the window style (LookCatalog), and the color
// theme (ThemeCatalog), all chosen in Settings. Everything themed is a DynamicResource, so switching any of them
// restyles open windows immediately, with no restart.
static class AppTheme
{
    public const string SystemMode = "system", LightMode = "light", DarkMode = "dark";

    static ThemeDef _theme = ThemeCatalog.Find(null);
    static LookDef _look = LookCatalog.Find(null);
    static string _modeSetting = SystemMode;
    static ApplicationTheme _mode = ApplicationTheme.Light;

    public static ThemeDef Current => _theme;

    public static LookDef Look => _look;

    // "system", "light", or "dark", as chosen in Settings.
    public static string Mode => _modeSetting;

    // Raised after a light or dark switch, so views built for one mode can rebuild.
    public static event Action? ModeChanged;

    public static void Initialize(string? themeId, string? mode = null, string? style = null)
    {
        _theme = ThemeCatalog.Find(themeId);
        _look = LookCatalog.Find(style);
        _modeSetting = Normalize(mode);
        _mode = Resolve();
        ApplicationThemeManager.Apply(_mode, WindowBackdropType.None, updateAccent: false);
        ApplyColors();
        // Following Windows: switch when it does. A Light or Dark choice ignores it.
        SystemEvents.UserPreferenceChanged += (_, e) =>
        {
            if (e.Category == UserPreferenceCategory.General && _modeSetting == SystemMode)
                Application.Current?.Dispatcher.BeginInvoke(ApplyMode);
        };
    }

    // Live: called from the Settings mode picker as the selection changes.
    public static void SetMode(string? mode)
    {
        _modeSetting = Normalize(mode);
        ApplyMode();
    }

    // Live: called from the Settings style picker. Spatial is always dark, so it can switch the mode too.
    public static void SetStyle(string? style)
    {
        _look = LookCatalog.Find(style);
        if (Resolve() != _mode)
        {
            ApplyMode();
            return;
        }
        ApplyColors();
        foreach (Window window in Application.Current.Windows)
            UpdateWindow(window);
        ModeChanged?.Invoke();
    }

    static string Normalize(string? mode) => mode?.ToLowerInvariant() switch
    {
        LightMode => LightMode,
        DarkMode => DarkMode,
        _ => SystemMode,
    };

    static ApplicationTheme Resolve() => _look.ForcesDark ? ApplicationTheme.Dark : _modeSetting switch
    {
        LightMode => ApplicationTheme.Light,
        DarkMode => ApplicationTheme.Dark,
        _ => SystemUsesLightTheme() ? ApplicationTheme.Light : ApplicationTheme.Dark,
    };

    // Restyles every open window, title bars included, when the resolved mode changes.
    static void ApplyMode()
    {
        var mode = Resolve();
        if (mode == _mode)
            return;
        _mode = mode;
        // The new mode's accent goes in first: WPF UI's theme dictionary copies some accent colors (the "on"
        // toggle fill) when it loads, and would otherwise keep the old mode's accent.
        ApplyColors();
        ApplicationThemeManager.Apply(_mode, WindowBackdropType.None, updateAccent: false);
        ApplyColors();
        foreach (Window window in Application.Current.Windows)
            UpdateWindow(window);
        ModeChanged?.Invoke();
    }

    static readonly HashSet<Window> Themed = new();

    // The title bar's light or dark, and the themed surface behind the content. WPF UI replaces a window's
    // background with its own ApplicationBackgroundBrush (as a fixed brush) when the window loads and when the
    // theme changes, so the surface is put back each time.
    static void UpdateWindow(Window window)
    {
        if (Themed.Contains(window))
            window.SetResourceReference(Window.BackgroundProperty, "ThemeSurfaceBrush");
        if (IsDark)
            WindowBackgroundManager.ApplyDarkThemeToWindow(window);
        else
            WindowBackgroundManager.RemoveDarkThemeFromWindow(window);
    }

    // Live: called from the Settings theme picker as the selection changes.
    public static void SetTheme(string? themeId)
    {
        _theme = ThemeCatalog.Find(themeId);
        ApplyColors();
    }

    public static bool IsDark => _mode == ApplicationTheme.Dark;

    // Sets every themed brush for the current style, theme, and mode. WPF UI's own neutral and accent brushes
    // are overridden too, so its controls (text boxes, toggles, cards) follow along.
    static void ApplyColors()
    {
        var dark = IsDark;
        var c = _theme.For(dark);
        var look = _look;

        // Neutrals come from the style, as on the Mac and iPhone: the window surface behind the tiles, the tiles,
        // hairlines, and text.
        var surface = look.WindowBrush(dark, c.Accent, c.Secondary);
        surface.Freeze();
        Application.Current.Resources["ThemeSurfaceBrush"] = surface;
        // WPF UI's own window background, for anything that still uses it.
        Application.Current.Resources["ApplicationBackgroundBrush"] = surface;
        var tile = look.TileColor(dark, c.Accent);
        SetBrush("ThemeTileBrush", tile);
        SetBrush("CardBackgroundFillColorDefaultBrush", tile);
        SetBrush("ThemeBorderBrush", look.Hairline(dark));
        SetBrush("CardStrokeColorDefaultBrush", look.Hairline(dark));
        SetBrush("TextFillColorPrimaryBrush", look.Ink(dark));
        var under = look.EffectiveTile(dark, c.Accent);
        SetBrush("TextFillColorSecondaryBrush", LookDef.EnsureContrast(look.Muted(dark), under));
        var accentText = LookDef.EnsureContrast(c.AccentText, under);
        ApplyShapes(look, dark, c, accentText);

        // Accent: the selected tile, toggles, and checkboxes. Hover and press shades follow the design tokens.
        var hover = Blend(c.Accent, Colors.White, 0.18);
        var pressed = Blend(c.Accent, Colors.Black, 0.15);
        ApplicationAccentColorManager.Apply(c.Accent, c.Accent, hover, pressed);
        SetBrush("AccentFillColorDefaultBrush", c.Accent);
        SetBrush("AccentFillColorSecondaryBrush", hover);
        SetBrush("AccentFillColorTertiaryBrush", pressed);
        SetBrush("TextOnAccentFillColorPrimaryBrush", c.OnAccent);
        SetBrush("OnAccentWellBrush", c.OnAccent, 0.16);
        SetBrush("AccentTextFillColorPrimaryBrush", accentText);
        SetBrush("AccentTintBrush", c.AccentTint);

        // Secondary: one contrasting tile per screen (the message tile) and the "N waiting" badges. Raw
        // secondary is decorative only (dots, swatches); controls and text use secondaryText, and an icon well
        // on the secondary tile is filled with secondaryText with its glyph in the tile color.
        SetBrush("ThemeSecondaryBrush", c.Secondary);
        SetBrush("ThemeSecondaryTintBrush", c.SecondaryTint);
        SetBrush("ThemeSecondaryTextBrush", c.SecondaryText);

        // The main action (Send, Pair a phone, Save): the theme's primaryButton and onPrimaryButton tokens, with
        // the same hover and press overlays as other accent fills.
        // Spatial's is a glowing pill in the theme's second color, with black text.
        var primary = look.IsSpatial ? c.Secondary : c.PrimaryButton;
        SetBrush("PrimaryButtonBrush", primary);
        SetBrush("PrimaryButtonHoverBrush", Blend(primary, Colors.White, 0.18));
        SetBrush("PrimaryButtonPressedBrush", Blend(primary, Colors.Black, 0.15));
        SetBrush("OnPrimaryButtonBrush", look.IsSpatial ? Colors.Black : c.OnPrimaryButton);

        // A selected device: the secondary tint with secondaryText (Spatial: near-white with near-black text).
        var selected = look.IsSpatial ? Color.FromArgb(230, 255, 255, 255) : c.SecondaryTint;
        var onSelected = look.IsSpatial ? Color.FromRgb(20, 20, 20) : c.SecondaryText;
        SetBrush("SelectedTileBrush", selected);
        SetBrush("SelectedTileTextBrush", onSelected);
        SetBrush("SelectedWellBrush", onSelected, 0.12);

        // Switches: the main action's color, or the second color in Clay and Spatial, with a white knob there.
        var on = look.IsClay || look.IsSpatial ? c.Secondary : c.PrimaryButton;
        SetBrush("ToggleSwitchFillOn", on);
        SetBrush("ToggleSwitchFillOnPointerOver", Blend(on, Colors.White, 0.12));
        SetBrush("ToggleSwitchFillOnPressed", Blend(on, Colors.Black, 0.15));
        SetBrush("ToggleSwitchStrokeOn", on);
        SetBrush("ToggleSwitchKnobFillOn", look.IsClay || look.IsSpatial ? Colors.White : c.OnPrimaryButton);

        SetBrush("SuccessFillBrush", dark ? ThemeCatalog.SuccessFill.Dark : ThemeCatalog.SuccessFill.Light);

        SetBrush("SuccessTextBrush", dark ? ThemeCatalog.SuccessText.Dark : ThemeCatalog.SuccessText.Light);

        AppIcon.SetTheme(_theme.Id);
    }

    // Corners, borders, shadows, title type, and the secondary button, which differ by style.
    static void ApplyShapes(LookDef look, bool dark, ThemeColors c, Color accentText)
    {
        var resources = Application.Current.Resources;
        resources["LookTileRadius"] = new CornerRadius(look.CardRadius);
        // Atelier has no cards, only a rule under each section; Clay's cards are edged by shadow alone.
        resources["LookTileBorderThickness"] = look.IsAtelier ? new Thickness(0, 0, 0, 1) : look.IsClay ? new Thickness(0) : new Thickness(1);
        resources["LookTileEffect"] = look.IsClay
            ? new System.Windows.Media.Effects.DropShadowEffect
            {
                Color = dark ? Colors.Black : Color.FromRgb(0x78, 0x64, 0xB4),
                Opacity = dark ? 0.45 : 0.18,
                BlurRadius = 20,
                ShadowDepth = 8,
                Direction = 315,
            }
            : null;
        resources["DisplayFontFamily"] = look.DisplayFont;
        resources["DisplayFontWeight"] = look.DisplayWeight;
        // Pills are 18 px corners on a 36 px button.
        resources["PrimaryButtonRadius"] = new CornerRadius(Math.Min(look.PrimaryRadius, 18));

        // The secondary button. Material: an outlined pill. Clay: a raised pill. Spatial: a frosted pill. Atelier:
        // an underlined label.
        var ink = look.Ink(dark);
        var clear = Colors.Transparent;
        var (fill, hover, pressed, text, border, thickness, radius) = look.Id switch
        {
            "clay" => (look.Container(dark), look.Background(dark), Blend(look.Background(dark), Colors.Black, 0.06), ink, clear, new Thickness(0), 18.0),
            "spatial" => (Color.FromArgb(36, 255, 255, 255), Color.FromArgb(56, 255, 255, 255), Color.FromArgb(26, 255, 255, 255), ink, clear, new Thickness(0), 18.0),
            "atelier" => (clear, clear, clear, ink, ink, new Thickness(0, 0, 0, 1), 0.0),
            _ => (clear, WithAlpha(accentText, 0.08), WithAlpha(accentText, 0.14), accentText, WithAlpha(look.Muted(dark), 0.7), new Thickness(1), 18.0),
        };
        SetBrush("TonalBackgroundBrush", fill);
        SetBrush("TonalHoverBrush", hover);
        SetBrush("TonalPressedBrush", pressed);
        SetBrush("TonalForegroundBrush", text);
        SetBrush("TonalBorderBrush", border);
        resources["TonalBorderThickness"] = thickness;
        resources["TonalRadius"] = new CornerRadius(radius);
    }

    static Color WithAlpha(Color color, double opacity) => Color.FromArgb((byte)(color.A * opacity), color.R, color.G, color.B);

    static void SetBrush(string key, Color color, double opacity = 1)
    {
        var brush = new SolidColorBrush(color) { Opacity = opacity };
        brush.Freeze();
        Application.Current.Resources[key] = brush;
    }

    // An overlay of `over` at `amount` opacity on top of `color` (accent.hoverOverlay and accent.pressedOverlay).
    static Color Blend(Color color, Color over, double amount) => Color.FromArgb(color.A,
        (byte)(color.R + (over.R - color.R) * amount),
        (byte)(color.G + (over.G - color.G) * amount),
        (byte)(color.B + (over.B - color.B) * amount));

    // A WPF UI message box (never the classic Win32 one), for the rare errors with no window to show them in.
    public static async System.Threading.Tasks.Task ShowMessageAsync(string title, string message)
    {
        var box = new Wpf.Ui.Controls.MessageBox { Title = title, Content = message, CloseButtonText = "OK" };
        await box.ShowDialogAsync();
    }

    // Gives a window the app icon (taskbar and title bar) and the current light or dark mode, keeping the theme's
    // colors. ApplyMode keeps it current while it's open.
    public static void Setup(Window window, TitleBar? titleBar = null)
    {
        void ShowIcon()
        {
            window.Icon = AppIcon.ImageSource;
            if (titleBar is not null)
                titleBar.Icon = new ImageIcon { Source = AppIcon.ImageSource, Width = 16, Height = 16 };
        }
        ShowIcon();
        // The logo follows the theme: replace the taskbar and title bar icons when it changes.
        AppIcon.Changed += ShowIcon;
        window.Closed += (_, _) => AppIcon.Changed -= ShowIcon;
        // A solid themed surface behind the tiles rather than Mica.
        Themed.Add(window);
        window.Closed += (_, _) => Themed.Remove(window);
        UpdateWindow(window);
        window.Loaded += (_, _) =>
        {
            UpdateWindow(window);
            // After WPF UI's own Loaded handling, which may have replaced the background.
            window.Dispatcher.BeginInvoke(() => UpdateWindow(window), System.Windows.Threading.DispatcherPriority.Loaded);
        };
    }

    static bool SystemUsesLightTheme()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("AppsUseLightTheme") is 1;
    }
}
