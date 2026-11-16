using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using Xunit;

namespace Droprr.Tests;

// The local API's requests and answers (docs/PROTOCOL.md, "Local API"), which the MCP server depends on.
public sealed class LocalApiTests : IDisposable
{
    readonly string _folder = Path.Combine(Path.GetTempPath(), "droprr-local-api-" + Guid.NewGuid().ToString("N"));
    readonly string _file;

    readonly PeerList _peers =
    [
        new Peer { Name = "Studio PC", Platform = DevicePlatform.Windows, Token = "t1" },
        new Peer { Name = "Phone", Platform = DevicePlatform.IOS },
        new Peer { Name = "Laptop", Platform = DevicePlatform.MacOS },
        new Peer { Name = "Browser 1", Platform = DevicePlatform.Web },
    ];

    public LocalApiTests()
    {
        Directory.CreateDirectory(_folder);
        _file = Path.Combine(_folder, "notes.txt");
        File.WriteAllText(_file, "hi");
    }

    public void Dispose() => Directory.Delete(_folder, recursive: true);

    (LocalApi.SendRequest? Request, LocalApi.Failure? Failure) Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        return LocalApi.ParseSend(document.RootElement, _peers);
    }

    static string Json(object value) => JsonSerializer.Serialize(value);

    [Fact]
    public void Text_and_files_go_to_the_named_device_ignoring_case()
    {
        var (request, failure) = Parse(Json(new { to = " phone ", text = "  hello  ", files = new[] { _file } }));

        Assert.Null(failure);
        Assert.Equal("Phone", request!.Peer.Name);
        Assert.Equal("hello", request.Text);
        Assert.Equal([_file], request.Files);
    }

    [Fact]
    public void Text_alone_or_files_alone_is_enough()
    {
        Assert.Null(Parse(Json(new { to = "Phone", text = "https://example.com" })).Failure);
        Assert.Null(Parse(Json(new { to = "Phone", files = new[] { _file }, text = (string?)null })).Failure);
    }

    [Theory]
    [InlineData("""{"to":"Phone"}""", 400, "nothing to send")]
    [InlineData("""{"to":"Phone","text":"   "}""", 400, "nothing to send")]
    [InlineData("""{"text":"hi"}""", 400, "missing \"to\"")]
    [InlineData("""{"to":"","text":"hi"}""", 400, "missing \"to\"")]
    [InlineData("""{"to":"Phone","text":5}""", 400, "\"text\" must be a string")]
    [InlineData("""{"to":"Phone","files":"a.txt"}""", 400, "\"files\" must be an array")]
    [InlineData("""{"to":"Phone","files":["notes.txt"]}""", 400, "absolute path")]
    [InlineData("""[1]""", 400, "body must be JSON")]
    [InlineData("""{"to":"Toaster","text":"hi"}""", 404, "Devices: Studio PC, Phone, Laptop, Browser 1")]
    [InlineData("""{"to":"Laptop","text":"hi"}""", 409, "Laptop isn't paired")]
    public void Bad_requests_say_what_is_wrong(string json, int status, string message)
    {
        var (request, failure) = Parse(json);

        Assert.Null(request);
        Assert.Equal(status, failure!.Status);
        Assert.Contains(message, failure.Error);
    }

    [Fact]
    public void Missing_files_and_folders_are_refused()
    {
        var missing = Path.Combine(_folder, "gone.txt");
        Assert.Contains("no file at", Parse(Json(new { to = "Phone", files = new[] { missing } })).Failure!.Error);
        Assert.Contains("is a folder", Parse(Json(new { to = "Phone", files = new[] { _folder } })).Failure!.Error);
    }

    [Fact]
    public void A_computer_with_no_devices_says_so()
    {
        using var document = JsonDocument.Parse("""{"to":"Phone","text":"hi"}""");
        var (_, failure) = LocalApi.ParseSend(document.RootElement, new PeerList());

        Assert.Equal(404, failure!.Status);
        Assert.Contains("no devices yet", failure.Error);
    }

    [Fact]
    public void Devices_list_says_how_each_is_reached()
    {
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(LocalApi.Devices("Desk", _peers, peer => peer.Name == "Phone" ? 2 : 9)));
        var root = document.RootElement;
        var devices = root.GetProperty("devices").EnumerateArray().ToDictionary(d => d.GetProperty("name").GetString()!);

        Assert.True(root.GetProperty("ok").GetBoolean());
        Assert.Equal("Desk", root.GetProperty("name").GetString());
        Assert.Equal("computer", devices["Studio PC"].GetProperty("kind").GetString());
        Assert.Equal("windows", devices["Studio PC"].GetProperty("platform").GetString());
        Assert.Equal(0, devices["Studio PC"].GetProperty("waiting").GetInt32());
        Assert.Equal("phone", devices["Phone"].GetProperty("kind").GetString());
        Assert.Equal(2, devices["Phone"].GetProperty("waiting").GetInt32());
        Assert.False(devices["Laptop"].GetProperty("paired").GetBoolean());
        Assert.Equal("browser", devices["Browser 1"].GetProperty("kind").GetString());
        Assert.Equal("web", devices["Browser 1"].GetProperty("platform").GetString());
    }

    [Fact]
    public void Connection_file_has_the_loopback_address_and_token()
    {
        LocalApi.WriteConnectionFile(_folder, 53318, "secret");
        LocalApi.WriteConnectionFile(_folder, 53400, "secret2");

        using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(_folder, LocalApi.ConnectionFileName)));
        Assert.Equal("http://127.0.0.1:53400", document.RootElement.GetProperty("url").GetString());
        Assert.Equal("secret2", document.RootElement.GetProperty("token").GetString());
    }
}
