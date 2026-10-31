namespace Droprr;

// The Send window's last device tile, which opens the one code (Pair a phone).
public sealed class AddDeviceTile
{
    public static readonly AddDeviceTile Instance = new();

    public string Name => "Add a device";
}
