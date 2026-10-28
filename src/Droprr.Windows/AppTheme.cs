using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;

namespace Droprr;

// Light or dark to match Windows, with the accent color taken from the app icon rather than the system's.
static class AppTheme
{
    // The purple half of file-swap-icon-pack's app icon.
    static readonly Color Accent = Color.FromRgb(0x59, 0x1F, 0xFA);

    public static void Initialize()
    {
        var theme = SystemUsesLightTheme() ? ApplicationTheme.Light : ApplicationTheme.Dark;
        ApplicationThemeManager.Apply(theme, WindowBackdropType.Mica, updateAccent: false);
        ApplicationAccentColorManager.Apply(Accent, theme);
        // A theme switch recomputes the accent shades for the new background.
        ApplicationThemeManager.Changed += (newTheme, _) => ApplicationAccentColorManager.Apply(Accent, newTheme);
    }

    // Gives a window the app icon (taskbar and title bar) and makes it follow Windows' light and dark setting
    // while it's open, keeping the icon's accent.
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
