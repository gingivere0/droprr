using System.Collections.Generic;
using System.Linq;
using Xunit;

namespace Droprr.Tests;

public class PeerBookTests
{
    const string FpA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const string FpB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    static PairRequest Request(PairTarget target, string name = "MacBook", DevicePlatform platform = DevicePlatform.MacOS,
        string? host = "macbook.example.ts.net", string? sendToken = "send", string? acceptToken = "accept",
        string? id = null, string? fingerprint = null) =>
        new(target, name, platform, host, 53318, sendToken, acceptToken, id, fingerprint);

    [Fact]
    public void Match_adds_a_new_peer_with_both_tokens()
    {
        var peers = new PeerList();
        var peer = peers.ApplyPairing(Request(new PairTarget.Match(), id: "mac1", fingerprint: FpA));

        Assert.Single(peers);
        Assert.Equal("MacBook", peer.Name);
        Assert.Equal(DevicePlatform.MacOS, peer.Platform);
        Assert.Equal("macbook.example.ts.net", peer.Host);
        Assert.Equal("send", peer.Token);
        Assert.Equal("accept", peer.AcceptToken);
        Assert.Equal("mac1", peer.Id);
        Assert.Equal(FpA, peer.Fingerprint);
    }

    [Fact]
    public void Match_finds_the_same_device_id_before_the_name()
    {
        var peers = new PeerList { new() { Name = "Work Mac", Id = "mac1" }, new() { Name = "MacBook" } };
        var peer = peers.ApplyPairing(Request(new PairTarget.Match(), id: "mac1"));

        Assert.Equal("Work Mac", peer.Name);
        Assert.Equal(2, peers.Count);
    }

    [Fact]
    public void Match_finds_the_same_name_ignoring_case_and_spaces()
    {
        var peers = new PeerList { new() { Name = " macbook " } };
        peers.ApplyPairing(Request(new PairTarget.Match()));

        Assert.Single(peers);
    }

    [Fact]
    public void Match_keeps_a_host_the_person_typed()
    {
        var peers = new PeerList { new() { Name = "MacBook", Host = "typed-name" } };
        var peer = peers.ApplyPairing(Request(new PairTarget.Match()));

        Assert.Equal("typed-name", peer.Host);
    }

    [Fact]
    public void New_always_adds_under_a_unique_name()
    {
        var peers = new PeerList { new() { Name = "MacBook", Id = "other" } };
        var peer = peers.ApplyPairing(Request(new PairTarget.New(), id: "mac1"));

        Assert.Equal(2, peers.Count);
        Assert.Equal("MacBook (2)", peer.Name);
    }

    [Fact]
    public void Update_fills_in_an_identity_but_never_replaces_one()
    {
        var peers = new PeerList { new() { Name = "MacBook", Platform = DevicePlatform.MacOS, Id = "mac1" } };
        var peer = peers.ApplyPairing(Request(new PairTarget.Update("MacBook"), platform: DevicePlatform.Windows,
            id: "someone-else", fingerprint: FpA));

        Assert.Equal(DevicePlatform.MacOS, peer.Platform);
        Assert.Equal("mac1", peer.Id);
        Assert.Equal(FpA, peer.Fingerprint);
    }

    [Fact]
    public void Repair_replaces_the_identity()
    {
        var peers = new PeerList { new() { Name = "MacBook", Id = "mac1", Fingerprint = FpA, AcceptToken = "old" } };
        var peer = peers.ApplyPairing(Request(new PairTarget.Repair("MacBook"), id: "mac2", fingerprint: FpB));

        Assert.Single(peers);
        Assert.Equal("mac2", peer.Id);
        Assert.Equal(FpB, peer.Fingerprint);
        Assert.Equal("accept", peer.AcceptToken);
    }

    [Fact]
    public void An_identity_another_peer_has_is_never_taken()
    {
        var peers = new PeerList { new() { Name = "Mac mini", Id = "mini", Fingerprint = FpA } };
        var peer = peers.ApplyPairing(Request(new PairTarget.New(), id: "mini", fingerprint: FpA));

        Assert.Equal("", peer.Id);
        Assert.Equal("", peer.Fingerprint);
    }

