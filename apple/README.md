# Droprr for Mac and iPhone

Native SwiftUI apps that speak the protocol in [`docs/PROTOCOL.md`](../docs/PROTOCOL.md).

| Target | What it is |
| --- | --- |
| `DroprrMac` | Menu bar app. Receives into `~/Downloads/Droprr`, sends files, text and the clipboard, keeps an outbox for iPhones (`/inbox`), and shows a pairing QR code. |
| `DroprrMacShare` | Mac share extension: Share › Droprr in Finder, Safari, Photos and other apps. |
| `DroprriOS` | iPhone app. Sends the clipboard, photos, files and text, collects items the computers queued for it each time it opens, and pairs by scanning a QR code. |
| `DroprrShare` | iPhone share extension: pick Droprr in any share sheet, then tap a computer. |

## Setup

1. Create your local config and fill in your team ID and a bundle ID prefix. The file is gitignored,
   so personal values never reach the repo.

   ```bash
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

2. Open the project, then run `DroprrMac` on the Mac and `DroprriOS` on the iPhone.
   Xcode creates the signing profiles and app groups.

   ```bash
   open Droprr.xcodeproj
   ```

3. Install Tailscale on every device and sign in to the same tailnet.

4. Pair the iPhone with each computer: on the computer, choose **Pair a Phone** (the QR button in the
   Mac's menu bar panel, or Add Device in Settings). On the iPhone, scan the code with the Camera app
   or with Droprr (Settings › QR button). The phone stores that computer's token, and the computer adds
   the phone automatically.

5. To send from the Mac to the PC, add the PC in the Mac's Settings with its Tailscale name and its token.

## How it works

- **Receiving (Mac):** a small HTTP server on port 53318 that only accepts loopback and Tailscale
  addresses (100.64.0.0/10 and fd7a:115c:a1e0::/48) and checks the Bearer token. Text and links are
  copied to the clipboard; the *Auto-copy received items* setting also copies files and images.
- **Phones:** iOS can't listen in the background, so sends to an iPhone wait in the Mac's outbox
  (`~/Library/Application Support/<bundle id>/Outbox`, 7-day expiry). The iPhone collects them with
  `GET /inbox` whenever it opens or you pull to refresh on Received.
- **Tokens:** each computer has its own token. The iPhone keeps one per computer, from that computer's QR code.
- **Mac share extension:** sandboxed, so it hands items for an iPhone to the running Mac app over
  loopback (`POST /outbox/<peer id>`, Apple-internal, not part of the protocol).
- **Settings storage:** UserDefaults in an app group (`<team ID>.droprr` on the Mac,
  `group.<prefix>.droprr` on iOS) so the share extensions can read them.

## Project layout

| Folder | Compiled into |
| --- | --- |
| `Shared/` | All four targets: protocol client and server, settings, pairing, theme |
| `Mac/` | `DroprrMac` |
| `MacShareExtension/` | `DroprrMacShare` |
| `iOS/` | `DroprriOS` |
| `ShareExtension/` | `DroprrShare` |
| `Config/` | Info.plists, entitlements and xcconfigs |
| `scripts/` | `generate_project.py`, which rebuilds the Xcode project |

The project uses Xcode folder-synced groups, so new `.swift` files in these folders are picked up
without editing the project. Run `scripts/generate_project.py` only when adding a target or changing
build settings.

Icons come from `file-swap-icon-pack/` at the repo root.
