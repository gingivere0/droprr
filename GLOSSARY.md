# Glossary

The words Droprr's code, docs, and commits use for its domain. The protocol itself is in [docs/PROTOCOL.md](docs/PROTOCOL.md); decisions about the code's shape are in [docs/adr/](docs/adr/).

## Devices

- **Device**: a computer or phone running Droprr, or a browser using it. Each app device has a stable **device id** and its own certificate.
- **Peer**: another device this one knows and can send to. Saved in settings (`Peer` on every platform). A peer's **platform** is `windows`, `macos`, `ios`, or `web`, and is unknown until pairing or a ping says.
- **Computer**: a Windows PC or Mac. Computers listen, so they're sent to directly.
- **Queue-only peer**: an iPhone without Droprr open, or a browser. Items for it wait in this computer's **outbox** until it checks its **inbox** (`GET /inbox`).
- **Nearby device**: a device found on the local network by Bonjour. Discovery only finds addresses; it never makes a device trusted.

## Trust

- **Main token**: a device's own token, in its pairing QR code and Settings. Never sent to a peer.
- **Device token**: a token one device mints for a peer during pairing. The **send token** is the one this device uses to call the peer; the **accept token** is the one it accepts from the peer. Pairing again replaces both.
- **Pin**: the SHA-256 fingerprint of a peer's certificate, saved at pairing. Every local network connection must present the pinned certificate.
- **Pairing**: two devices exchanging device tokens (and ids and pins). The kinds:
  - **QR pairing**: scanning a code that carries the main token (`POST /pair`).
  - **The one code**: the code from Pair a phone or Add a device. It opens Browser access and lets the Droprr app pair with a **join secret** instead of a token.
  - **LAN pairing**: pairing with a nearby device over HTTPS. Both screens show a six-digit code, and the person confirms on the receiving device.
  - **Tailscale pairing**: a computer added with a typed token calls the other's `POST /pair` over Tailscale.
  - **Pairing again** (repair): a device already paired pairs again with consent, getting fresh tokens on the same peer and never an "already paired" error.
- **Pair target**: which saved peer a pairing applies to: **match** (main token: same device id, else same name, else new), **new** (a confirmed pairing with a device not seen before), **update** (the peer whose device token authenticated the request: it may only fill in its identity), or **repair** (pairing again: identity replaced). `PairTarget` on Windows and the Mac and iPhone.
- **Same device**: two peer records that share a device id or pin and don't have two different ids or two different pins. They're **merged** into the older record. A shared host alone is never enough.

## Getting there

- **Path**: how a send reaches a peer: **Wi-Fi** (the local network, HTTPS on the HTTP port + 1, pinned) or **Tailscale** (plain HTTP to a Tailscale address only). Wi-Fi first when the peer was seen recently, never both for one send.
- **Browser access**: sending to and from a phone's browser. Either the computer's own page (`/web`, on the same Wi-Fi or Tailscale) or the **website** (site/), which meets the computer through the **relay** and then talks to it directly over WebRTC.
- **Room**: a computer's place on the relay, named from its **host key**. The relay only introduces; it never sees what's sent.
