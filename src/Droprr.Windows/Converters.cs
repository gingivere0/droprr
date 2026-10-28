using System;
using System.Globalization;
using System.Windows.Data;
using Wpf.Ui.Controls;

namespace Droprr;

// A peer's platform as its device glyph, per the design system's shared meanings (MASTER.md, Iconography).
sealed class PlatformSymbolConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => (value as string)?.ToLowerInvariant() switch
    {
        "ios" => SymbolRegular.Phone24,
        "macos" => SymbolRegular.Laptop24,
        _ => SymbolRegular.Desktop24,
    };

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}
