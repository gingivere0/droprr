using System.Windows;
using System.Windows.Media;
using Droprr.Codes;
using QRCoder;

namespace Droprr;

// Draws a styled QR code (design-system/droprr/qr-style.md) as a vector image, in the current theme's light colors.
static class QrDrawing
{
    public static DrawingImage Render(string text)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(text, QRCodeGenerator.ECCLevel.Q);
        var kinds = QrStyle.Classify(Modules(data));
        var n = kinds.GetLength(0);
        var light = AppTheme.Current.Light;
        var (outer, inner) = QrStyle.Colors(Rgb(light.Accent), Rgb(light.TextPrimary), Rgb(light.SecondaryText));

        var outerDots = new GeometryGroup();
        var innerDots = new GeometryGroup();
        var radius = QrStyle.Dot / 2;
        for (var r = 0; r < n; r++)
            for (var c = 0; c < n; c++)
            {
                var group = kinds[r, c] switch { QrModule.Outer => outerDots, QrModule.Inner => innerDots, _ => null };
                group?.Children.Add(new EllipseGeometry(new Point(c + QrStyle.Quiet + 0.5, r + QrStyle.Quiet + 0.5), radius, radius));
            }

        // The eyes: a 7-module rounded square, a white 5, and a 3, all in the outer color.
        var eyes = new GeometryGroup { FillRule = FillRule.EvenOdd };
        var eyeCenters = new GeometryGroup();
        foreach (var (row, col) in new[] { (0, 0), (0, n - 7), (n - 7, 0) })
        {
            double x = col + QrStyle.Quiet, y = row + QrStyle.Quiet;
            eyes.Children.Add(new RectangleGeometry(new Rect(x, y, 7, 7), 2.4, 2.4));
            eyes.Children.Add(new RectangleGeometry(new Rect(x + 1, y + 1, 5, 5), 1.6, 1.6));
            eyeCenters.Children.Add(new RectangleGeometry(new Rect(x + 2, y + 2, 3, 3), 1, 1));
        }

        var size = n + QrStyle.Quiet * 2;
        var drawing = new DrawingGroup();
        drawing.Children.Add(new GeometryDrawing(Brushes.White, null, new RectangleGeometry(new Rect(0, 0, size, size))));
        drawing.Children.Add(new GeometryDrawing(Brush(outer), null, outerDots));
        drawing.Children.Add(new GeometryDrawing(Brush(inner), null, innerDots));
        drawing.Children.Add(new GeometryDrawing(Brush(outer), null, eyes));
        drawing.Children.Add(new GeometryDrawing(Brush(outer), null, eyeCenters));
        var image = new DrawingImage(drawing);
        image.Freeze();
        return image;
    }

    // QRCoder's matrix without its quiet zone, which it adds unless the top-left module is already a finder's.
    static bool[,] Modules(QRCodeData data)
    {
        var rows = data.ModuleMatrix;
        var quiet = rows[0][0] ? 0 : 4;
        var n = rows.Count - quiet * 2;
        var dark = new bool[n, n];
        for (var r = 0; r < n; r++)
            for (var c = 0; c < n; c++)
                dark[r, c] = rows[r + quiet][c + quiet];
        return dark;
    }

    static uint Rgb(Color color) => (uint)(color.R << 16 | color.G << 8 | color.B);

    static SolidColorBrush Brush(uint rgb)
    {
        var brush = new SolidColorBrush(Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
        brush.Freeze();
        return brush;
    }
}
