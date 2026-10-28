# Droprr

Droprr sends files, text, and links between your own devices over [Tailscale](https://tailscale.com): a Windows PC and an iPhone today, with a Mac app planned.

- **Windows:** a tray app that receives items, saves them to `Downloads\Droprr`, copies text and links to the clipboard, and shows a notification. It sends to other devices from its Send window or from Explorer's **Send to** menu, and holds items for your iPhone until the phone picks them up.
- **iPhone:** a "Send to PC" Share Sheet shortcut, and a "Get from PC" shortcut that picks up anything waiting. See [docs/ios-shortcut.md](docs/ios-shortcut.md).
- **Icons:** the shared artwork for every platform is in [file-swap-icon-pack](file-swap-icon-pack/README.md).
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

Right-click the tray icon and choose **Settings…**. There you can:

- rename this PC, change the port, and pick where received items are saved,
- turn on **Start Droprr when I sign in to Windows**,
- keep **Add Droprr to the Start menu and Windows Search** on (the default) so typing "Droprr" in Windows Search finds it,
- show, copy, or replace the token every device needs, and
- add, edit, or remove devices. Computers are listed by Tailscale host name; turn on **iPhone** for phones.

Everything is stored in `%APPDATA%\Droprr\settings.json` (see [settings.example.json](src/Droprr.Windows/settings.example.json)). That file is ignored by git: never commit real tokens or host names.

### Sending to your iPhone

A phone can't accept incoming connections, so items you send to an iPhone wait on the PC (in `%APPDATA%\Droprr\outbox`) until the phone runs **Get from PC**, for up to 7 days. The tray shows how many are waiting. The first time your phone runs Get from PC, it's added to your devices automatically.
