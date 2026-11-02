using System;
using System.IO;
using System.Linq;
using System.Net;
using Droprr.Codes;
using Xunit;

namespace Droprr.Tests;

public class CodesTests
{
    [Fact]
    public void AlignmentCentersMatchTheStandard()
    {
        Assert.Empty(QrStyle.Alignment(1));
        Assert.Equal(new[] { 6, 28, 50 }, QrStyle.Alignment(10));
        Assert.Equal(new[] { 6, 34, 60, 86, 112, 138 }, QrStyle.Alignment(32));
        Assert.Equal(new[] { 6, 30, 58, 86, 114, 142, 170 }, QrStyle.Alignment(40));
    }

    // The vector file comes from site/qrstyle.js, the reference implementation (scripts/qr-style-vector.js), so this
    // checks the port against it.
    [Fact]
    public void ClassifyMatchesTheReferenceImplementation()
    {
        var lines = File.ReadAllLines(Path.Combine(AppContext.BaseDirectory, "qr-style-vector.txt"))
            .Where(l => !l.StartsWith('#')).ToArray();
        var blank = Array.IndexOf(lines, "");
        var matrix = lines[..blank];
        var expected = lines[(blank + 1)..].Where(l => l.Length > 0).ToArray();
        var n = matrix.Length;
        var dark = new bool[n, n];
        for (var r = 0; r < n; r++)
            for (var c = 0; c < n; c++)
                dark[r, c] = matrix[r][c] == '1';

        var kinds = QrStyle.Classify(dark);

        Assert.Equal(57, n);
        for (var r = 0; r < n; r++)
            Assert.Equal(expected[r], string.Concat(Enumerable.Range(0, n).Select(c => (int)kinds[r, c])));
    }

    [Fact]
    public void ColorsUseTheAccentOutsideAndTextInside()
    {
        Assert.Equal((0x557A5Cu, 0x15131Cu), QrStyle.Colors(0x557A5C, 0x15131C, 0x9A4E2D));
        // Graphite & Lime's accent is nearly black, so the inside takes the secondary text color.
        Assert.Equal((0x1F2024u, 0x4D7C0Fu), QrStyle.Colors(0x1F2024, 0x15131C, 0x4D7C0F));
    }

    [Fact]
    public void ComputerAppInfoPacksAddressesAndAFingerprintPrefix()
    {
        var info = OneCode.AppInfo(OneCode.Windows, "00112233445566778899aabbccddeeff" + new string('9', 32),
            IPAddress.Parse("100.64.12.34"), OneCode.DefaultPort,
            new[] { IPAddress.Parse("192.168.1.30"), IPAddress.Parse("fe80::1") });
        Assert.Equal("AgEDABEiM0RVZneImaq7zN3u_2RADCLAqAEe", info);

        var mac = OneCode.AppInfo(OneCode.MacOS, "00112233445566778899AABBCCDDEEFF00112233445566778899aabbccddeeff",
            null, 53340, new[] { IPAddress.Parse("10.0.0.7") });
        Assert.Equal("AgIFABEiM0RVZneImaq7zN3u_9BcCgAABw", mac);
    }

    [Fact]
    public void NamedAppInfoCutsNamesOnACharacterBoundary()
    {
        Assert.Equal("AgQAQWxleOKAmXMgaVBob25l", OneCode.NamedAppInfo(OneCode.Phone, "Alex’s iPhone"));
        var longName = new string('é', 20); // 40 bytes in UTF-8
        var decoded = Convert.FromBase64String(OneCode.NamedAppInfo(OneCode.Web, longName).Replace('-', '+').Replace('_', '/') + "=");
        Assert.Equal(3 + 32, decoded.Length);
    }

    [Fact]
    public void ShortIdsKeepTheirFirst22Characters()
    {
        var full = new string('a', 22) + new string('b', 21);
        Assert.Equal(new string('a', 22), OneCode.Short(full));
        Assert.Equal("abc", OneCode.Short("abc"));
    }
}
