# Droprr

Droprr sends files, photos, text, and links between your own Windows PC, Mac, and iPhone. It works over your private [Tailscale](https://tailscale.com) network: devices find each other by their Tailscale names, so it works the same at home or away.

## How it works

- **Tailscale only.** Every device runs Tailscale on the same tailnet. Droprr accepts connections only from Tailscale addresses (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) and from the device itself, never from your LAN or the internet. Tailscale encrypts the traffic.
- **One port.** Each computer listens on port `53318` by default (changeable in Settings).
- **A token per computer.** Every request carries that computer's secret token. Pairing hands the token to your phone with a QR code, so you rarely type it.
- **Phones collect.** An iPhone can't accept connections in the background, so anything sent to it waits on the sending computer for up to 7 days. The phone collects it when the app opens.
- **An open protocol.** It's a small HTTP API, described in [docs/PROTOCOL.md](docs/PROTOCOL.md).

Received items land in a `Droprr` folder in Downloads. Text and links also go straight to the clipboard, and a setting copies files and images too.

## Features

| | Windows | Mac | iPhone |
| --- | --- | --- | --- |
| App | Tray app with a Send window | Menu bar app with a Send window | App with Send and Received tabs |
| Send from other apps | Explorer's **Send to › Droprr** | **Share › Droprr** | **Share › Droprr** |
| Receive | Always, into `Downloads\Droprr` | Always, into `~/Downloads/Droprr` | While open, and collects queued items when it opens |
| Hold items for an iPhone | Yes, with a "N waiting" badge to clear them | Yes | n/a |
| Pair a phone by QR code | Yes | Yes | Scans the code (Camera or in-app) |
| Auto-copy received items to the clipboard | Yes | Yes | n/a |
| Start at sign-in | Yes | Yes (launch at login) | n/a |

## Setup

Install Tailscale on every device and sign in to the same tailnet first.

### Windows

1. Install the [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0).
2. Publish a build. This creates `deploy\<yyyyMMdd-HHmmss>\Droprr.exe`:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1
   ```

3. Start that `Droprr.exe` once. It creates `%APPDATA%\Droprr\settings.json` with a random token, adds itself to the Start menu (so Windows Search finds it) and to Explorer's **Send to** menu, and appears in the tray.
4. Allow Droprr through Windows Firewall from Tailscale addresses only. Run this once in an elevated PowerShell:

   ```powershell
   New-NetFirewallRule -DisplayName "Droprr (Tailscale)" -Direction Inbound -Protocol TCP -LocalPort 53318 -RemoteAddress 100.64.0.0/10 -Action Allow
   ```

**Using it:** left-click the tray icon to open the Send window, or right-click it for the menu: Recent items, the Droprr folder, Settings, and how many items are waiting for your phone. Starting Droprr again while it's running just brings up the Send window. In Settings you can rename the PC, change the port or save folder, turn on **Start Droprr when I sign in to Windows** and **Auto-copy received items to clipboard**, manage the token, and add or remove devices.

**Updates install themselves.** After changing the code, run `scripts\deploy.ps1` again. Within a few seconds, the running Droprr starts the new build and exits (it waits if something is arriving), reopening any window you had open. The newest two builds are kept, and the Start menu, **Send to**, and sign-in entries follow the new build.

To build without deploying, run `dotnet build` in the repo root.

### Mac and iPhone

1. Copy `apple/Config/Local.xcconfig.example` to `apple/Config/Local.xcconfig` (gitignored) and set your Apple team ID and a bundle ID prefix.
2. Open `apple/Droprr.xcodeproj` in Xcode, then run the `DroprrMac` target on the Mac and the `DroprriOS` target on the iPhone.

See [apple/README.md](apple/README.md) for details.

## Pairing

1. On a computer, open **Pair a phone**: in Settings › Devices on Windows, or with the QR button in the Mac's menu bar panel.
2. On the iPhone, scan the code with the Camera app or with Droprr's QR button.

The phone saves that computer's address and token, and the computer adds the phone to its devices, so each can send to the other. The QR code contains the token, so show it only to your own phone.

To send between two computers, add each one in the other's Settings with its Tailscale name and its token.

## iPhone shortcuts (optional)

Without the iPhone app, you can still send to a computer from the share sheet, and collect queued items, with two Shortcuts. See [docs/ios-shortcut.md](docs/ios-shortcut.md).

## Troubleshooting

- **The phone or another computer can't connect (timeout):** check that Tailscale is connected on both devices and that the Windows Firewall rule exists. On the phone, opening `http://<pc>:53318/ping` in Safari should immediately show an "unauthorized" error, which means the PC is reachable.
- **"unauthorized":** the token doesn't match. Pair again, or copy the token from the receiving computer's Settings.
- **Droprr doesn't show up in Windows Search:** check that **Add Droprr to the Start menu and Windows Search** is on in Settings.
- **The tray icon is hidden:** Windows puts new tray icons behind the **^** arrow. Drag Droprr onto the taskbar to keep it visible.
- **Developing with an AI agent or another sandboxed tool:** processes started from inside a packaged (MSIX) app have their AppData writes redirected into that app's private storage. A Droprr launched that way gets a separate settings file and token that you won't see. Start Droprr yourself, and let `scripts\deploy.ps1` plus the self-update hand new builds to it.

## Repository layout

| Path | What's there |
| --- | --- |
| `src/Droprr.Windows/` | The Windows app (WPF on .NET 10, styled with [WPF UI](https://github.com/lepoco/wpfui)) |
| `apple/` | The Mac and iPhone apps (SwiftUI, Xcode project) |
| `docs/PROTOCOL.md` | The HTTP protocol every Droprr app speaks |
| `docs/ios-shortcut.md` | Optional iPhone Shortcuts |
| `scripts/deploy.ps1` | Publishes a Windows build for the self-updating app |
| `file-swap-icon-pack/` | App and tray icons for every platform |

`deploy/`, `bin/`, and `obj/` are build output and ignored by git, as are personal files such as `settings.json` and `apple/Config/Local.xcconfig`. Never commit tokens, host names, or IP addresses.
