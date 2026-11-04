using System;
using Xunit;

namespace Droprr.Tests;

// The join secret stays open while anyone holds a lease on it, and each lease ends on its own.
public class BrowserAccessTests
{
    [Fact]
    public void ClosedUntilALeaseOpensIt()
    {
        var access = new BrowserAccess();
        Assert.Null(access.Secret);
        Assert.False(access.IsSecret("anything"));
        access.OpenJoin();
        Assert.NotNull(access.Secret);
        Assert.True(access.IsSecret(access.Secret));
    }

    [Fact]
    public void ASecondLeaseKeepsTheSameSecret()
    {
        var access = new BrowserAccess();
        access.OpenJoin();
        var first = access.Secret;
        access.OpenJoin();
        Assert.Equal(first, access.Secret);
    }

    [Fact]
    public void ClosingOneLeaseKeepsTheOtherOpen()
    {
        var access = new BrowserAccess();
        var window = access.OpenJoin();
        var invite = access.OpenJoin();
        var secret = access.Secret;
        access.CloseJoin(window);
        Assert.Equal(secret, access.Secret);
        access.CloseJoin(invite);
        Assert.Null(access.Secret);
    }

    [Fact]
    public void AnExpiredLeaseLetsGo()
    {
        var access = new BrowserAccess();
        access.OpenJoin(TimeSpan.Zero);
        Assert.Null(access.Secret);
        var window = access.OpenJoin();
        access.OpenJoin(TimeSpan.Zero);
        Assert.NotNull(access.Secret);
        access.CloseJoin(window);
        Assert.Null(access.Secret);
    }

    [Fact]
    public void ReopeningAfterTheLastLeaseMakesANewSecret()
    {
        var access = new BrowserAccess();
        var lease = access.OpenJoin();
        var first = access.Secret;
        access.CloseJoin(lease);
        access.OpenJoin();
        Assert.NotEqual(first, access.Secret);
    }
}