    [Fact]
    public void A_target_renamed_meanwhile_falls_back_to_matching()
    {
        var peers = new PeerList { new() { Name = "MacBook" } };
        var peer = peers.ApplyPairing(Request(new PairTarget.Update("Gone")));

        Assert.Single(peers);
        Assert.Same(peers[0], peer);
    }

    [Fact]
    public void Phones_have_no_host_and_no_token_without_one_offered()
    {
        var peers = new PeerList { new() { Name = "iPhone", Platform = DevicePlatform.IOS, Token = "stale" } };
        var peer = peers.ApplyPairing(Request(new PairTarget.Match(), name: "iPhone", platform: DevicePlatform.IOS,
            host: "phone.example", sendToken: null));

        Assert.Equal("", peer.Host);
        Assert.Equal("", peer.Token);
        Assert.True(peer.IsPhone);
    }

    [Fact]
    public void Repairable_only_matches_the_same_kind_of_device()
    {
        var peers = new PeerList
        {
            new() { Name = "Browser", Platform = DevicePlatform.Web, Id = "web1" },
            new() { Name = "iPhone", Platform = DevicePlatform.IOS, Id = "phone1" },
            new() { Name = "MacBook", Platform = DevicePlatform.MacOS, Fingerprint = FpA },
        };

        Assert.Null(peers.FindRepairable("web1", null, DevicePlatform.IOS));
        Assert.Equal("iPhone", peers.FindRepairable("phone1", null, DevicePlatform.IOS)?.Name);
        Assert.Null(peers.FindRepairable("phone1", null, DevicePlatform.MacOS));
        Assert.Equal("MacBook", peers.FindRepairable(null, FpA.ToUpperInvariant(), DevicePlatform.Windows)?.Name);
    }

    [Fact]
    public void A_phone_checking_in_is_added_once_and_never_over_a_computer()
    {
        var peers = new PeerList { new() { Name = "Desk", Platform = DevicePlatform.Windows } };

        Assert.Null(peers.AddCheckedInPhone("desk"));
        Assert.Null(peers.AddCheckedInPhone(""));
        var phone = peers.AddCheckedInPhone("Seth's iPhone");
        Assert.Equal(DevicePlatform.IOS, phone?.Platform);
        Assert.Null(peers.AddCheckedInPhone("Seth's iPhone"));
        Assert.Equal(DevicePlatform.Windows, peers.FindByName("Desk")!.Platform);
    }

    [Fact]
    public void Phones_checking_in_stop_at_fifty()
    {
        var peers = new PeerList(Enumerable.Range(0, 50).Select(i => new Peer { Name = $"p{i}", Platform = DevicePlatform.IOS }));

        Assert.False(peers.CanAddCheckedInPhone("one more"));
    }

    [Fact]
    public void A_browser_connecting_again_gets_a_new_token_on_the_same_record()
    {
        var peers = new PeerList();
        var first = peers.ConnectBrowser("browser-id", "", "t1");
        var again = peers.ConnectBrowser("browser-id", "Safari", "t2");

        Assert.Same(first, again);
        Assert.Equal("Browser", again.Name);
        Assert.Equal("t2", again.AcceptToken);
        Assert.True(again.IsBrowser);
    }

    [Fact]
    public void Removing_a_browser_leaves_other_peers_with_its_name()
    {
        var peers = new PeerList
        {
            new() { Name = "Phone", Platform = DevicePlatform.Web },
            new() { Name = "phone", Platform = DevicePlatform.IOS },
        };
        peers.RemoveBrowser("PHONE");

        Assert.Equal(DevicePlatform.IOS, Assert.Single(peers).Platform);
    }

