# Droprr for Mac and iPhone

Native SwiftUI apps that speak the protocol in [`docs/PROTOCOL.md`](../docs/PROTOCOL.md).

| Target | What it is |
| --- | --- |
| `DroprrMac` | Menu bar app. Receives into `~/Downloads/Droprr` (text and links go to the clipboard), sends files, text and the clipboard. |
| `DroprriOS` | iPhone app. Sends the clipboard, photos, files and text. Receives only while it is open (iOS stops background listeners); received files appear in Files › On My iPhone › Droprr. |
| `DroprrShare` | Share extension inside the iPhone app. Pick "Droprr" in any share sheet, then tap a device. |

The receiver only accepts connections from loopback and Tailscale addresses
(100.64.0.0/10 and fd7a:115c:a1e0::/48), and every request needs the shared pairing token.

## First-time setup

1. Copy the local config and fill in your own team ID and a bundle ID prefix.
   This file is gitignored, so personal values never reach the repo.

   ```bash
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

2. Open the project in Xcode.

   ```bash
   open Droprr.xcodeproj
   ```

3. Run `DroprrMac` on the Mac. Run `DroprriOS` on your iPhone (plug it in or pair it over Wi‑Fi,
   then pick it as the run destination). Xcode creates the signing profiles and the app group for you.

4. On every device, open Settings and:
   - paste the **same pairing token** (or generate one on one device and copy it to the others),
   - add each other device by its **Tailscale name** (for example `my-pc`) or 100.x address,
   - press **Test** next to a device to check it answers.

The first time the Mac app receives a connection, macOS may ask whether Droprr may accept incoming
network connections. Allow it.

## Notes

- Default port is 53318, matching the Windows app. Change it in Settings if needed.
- The project uses Xcode folder-synced groups, so new `.swift` files dropped into `Shared/`, `Mac/`,
  `iOS/` or `ShareExtension/` are picked up without editing the project. `Shared/` is compiled into all three targets.
