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
        ApplicationAccentColorManager.Apply(Token("BrandViolet"), theme);
        var text = new SolidColorBrush(Token(theme == ApplicationTheme.Dark ? "AccentTextDark" : "AccentTextLight"));
        text.Freeze();
        Application.Current.Resources["AccentTextFillColorPrimaryBrush"] = text;
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
