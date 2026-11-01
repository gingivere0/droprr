using System.Text.Json;
using Xunit;

namespace Droprr.Tests;

// settings.json and the protocol keep their strings; the enums only exist in memory.
public class WireFormatTests
{
    static readonly JsonSerializerOptions Web = new(JsonSerializerDefaults.Web);

    [Theory]
    [InlineData("windows", DevicePlatform.Windows)]
    [InlineData("macos", DevicePlatform.MacOS)]
    [InlineData(" iOS ", DevicePlatform.IOS)]
    [InlineData("web", DevicePlatform.Web)]
    [InlineData("linux", DevicePlatform.Unknown)]
    [InlineData("", DevicePlatform.Unknown)]
    [InlineData(null, DevicePlatform.Unknown)]
    public void Platforms_from_the_wire(string? wire, DevicePlatform platform) =>
        Assert.Equal(platform, DevicePlatforms.FromWire(wire));

    [Fact]
    public void Only_apps_pair()
    {
        Assert.True(DevicePlatform.IOS.CanPair());
        Assert.True(DevicePlatform.Windows.CanPair());
        Assert.True(DevicePlatform.MacOS.CanPair());
        Assert.False(DevicePlatform.Web.CanPair());
        Assert.False(DevicePlatform.Unknown.CanPair());
    }

    [Fact]
    public void A_saved_peer_reads_and_writes_the_same_strings()
    {
        const string saved = """{"name":"Phone","platform":"ios","lastPath":"lan","lan":["10.0.0.2:53319"]}""";
        var peer = JsonSerializer.Deserialize<Peer>(saved, Web)!;

        Assert.Equal(DevicePlatform.IOS, peer.Platform);
        Assert.Equal(SendPath.Lan, peer.LastPath);

        using var written = JsonDocument.Parse(JsonSerializer.Serialize(peer, Web));
        Assert.Equal("ios", written.RootElement.GetProperty("platform").GetString());
        Assert.Equal("lan", written.RootElement.GetProperty("lastPath").GetString());
        Assert.False(written.RootElement.TryGetProperty("isPhone", out _));
    }

    [Fact]
    public void A_peer_saved_by_an_older_version_still_reads()
    {
        var peer = JsonSerializer.Deserialize<Peer>("""{"name":"Old","platform":"","lastPath":""}""", Web)!;
        Assert.Equal(DevicePlatform.Unknown, peer.Platform);
        Assert.Equal(SendPath.None, peer.LastPath);

        var unknown = JsonSerializer.Deserialize<Peer>("""{"name":"Odd","platform":"plan9","lastPath":"carrier pigeon"}""", Web)!;
        Assert.Equal(DevicePlatform.Unknown, unknown.Platform);
        Assert.Equal(SendPath.None, unknown.LastPath);
    }

    [Fact]
    public void A_saved_peer_list_reads_into_a_peer_list()
    {
        var peers = JsonSerializer.Deserialize<PeerList>("""[{"name":"A"},{"name":"B","platform":"web"}]""", Web)!;

        Assert.Equal(2, peers.Count);
        Assert.True(peers.FindByName("b")!.IsBrowser);
    }

    [Fact]
    public void Ping_answers_parse()
    {
        var info = PingInfo.Parse("""{"name":"Mac","version":"0.3.2","platform":"macos","protocol":2,"id":"mac1","fp":"ABCDEF","tlsPort":53319}""");

        Assert.Equal(DevicePlatform.MacOS, info.Platform);
        Assert.Equal("mac1", info.Id);
        Assert.Equal("abcdef", info.Fingerprint);
        Assert.Equal(53319, info.TlsPort);
        Assert.Equal("0.3.2", info.Version);
    }

    [Fact]
    public void Ping_answers_with_odd_fields_still_parse()
    {
        var info = PingInfo.Parse("""{"platform":7,"tlsPort":"53319"}""");

        Assert.Equal(DevicePlatform.Unknown, info.Platform);
        Assert.Null(info.TlsPort);
    }

    [Fact]
    public void Pair_answers_parse()
    {
        var info = PairInfo.Parse("""{"ok":true,"name":"Mac","token":"t","id":"mac1","fp":"AB","tlsPort":53319,"lan":["10.0.0.2:53319",5],"host":"mac.ts.net"}""")!;

        Assert.Equal("t", info.Token);
        Assert.Equal("ab", info.Fingerprint);
        Assert.Equal(new[] { "10.0.0.2:53319" }, info.Lan);
        Assert.Equal("mac.ts.net", info.Host);
    }

    [Fact]
    public void Pair_answers_without_a_token_are_refused() =>
        Assert.Null(PairInfo.Parse("""{"ok":true,"name":"Mac"}"""));
}
