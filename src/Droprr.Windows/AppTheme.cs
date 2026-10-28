using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;

namespace Droprr;

// Light or dark to match Windows, with Droprr's brand accent (Themes/Tokens.xaml) rather than the system's.
static class AppTheme
{
    static Color Token(string key) => (Color)Application.Current.FindResource(key);

    public static void Initialize()
    {
        var theme = SystemUsesLightTheme() ? ApplicationTheme.Light : ApplicationTheme.Dark;
        ApplicationThemeManager.Apply(theme, WindowBackdropType.Mica, updateAccent: false);
        ApplyAccent(theme);
        // A theme switch recomputes the accent shades for the new background.
        ApplicationThemeManager.Changed += (newTheme, _) => ApplyAccent(newTheme);
    }

    // WPF UI derives the accent shades from one color; accent-colored text uses the design system's
    // values instead, so it keeps its contrast (6.4:1 or better) in both themes.
    static void ApplyAccent(ApplicationTheme theme)
    {
        var dark = theme == ApplicationTheme.Dark;
        var violet = Token("BrandViolet");
        // The design system keeps filled accent controls violet in both themes (white text on it is 7:1).
        // WPF UI would lighten them in dark mode, which drops white text below 4.5:1.
        var hover = Blend(violet, Colors.White, 0.18);
        var pressed = Blend(violet, Colors.Black, 0.15);
        ApplicationAccentColorManager.Apply(violet, violet, hover, pressed);
        SetBrush("AccentFillColorDefaultBrush", violet);
        SetBrush("AccentFillColorSecondaryBrush", hover);
        SetBrush("AccentFillColorTertiaryBrush", pressed);
        SetBrush("TextOnAccentFillColorPrimaryBrush", Colors.White);
        SetBrush("AccentTextFillColorPrimaryBrush", Token(dark ? "AccentTextDark" : "AccentTextLight"));
        SetBrush("AccentTintBrush", violet,
            (double)Application.Current.FindResource(dark ? "AccentTintOpacityDark" : "AccentTintOpacityLight"));
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
    // while it's open, keeping the brand accent.
    public static void Setup(Window window, TitleBar? titleBar = null)
    {
        window.Icon = AppIcon.ImageSource;
        if (titleBar is not null)
            titleBar.Icon = new ImageIcon { Source = AppIcon.ImageSource, Width = 16, Height = 16 };
        window.Loaded += (_, _) => SystemThemeWatcher.Watch(window, WindowBackdropType.Mica, updateAccents: false);
    }

    static bool SystemUsesLightTheme()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("AppsUseLightTheme") is 1;
    }
}
