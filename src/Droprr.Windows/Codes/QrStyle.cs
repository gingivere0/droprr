using System;
using System.Collections.Generic;

namespace Droprr.Codes;

// What to draw for one module of a styled QR code.
public enum QrModule : byte { Light, Outer, Inner, Eye }

// Droprr's styled QR code (design-system/droprr/qr-style.md), ported from site/qrstyle.js, the reference
// implementation: change them together. Only the base class library, so the tests run anywhere .NET does.
public static class QrStyle
{
    // design-system/droprr/qr-outline.json: in units of the outline's longest side, centered on (0, 0).
    public static readonly (double X, double Y)[] Outline =
    {
        (-0.0844, -0.5),
        (-0.1287, -0.4935),
        (-0.1564, -0.4751),
        (-0.1914, -0.417),
        (-0.2431, -0.3524),
        (-0.3049, -0.2509),
        (-0.3077, -0.1836),
        (-0.2975, -0.0969),
        (-0.2984, -0.0489),
        (-0.3206, -0.0101),
        (-0.3418, 0.0507),
        (-0.3482, 0.1338),
        (-0.3768, 0.2168),
        (-0.3796, 0.2463),
        (-0.4304, 0.3164),
        (-0.4479, 0.3745),
        (-0.4377, 0.4419),
        (-0.4091, 0.4797),
        (-0.3704, 0.4991),
        (-0.3298, 0.5),
        (-0.2763, 0.4926),
        (-0.2163, 0.4622),
        (-0.184, 0.4317),
        (-0.1195, 0.3884),
        (-0.0595, 0.3146),
        (0.0291, 0.2638),
        (0.089, 0.1836),
        (0.1342, 0.1531),
        (0.1628, 0.1218),
        (0.1896, 0.1052),
        (0.2597, 0.0839),
        (0.3971, 0.095),
        (0.434, 0.0839),
        (0.4479, 0.0701),
        (0.446, 0.0443),
        (0.4202, 0.0157),
        (0.3464, -0.0295),
        (0.2689, -0.0637),
        (0.2006, -0.1218),
        (0.1444, -0.1218),
        (0.0586, -0.0996),
        (-0.0577, -0.1596),
        (-0.065, -0.1753),
        (-0.0623, -0.1882),
        (-0.03, -0.2482),
        (-0.0217, -0.3063),
        (-0.0226, -0.3782),
        (-0.0383, -0.4493),
        (-0.0613, -0.4732),
        (-0.0696, -0.4908),
    };

    public const double Size = 0.8;  // the outline's longest side, as a share of the code
    public const double Gap = 0.5;   // dark modules closer than this to the outline's edge are left out (in modules)
    public const double Dot = 0.95;  // dot diameter, in modules
    public const int Quiet = 3;      // white margin, in modules

    // Rows and columns of the alignment pattern centers for a version.
    public static int[] Alignment(int version)
    {
        if (version == 1)
            return Array.Empty<int>();
        var count = version / 7 + 2;
        var step = version == 32 ? 26 : (version * 4 + count * 2 + 1) / (count * 2 - 2) * 2;
        var result = new List<int> { 6 };
        for (var pos = 17 + version * 4 - 7; result.Count < count; pos -= step)
            result.Insert(1, pos);
        return result.ToArray();
    }

    // Function modules, which are always drawn: finders with separators and format information, timing, version
    // information, and alignment patterns.
    public static bool[,] FunctionModules(int n)
    {
        var version = (n - 17) / 4;
        var marked = new bool[n, n];
        void Mark(int r0, int c0, int rows, int cols)
        {
            for (var r = Math.Max(0, r0); r < Math.Min(n, r0 + rows); r++)
                for (var c = Math.Max(0, c0); c < Math.Min(n, c0 + cols); c++)
                    marked[r, c] = true;
        }
        Mark(0, 0, 9, 9); Mark(0, n - 8, 9, 8); Mark(n - 8, 0, 8, 9);
        Mark(6, 0, 1, n); Mark(0, 6, n, 1);
        if (version >= 7) { Mark(0, n - 11, 6, 3); Mark(n - 11, 0, 3, 6); }
        var centers = Alignment(version);
        foreach (var r in centers)
            foreach (var c in centers)
            {
                if ((r < 9 && c < 9) || (r < 9 && c > n - 10) || (r > n - 10 && c < 9))
                    continue;
                Mark(r - 2, c - 2, 5, 5);
            }
        return marked;
    }

    public static bool IsEye(int r, int c, int n) => (r < 7 && c < 7) || (r < 7 && c >= n - 7) || (r >= n - 7 && c < 7);

    // What to draw for each module of a code without its quiet zone: dark[row, column].
    public static QrModule[,] Classify(bool[,] dark)
    {
        var n = dark.GetLength(0);
        var fixedModules = FunctionModules(n);
        var poly = new (double X, double Y)[Outline.Length];
        for (var i = 0; i < Outline.Length; i++)
            poly[i] = (Outline[i].X * Size * n + n / 2.0, Outline[i].Y * Size * n + n / 2.0);
        var kinds = new QrModule[n, n];
        for (var r = 0; r < n; r++)
            for (var c = 0; c < n; c++)
            {
                if (IsEye(r, c, n)) { kinds[r, c] = QrModule.Eye; continue; }
                if (!dark[r, c])
                    continue;
                double x = c + 0.5, y = r + 0.5;
                if (!fixedModules[r, c] && EdgeDistance(x, y, poly) < Gap)
                    continue;
                kinds[r, c] = Inside(x, y, poly) ? QrModule.Inner : QrModule.Outer;
            }
        return kinds;
    }

    static bool Inside(double x, double y, (double X, double Y)[] poly)
    {
        var result = false;
        for (int i = 0, j = poly.Length - 1; i < poly.Length; j = i++)
        {
            var (xi, yi) = poly[i];
            var (xj, yj) = poly[j];
            if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi)
                result = !result;
        }
        return result;
    }

    static double EdgeDistance(double x, double y, (double X, double Y)[] poly)
    {
        var best = double.PositiveInfinity;
        for (int i = 0, j = poly.Length - 1; i < poly.Length; j = i++)
        {
            var (ax, ay) = poly[j];
            var (bx, by) = poly[i];
            double dx = bx - ax, dy = by - ay;
            var length = dx * dx + dy * dy;
            var t = Math.Max(0, Math.Min(1, ((x - ax) * dx + (y - ay) * dy) / (length == 0 ? 1 : length)));
            best = Math.Min(best, Math.Sqrt(Math.Pow(x - ax - t * dx, 2) + Math.Pow(y - ay - t * dy, 2)));
        }
        return best;
    }

    // The theme's light-palette colors (0xRRGGBB): outer is the accent; inner is the primary text, or the secondary
    // text when the accent is itself nearly black.
    public static (uint Outer, uint Inner) Colors(uint accent, uint textPrimary, uint secondaryText) =>
        (accent, Luminance(accent) < 0.05 ? secondaryText : textPrimary);

    static double Luminance(uint rgb)
    {
        static double Channel(uint v)
        {
            var x = v / 255.0;
            return x <= 0.03928 ? x / 12.92 : Math.Pow((x + 0.055) / 1.055, 2.4);
        }
        return 0.2126 * Channel((rgb >> 16) & 255) + 0.7152 * Channel((rgb >> 8) & 255) + 0.0722 * Channel(rgb & 255);
    }
}