    [Fact]
    public void Tailscale_pairing_pins_the_identity_unless_another_peer_has_it()
    {
        var peers = new PeerList { new() { Name = "Mac", Token = "typed" }, new() { Name = "Mini" } };
        var info = new PairInfo("minted-there", "Mac", "mac1", FpA, 53319, new List<string> { "192.168.1.5:53319" }, null);
        peers.ApplyTailscalePairing(peers[0], "minted-here", info);

        Assert.Equal("minted-here", peers[0].AcceptToken);
        Assert.Equal("minted-there", peers[0].Token);
        Assert.Equal("mac1", peers[0].Id);
        Assert.Equal(FpA, peers[0].Fingerprint);
        Assert.Equal(53319, peers[0].TlsPort);

        // Mini answers with the identity Mac now has.
        peers.ApplyTailscalePairing(peers[1], "m2", info with { Token = "t2" });
        Assert.Equal("", peers[1].Id);
        Assert.Equal("", peers[1].Fingerprint);
        Assert.Equal("t2", peers[1].Token);
    }

    [Fact]
    public void Lan_pairing_updates_the_same_device_paired_over_tailscale()
    {
        var peers = new PeerList { new() { Name = "Work Mac", Host = "mac.example.ts.net", Fingerprint = FpA, Token = "old" } };
        var pairing = new LanPairing("mac1", "MacBook Pro", DevicePlatform.MacOS, FpA, 53319, new[] { "192.168.1.5:53319" }, "minted");
        var peer = peers.ApplyLanPairing(pairing, new PairInfo("new", null, null, null, null, new List<string>(), "ignored"));

        Assert.Single(peers);
        Assert.Equal("Work Mac", peer.Name);
        Assert.Equal("mac.example.ts.net", peer.Host);
        Assert.Equal("new", peer.Token);
        Assert.Equal("minted", peer.AcceptToken);
        Assert.Equal(53319, peer.TlsPort);
        Assert.Equal(new[] { "192.168.1.5:53319" }, peer.Lan);
    }

    [Fact]
    public void Lan_pairing_with_a_new_device_takes_its_tailscale_host()
    {
        var peers = new PeerList();
        var pairing = new LanPairing("pc1", "Desk", DevicePlatform.Windows, FpB, 53319, new[] { "10.0.0.2:53319" }, "minted");
        var peer = peers.ApplyLanPairing(pairing, new PairInfo("t", null, null, null, 60001, new List<string> { "10.0.0.9:60001" }, "desk.ts.net"));

        Assert.Equal("desk.ts.net", peer.Host);
        Assert.Equal(60001, peer.TlsPort);
        Assert.Equal(new[] { "10.0.0.9:60001" }, peer.Lan);
    }

    [Fact]
    public void Learning_from_ping_fills_in_but_never_replaces()
    {
        var peer = new Peer { Name = "Mac", Id = "mac1" };
        peer.Learn(new PingInfo(DevicePlatform.MacOS, "other", FpA, 53319));

        Assert.Equal(DevicePlatform.MacOS, peer.Platform);
        Assert.Equal("mac1", peer.Id);
        Assert.Equal(FpA, peer.Fingerprint);
        Assert.Equal(53319, peer.TlsPort);

        peer.Learn(new PingInfo(DevicePlatform.Unknown, null, FpB, 1));
        Assert.Equal(DevicePlatform.MacOS, peer.Platform);
        Assert.Equal(FpA, peer.Fingerprint);
        Assert.Equal(53319, peer.TlsPort);
    }

    [Fact]
    public void The_iphone_switch_keeps_browsers_browsers()
    {
        var computer = new Peer { Platform = DevicePlatform.MacOS };
        computer.IsPhone = false;
        Assert.Equal(DevicePlatform.MacOS, computer.Platform);
        computer.IsPhone = true;
        Assert.Equal(DevicePlatform.IOS, computer.Platform);
        computer.IsPhone = false;
        Assert.Equal(DevicePlatform.Unknown, computer.Platform);

        var browser = new Peer { Platform = DevicePlatform.Web };
        browser.IsPhone = true;
        Assert.Equal(DevicePlatform.Web, browser.Platform);
    }
}
