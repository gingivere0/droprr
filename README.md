# Droprr

Droprr sends files, text, and links between your own devices over [Tailscale](https://tailscale.com): a Windows PC and an iPhone today, with a Mac app planned.

- **Windows:** a tray app that receives items, saves them to `Downloads\Droprr`, copies text and links to the clipboard, and shows a notification. It can also send to other Droprr devices from a window or from Explorer's **Send to** menu.
- **iPhone:** a Share Sheet shortcut. See [docs/ios-shortcut.md](docs/ios-shortcut.md).
- **Protocol:** a small authenticated HTTP API. See [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Windows setup

Requires the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) to build.

```bash
dotnet build
```

Run `src/Droprr.Windows/bin/Debug/net10.0-windows/Droprr.exe`. On first run, Droprr:

- creates `%APPDATA%\Droprr\settings.json` with a random token (see [settings.example.json](src/Droprr.Windows/settings.example.json) for the format),
- adds **Droprr** to Explorer's **Send to** menu, and
- starts listening on port `53318` on its Tailscale address and localhost.

### Firewall

Windows Firewall blocks incoming connections by default. Allow Droprr's port from Tailscale addresses only, in an elevated PowerShell:

```powershell
New-NetFirewallRule -DisplayName "Droprr (Tailscale)" -Direction Inbound -Protocol TCP -LocalPort 53318 -RemoteAddress 100.64.0.0/10 -Action Allow
```

### Settings

Right-click the tray icon and choose **Edit settings**, then **Reload settings** after you save.

- `deviceName`: the name other devices see.
- `port`: the port to listen on.
- `token`: the shared secret every request must send. Keep it private.
- `saveFolder`: where received items go. `null` means `Downloads\Droprr`.
- `peers`: devices this PC can send to, by Tailscale hostname.

`settings.json` is ignored by git. Never commit real tokens or hostnames.
