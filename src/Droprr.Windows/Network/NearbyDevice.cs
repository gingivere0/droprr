using System.Windows;

namespace Droprr;

// A device in Settings' "Nearby on this network" list: one that can be paired, or one already paired under
// another name.
public sealed record NearbyDevice(LanDevice Device, string? PairedAs)
{
    public string Name => Device.Name;
    public DevicePlatform Platform => Device.Platform;
    public string? PairedLabel => PairedAs is null ? null : $"Paired as {PairedAs}";
    public Visibility PairVisibility => PairedAs is null ? Visibility.Visible : Visibility.Collapsed;
    public Visibility LabelVisibility => PairedAs is null ? Visibility.Collapsed : Visibility.Visible;
}
