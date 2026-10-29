using System;
using System.Globalization;
using System.Windows.Data;
using Wpf.Ui.Controls;

namespace Droprr;

// A token as dots unless it's revealed: [token, revealed]. An empty token stays empty.
sealed class MaskedTokenConverter : IMultiValueConverter
{
    public object Convert(object?[] values, Type targetType, object? parameter, CultureInfo culture) =>
        values[0] is not string { Length: > 0 } token ? "" : values[1] is true ? token : new string('•', 12);

    public object[] ConvertBack(object? value, Type[] targetTypes, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}

// A peer's platform as its device glyph, per the design system's shared meanings (MASTER.md, Iconography).
sealed class PlatformSymbolConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) => (value as string)?.ToLowerInvariant() switch
    {
        "ios" => SymbolRegular.Phone24,
        "web" => SymbolRegular.Globe24,
        "macos" => SymbolRegular.Laptop24,
        _ => SymbolRegular.Desktop24,
    };

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) => throw new NotSupportedException();
}
