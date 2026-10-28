using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;

namespace Droprr;

// Light or dark to match Windows, plus the color theme chosen in Settings (ThemeCatalog). Everything themed is
// a DynamicResource, so switching either one restyles open windows immediately, with no restart.
static class AppTheme
{
    static ThemeDef _theme = ThemeCatalog.Find(null);
    static ApplicationTheme _mode = ApplicationTheme.Light;

    public static ThemeDef Current => _theme;

    public static void Initialize(string? themeId)
    {
        _theme = ThemeCatalog.Find(themeId);
        _mode = SystemUsesLightTheme() ? ApplicationTheme.Light : ApplicationTheme.Dark;
        ApplicationThemeManager.Apply(_mode, WindowBackdropType.None, updateAccent: false);
        ApplyColors();
        // A light or dark switch recomputes the theme's shades for the new background.
        ApplicationThemeManager.Changed += (newMode, _) =>
        {
            _mode = newMode;
            ApplyColors();
        };
    }

    // Live: called from the Settings theme picker as the selection changes.
    public static void SetTheme(string? themeId)
    {
        _theme = ThemeCatalog.Find(themeId);
        ApplyColors();
    }

    public static bool IsDark => _mode == ApplicationTheme.Dark;

    // Sets every themed brush for the current theme and mode. WPF UI's own neutral and accent brushes are
    // overridden too, so its controls (text boxes, toggles, cards) follow the theme.
    static void ApplyColors()
    {
        var dark = IsDark;
        var c = _theme.For(dark);

        // Neutrals: the window surface behind the tiles, the tiles, hairlines, and text.
        SetBrush("ThemeSurfaceBrush", c.Surface);
        SetBrush("ThemeTileBrush", c.Tile);
        SetBrush("ThemeBorderBrush", c.Border);
        SetBrush("CardBackgroundFillColorDefaultBrush", c.Tile);
        SetBrush("CardStrokeColorDefaultBrush", c.Border);
        SetBrush("TextFillColorPrimaryBrush", c.TextPrimary);
        SetBrush("TextFillColorSecondaryBrush", c.TextSecondary);

        // Accent: the selected tile, toggles, and checkboxes. Hover and press shades follow the design tokens.
        var hover = Blend(c.Accent, Colors.White, 0.18);
        var pressed = Blend(c.Accent, Colors.Black, 0.15);
        ApplicationAccentColorManager.Apply(c.Accent, c.Accent, hover, pressed);
        SetBrush("AccentFillColorDefaultBrush", c.Accent);
        SetBrush("AccentFillColorSecondaryBrush", hover);
        SetBrush("AccentFillColorTertiaryBrush", pressed);
        SetBrush("TextOnAccentFillColorPrimaryBrush", c.OnAccent);
        SetBrush("OnAccentWellBrush", c.OnAccent, 0.16);
        SetBrush("AccentTextFillColorPrimaryBrush", c.AccentText);
        SetBrush("AccentTintBrush", c.AccentTint);

        // Secondary: one contrasting tile per screen (the message tile) and the "N waiting" badges. Raw
        // secondary is decorative only (dots, swatches); controls and text use secondaryText, and an icon well
        // on the secondary tile is filled with secondaryText with its glyph in the tile color.
        SetBrush("ThemeSecondaryBrush", c.Secondary);
        SetBrush("ThemeSecondaryTintBrush", c.SecondaryTint);
        SetBrush("ThemeSecondaryTextBrush", c.SecondaryText);

        // The main action: near-black in light mode, the accent in dark mode.
        SetBrush("PrimaryButtonBrush", c.PrimaryButton);
        SetBrush("PrimaryButtonHoverBrush", Blend(c.PrimaryButton, dark ? Colors.Black : Colors.White, 0.15));
        SetBrush("PrimaryButtonPressedBrush", Blend(c.PrimaryButton, dark ? Colors.Black : Colors.White, 0.28));
        SetBrush("OnPrimaryButtonBrush", c.OnPrimaryButton);

        SetBrush("SuccessFillBrush", dark ? ThemeCatalog.SuccessFill.Dark : ThemeCatalog.SuccessFill.Light);
        SetBrush("SuccessTextBrush", dark ? ThemeCatalog.SuccessText.Dark : ThemeCatalog.SuccessText.Light);
    }

    static void SetBrush(string key, Color color, double opacity = 1)
    {
        var brush = new SolidColorBrush(color) { Opacity = opacity };
        brush.Freeze();
        Application.Current.Resources[key] = brush;
    }

    // An overlay of `over` at `amount` opacity on top of `color` (accent.hoverOverlay and accent.pressedOverlay).
    static Color Blend(Color color, Color over, double amount) => Color.FromRgb(
        (byte)(color.R + (over.R - color.R) * amount),
        (byte)(color.G + (over.G - color.G) * amount),
        (byte)(color.B + (over.B - color.B) * amount));

    // A WPF UI message box (never the classic Win32 one), for the rare errors with no window to show them in.
    public static async System.Threading.Tasks.Task ShowMessageAsync(string title, string message)
    {
        var box = new Wpf.Ui.Controls.MessageBox { Title = title, Content = message, CloseButtonText = "OK" };
        await box.ShowDialogAsync();
    }

    // Gives a window the app icon (taskbar and title bar) and makes it follow Windows' light and dark setting
    // while it's open, keeping the theme's colors.
    public static void Setup(Window window, TitleBar? titleBar = null)
    {
        window.Icon = AppIcon.ImageSource;
        if (titleBar is not null)
            titleBar.Icon = new ImageIcon { Source = AppIcon.ImageSource, Width = 16, Height = 16 };
        // Bento: a solid themed surface behind the tiles rather than Mica.
        window.SetResourceReference(Window.BackgroundProperty, "ThemeSurfaceBrush");
        window.Loaded += (_, _) => SystemThemeWatcher.Watch(window, WindowBackdropType.None, updateAccents: false);
    }

    static bool SystemUsesLightTheme()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("AppsUseLightTheme") is 1;
    }
}
