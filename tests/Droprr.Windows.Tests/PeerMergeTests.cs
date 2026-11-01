using Xunit;

namespace Droprr.Tests;

public class PeerMergeTests
{
    const string FpA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const string FpB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    [Theory]
    [InlineData("mac1", "", "mac1", "", true)]       // same id
    [InlineData("", FpA, "mac1", FpA, true)]         // same pin
    [InlineData("mac1", FpA, "mac1", FpB, false)]    // two different pins
    [InlineData("mac1", FpA, "mac2", FpA, false)]    // two different ids
    [InlineData("", "", "", "", false)]              // nothing to go on
    public void Same_device(string idA, string fpA, string idB, string fpB, bool same)
    {
        var a = new Peer { Id = idA, Fingerprint = fpA };
        var b = new Peer { Id = idB, Fingerprint = fpB };

        Assert.Equal(same, PeerMerge.SameDevice(a, b));
        Assert.Equal(same, PeerMerge.SameDevice(b, a));
    }

    [Fact]
    public void A_shared_host_alone_isnt_the_same_device()
    {
        Assert.False(PeerMerge.SameDevice(new Peer { Host = "mac.ts.net" }, new Peer { Host = "mac.ts.net" }));
    }

    [Fact]
    public void Merging_keeps_the_older_name_and_host_and_the_newer_tokens()
    {
        var older = new Peer { Name = "Work Mac", Host = "mac.ts.net", Id = "mac1", Token = "old", AcceptToken = "old-accept", Lan = { "10.0.0.1:1" } };
        var newer = new Peer
        {
            Name = "MacBook", Id = "mac1", Fingerprint = FpA, TlsPort = 53319, Platform = DevicePlatform.MacOS,
            Token = "new", AcceptToken = "new-accept", Lan = { "10.0.0.2:1" }, LastPath = SendPath.Lan,
        };
        var peers = new PeerList { older, newer };

        var (o, n) = Assert.Single(PeerMerge.Duplicates(peers));
        Assert.Same(older, o);
        Assert.Same(newer, n);
        PeerMerge.Merge(peers, older, newer, keepOlderTokens: false);

        var merged = Assert.Single(peers);
        Assert.Equal("Work Mac", merged.Name);
        Assert.Equal("mac.ts.net", merged.Host);
        Assert.Equal("mac1", merged.Id);
        Assert.Equal(FpA, merged.Fingerprint);
        Assert.Equal(DevicePlatform.MacOS, merged.Platform);
        Assert.Equal(SendPath.Lan, merged.LastPath);
        Assert.Equal("new", merged.Token);
        Assert.Equal("new-accept", merged.AcceptToken);
        Assert.Equal(new[] { "10.0.0.2:1", "10.0.0.1:1" }, merged.Lan);
    }

    [Fact]
    public void Merging_can_keep_the_older_tokens()
    {
        var older = new Peer { Name = "Mac", Token = "old", AcceptToken = "old-accept", Id = "mac1" };
        var newer = new Peer { Name = "Mac (2)", Token = "new", AcceptToken = "new-accept", Id = "mac1" };
        var peers = new PeerList { older, newer };
        PeerMerge.Merge(peers, older, newer, keepOlderTokens: true);

        Assert.Equal("old", older.Token);
        Assert.Equal("old-accept", older.AcceptToken);
    }

    [Fact]
    public void Preview_combines_both_records_with_the_token_to_try()
    {
        var older = new Peer { Name = "Mac", Host = "mac.ts.net", Port = 1234 };
        var newer = new Peer { Name = "Mac (2)", Id = "mac1", Fingerprint = FpA, TlsPort = 1235, Platform = DevicePlatform.MacOS };
        var preview = PeerMerge.Preview(older, newer, "try-me");

        Assert.Equal("Mac", preview.Name);
        Assert.Equal("mac.ts.net", preview.Host);
        Assert.Equal(1234, preview.Port);
        Assert.Equal(DevicePlatform.MacOS, preview.Platform);
        Assert.Equal("mac1", preview.Id);
        Assert.Equal(FpA, preview.Fingerprint);
        Assert.Equal("try-me", preview.Token);
    }
}
