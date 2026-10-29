# Droprr protocol

Version 1, plus the planned [local network transport](#local-network-lan-transport) (protocol 2). The Windows and Mac apps implement all of version 1. The iPhone app receives directly only while it's open, and otherwise collects items through the [inbox](#inbox-phone-pull).

Devices talk over plain HTTP inside a Tailscale network. Tailscale's WireGuard tunnel already encrypts and authenticates the connection between devices, and a shared bearer token keeps other devices on the tailnet out.

## Transport

- **Addresses:** a receiver accepts connections only from its Tailscale network and from localhost. The simplest way is to listen only on its Tailscale IPv4 address (in `100.64.0.0/10`) and on localhost. See [Implementation notes](#implementation-notes) for the alternative.
- **Port:** configurable. The default is **`53318`**.
- **Host names:** senders address peers by their Tailscale MagicDNS name, for example `http://my-pc:53318`.
- **Auth:** every request, including `/ping`, must send `Authorization: Bearer <token>`, using one of the receiver's [tokens](#tokens). A missing or wrong token gets `401`.
- **Encoding:** JSON bodies and responses are UTF-8 with `Content-Type: application/json`.

## Tokens

Each device has one **main token** plus one **device token** per paired peer.

- **Main token:** shown in the device's pairing QR code and in its Settings. "Generate new token" (or "New token") replaces the main token only; device tokens keep working.
- **Device tokens:** minted during [`POST /pair`](#post-pair), one per peer: 32 random bytes, base64url-encoded without padding.
- **Authorization:** a request is authorized if its bearer token matches the main token or any device token. Compare against each one in constant time.
- **What a device stores per peer:** `acceptToken`, the device token it minted for that peer and accepts from it, and `token`, the token it sends when calling that peer (empty for phones, which can't be called).
- **Re-pairing** the same name replaces that peer's `acceptToken`, so the old one stops working. **Removing** a device deletes its `acceptToken`, so it can no longer connect.
- **Never send your own main token to a peer.** A computer peer with no `token` isn't paired: the app shows "Not paired: scan its code or enter its token" and doesn't send to it. A token the user enters by hand (for example, another device's main token) still works.
- Peers paired before device tokens existed keep their stored tokens and keep working; nobody has to pair again.

## Endpoints

| Endpoint | Purpose |
| --- | --- |
| [`GET /ping`](#get-ping) | Check that a device is reachable and the token is right. |
| [`POST /send`](#post-send) | Send files, text, or links. Also accepts [lenient inputs](#lenient-inputs). |
| [`POST /pair`](#post-pair) | Introduce yourself after scanning a [pairing QR](#pairing-qr). |
| [`GET /inbox?for=<name>`](#get-inboxfordevice-name) | A phone lists items a desktop queued for it. |
| [`GET /inbox/<id>`](#get-inboxid) | Download one queued item. |
| [`DELETE /inbox/<id>`](#delete-inboxid) | Acknowledge a queued item so it's removed. |

All of them require the bearer token and use the error shape below.

## Errors

Every error response, on any endpoint, has a 4xx or 5xx status and this body:

```json
{ "ok": false, "error": "human-readable message" }
```

| Status | Meaning |
| --- | --- |
| `400` | Bad request: empty content, unknown `type`, invalid URL, malformed JSON, no items, a missing `?for=`, or invalid `/pair` fields. |
| `401` | Missing or wrong token. |
| `404` | Unknown path. |
| `500` | The receiver failed. The body says `"receiver error"`; details stay in the receiver's local log, never in the response. |
| `507` | Not enough disk space: a `/send` body with a known `Content-Length` would leave less than 1 GB free on the drive it saves to. |

## `GET /ping`

Checks that a device is reachable and the token is right.

```http
GET /ping HTTP/1.1
Authorization: Bearer <token>
```

Response `200`:

```json
{ "name": "My PC", "version": "0.1.0", "platform": "windows", "protocol": 1 }
```

- `name` (string): the device's display name from its settings.
- `version` (string): the app's version.
- `platform` (string): one of `"windows"`, `"macos"`, or `"ios"`.
- `protocol` (integer): the protocol version this document describes, `1`. Separate from the app's `version`.

## `POST /send`

Sends one or more items. The body is either multipart or JSON.

### Files: `multipart/form-data`

Each part with a `filename` is saved as a file. Use the field name `file` for each file. One request may carry several files.

```bash
curl -H "Authorization: Bearer <token>" -F "file=@photo.jpg" -F "file=@notes.pdf" http://my-pc:53318/send
```

A multipart body may also carry plain form fields. They become text or url items; see [Multipart parts](#multipart-parts).

### Text and links: `application/json`

```json
{ "type": "text", "content": "any text" }
```

```json
{ "type": "url", "content": "https://example.com/page" }
```

- `type` must be `"text"` or `"url"`.
- `content` must be non-empty. For `"url"`, it must be a single absolute URL with no line breaks.
- **Links are `http` and `https` only.** A `"url"` whose scheme is anything else (such as `file:` or `javascript:`) is saved and handled as text, not rejected.

### Response

Response `200` when everything in the request was saved:

```json
{ "ok": true, "received": 2 }
```

`received` (integer) is the number of items saved: files plus `text` and `url` items.

## Lenient inputs

Clients such as iOS Shortcuts can't always build the bodies above, so `POST /send` also accepts the following. This is part of protocol version 1, and every receiver must implement it exactly. The response and error shapes are unchanged.

### How the body is classified

| Content-Type | Filename present? | Result |
| --- | --- | --- |
| `multipart/form-data` | per part | See [Multipart parts](#multipart-parts). |
| `application/json` | n/a | The JSON form above. |
| `application/x-www-form-urlencoded` | n/a | See [URL-encoded forms](#url-encoded-forms). |
| `text/plain` | no | One **text** item, or one **url** item if the body is a single web URL. |
| `text/plain` | yes | One **file**. |
| anything else, or missing | either | One **file** (a raw upload). |

"Filename present" means an `X-Droprr-Filename` header or a `Content-Disposition` header with a filename.

**Single web URL:** after trimming leading and trailing whitespace, the value contains no whitespace and parses as an absolute URL with scheme `http` or `https`.

### Raw uploads

The whole request body is the file. This is what Shortcuts sends for **Request Body: File**. The file name is the first of:

1. the `X-Droprr-Filename` header, percent-decoded (for example `My%20Photo.HEIC` becomes `My Photo.HEIC`);
2. the `filename*` parameter of a `Content-Disposition` header, then its `filename` parameter;
3. `Droprr yyyy-MM-dd HHmmss` (local time).

If the resulting name has no extension (including the fallback), the receiver appends one from the table below, based on the Content-Type's media type with any parameters removed. For example, `X-Droprr-Filename: IMG_0042` with `Content-Type: image/heic` is saved as `IMG_0042.heic`.

| Media type | Extension |
| --- | --- |
| `image/jpeg` | `.jpg` |
| `image/png` | `.png` |
| `image/heic` | `.heic` |
| `image/heif` | `.heif` |
| `image/gif` | `.gif` |
| `image/webp` | `.webp` |
| `video/quicktime` | `.mov` |
| `video/mp4` | `.mp4` |
| `audio/mpeg` | `.mp3` |
| `audio/mp4` | `.m4a` |
| `application/pdf` | `.pdf` |
| `application/zip` | `.zip` |
| `text/plain` | `.txt` |
| anything else, or missing | `.bin` |

Whichever name is used goes through the same cleanup as multipart file names. An empty body is a `400` with `"empty body"`.

### Multipart parts

- A part with a filename (`filename` or `filename*` in its `Content-Disposition`) is a **file**, whatever its field name.
- A part without a filename is **text**, or **url** if its value is a single web URL, whatever its field name. Empty parts are ignored.

### URL-encoded forms

Fields are read in this order: `url`, `content`, `text`, `file`. Other fields and empty values are ignored.

- `url` is a **url** item, and must be a valid absolute URL (otherwise `400`). If its scheme isn't `http` or `https`, it's saved and handled as **text**.
- `content`, `text`, and `file` are **text**, or **url** if the value is a single web URL.

This is what Shortcuts sends for a Form body whose field is Text rather than File.

## What a receiver does

- **Files** are saved to a `Droprr` folder in the user's Downloads (configurable). File names lose any path parts and invalid characters, and an existing file is never overwritten: the receiver adds ` (1)`, ` (2)`, and so on instead.
- **Text** is saved as `Text <date time>.txt` and copied to the clipboard.
- **Links** (`http` and `https` only) are saved as an internet shortcut and copied to the clipboard. A receiver only ever opens `http` and `https` links; anything else is copied as text.
- A notification appears for each item.
- There's no size limit, so receivers should stream files to disk rather than hold them in memory.

## Inbox (phone pull)

A phone can't listen for incoming connections, so it pulls items from desktops instead.

- **Outbox:** each desktop keeps an outbox per peer. A send to a peer whose `/ping` reports `"platform": "ios"` is always queued in that peer's outbox and never pushed directly.
- **Polling:** the phone polls each desktop peer when its app opens, or when the "Get from PC" shortcut runs.
- **Expiry:** items expire 7 days after they're queued, whether or not they were fetched.

All inbox endpoints need the same `Authorization: Bearer <token>` header and use the [error shape](#errors) above.

**Scoping:** when a request authenticates with a [device token](#tokens), all three inbox endpoints act only on that peer's queue. `?for=` is ignored (but still accepted), and an `id` from another queue returns `404`. With the main token, `?for=` picks the queue by name, which the iOS shortcuts rely on.

### `GET /inbox?for=<device name>`

Lists the items queued for the named device, oldest first. `<device name>` is the phone's `name`, URL-encoded.

Response `200`:

```json
{
  "ok": true,
  "items": [
    {
      "id": "3f1c2a9e-8d4b-4e0a-9c7f-2b6d5e1a0c34",
      "type": "file",
      "name": "photo.jpg",
      "size": 482113,
      "created": "2026-10-28T09:00:00Z"
    },
    {
      "id": "a7e0b5d2-1c3f-4a8e-b6d9-0f2e4c1b7a95",
      "type": "url",
      "name": "Link",
      "size": 24,
      "content": "https://example.com/page",
      "created": "2026-10-28T09:01:00Z"
    }
  ]
}
```

- `id` (string): a UUID.
- `type` (string): `"file"`, `"text"`, or `"url"`.
- `name` (string): the file name for files; a short label for text and links.
- `size` (integer): bytes. For text and links, the UTF-8 length of `content`.
- `content` (string): present only for `text` and `url` items.
- `created` (string): when the item was queued, in ISO 8601 UTC.

An empty outbox returns `"items": []`.

### `GET /inbox/<id>`

Downloads a `file` item's bytes, with `Content-Type` set to the file's media type (`application/octet-stream` if unknown) and `Content-Disposition: attachment; filename="..."` (plus `filename*=UTF-8''...` for non-ASCII names). An unknown or expired `id` returns `404`.

For a `text` or `url` item, it returns `200` with the item's `content` as the body and `Content-Type: text/plain; charset=utf-8`.

### `DELETE /inbox/<id>`

Acknowledges an item and removes it from the outbox. The phone calls this after it has saved the item.

Response `200`:

```json
{ "ok": true }
```

An unknown or expired `id` returns `404`.

## Pairing QR

A desktop can show a QR code that a phone scans to add it as a peer in one step. The code is a URI:

```text
droprr://pair?v=1&name=<name>&host=<host>&port=<port>&token=<token>&platform=<platform>&dns=<dns>
```

| Field | Meaning |
| --- | --- |
| `v` | Payload version. This document describes `1`. A phone that sees a higher version it doesn't understand should say so rather than guess. |
| `name` | The desktop's device name, as returned by its `/ping`. |
| `host` | The desktop's Tailscale IPv4 address. |
| `port` | The desktop's listening port. |
| `token` | The desktop's own token. |
| `platform` | `windows` or `macos`. |
| `dns` | Optional. The desktop's MagicDNS name, without a trailing dot, when it's available. |

**Encoding:** every value is percent-encoded per RFC 3986: anything outside the unreserved characters (`A`–`Z`, `a`–`z`, `0`–`9`, `-`, `.`, `_`, `~`) becomes `%XX` of its UTF-8 bytes. A space is `%20`, never `+`. For example:

```text
droprr://pair?v=1&name=My%20PC&host=100.64.0.1&port=53318&token=EXAMPLE-TOKEN&platform=windows&dns=my-pc.example.ts.net
```

**When a phone scans it:**

1. It keeps the QR code's token for that desktop only. Each desktop has its own tokens; a phone never shares one desktop's token with another.
2. It adds the peer, or updates an existing one matched by `host` or `name`, with the new name, host, `dns`, port, and platform. It should prefer `dns` for connecting when present, since the IP can change, and fall back to `host`.
3. It **must** call [`POST /pair`](#post-pair) right away with the QR code's token, so the desktop adds the phone too and pairing works in both directions. It stores the `token` in the response as that peer's token and uses it from then on instead of the QR code's token.
4. It calls `GET /ping` to confirm the pairing, and tells the user whether it worked.

### `POST /pair`

A device introduces itself to a desktop it just paired with. Requires the desktop's token, like every other endpoint.

```json
{ "name": "iPhone", "platform": "ios" }
```

```json
{ "name": "My Mac", "platform": "macos", "host": "my-mac", "port": 53318, "token": "<device token for the desktop to use>" }
```

- `name` (string, required): the caller's device name. For a phone, use the same name it passes to `GET /inbox?for=`.
- `platform` (string, required): `"ios"`, `"macos"`, or `"windows"`.
- `host` (string): required for computers, omitted for phones, which can't accept connections. Prefer the MagicDNS name.
- `port` (integer, optional): the caller's listening port, for computers. Defaults to `53318`.
- `token` (string, optional): computers send it: a device token the caller just minted for this desktop, which the desktop must use whenever it calls the caller. Phones omit it.

Response `200`:

```json
{ "ok": true, "name": "My PC", "token": "<device token for the caller to use>" }
```

`name` is the desktop's device name. `token` is a new [device token](#tokens) the desktop minted for the caller; the caller stores it as this desktop's token and uses it from then on. The desktop adds the caller as a peer, or updates the peer with the same name (case-insensitive), storing the token it minted as that peer's `acceptToken` (replacing any earlier one) and the request's `token` as the token it sends to that peer (empty for phones). An `"ios"` peer is queue-only: sends to it go to its [inbox](#inbox-phone-pull). A desktop keeps a host it already has for a known computer rather than replacing it. The desktop shows a "`<name>` paired" notification and, if its pairing window is open, confirms the pairing there and closes it. Invalid fields return `400`.

A desktop also still adds an unknown name that calls `GET /inbox?for=` as an `"ios"` peer, as a fallback for phones that didn't call `/pair`.

**Handling:** the code contains a secret. A desktop builds it only while the pairing window is open and never saves it to disk or writes it to a log. It warns the user that the code contains the token.

## Local network (LAN) transport

**Protocol 2. Design, not implemented yet.** Protocol 2 lets devices on the same Wi-Fi or wired network reach each other directly, without Tailscale. It's additive: everything above stays as it is, a protocol 1 device keeps working with a protocol 2 device over Tailscale, and the iOS Shortcuts are unaffected.

### Transports

| Transport | Port | Accepted from | Use |
| --- | --- | --- | --- |
| Plain HTTP | `53318` (the existing port setting) | Loopback and Tailscale (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) only | Exactly as in protocol 1: Tailscale peers, protocol 1 peers, and the iOS Shortcuts. |
| HTTPS | `53319` (the HTTP port + 1) | Loopback, Tailscale, and private LAN ranges: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fe80::/10`, and `fd00::/8` | The LAN, where it's required, and Tailscale, where it's optional. |

- A receiver drops any connection from an address outside its port's list, as in [Implementation notes](#implementation-notes). Every request still needs a bearer token, except [`POST /pair/request`](#lan-pairing-post-pairrequest).
- **Tokens and file contents never travel over plain HTTP outside Tailscale.** A sender uses only HTTPS for a LAN address.
- When the **Local network** setting is off, a device doesn't listen on `53319`, advertise, browse, or send over the LAN.

### Device identity

- **Device id:** each device generates a random id once (16 random bytes, base32, lowercase, without padding) and keeps it. Peers match on the id, never on the name, because names can change or repeat.
- **Certificate:** each device generates a self-signed certificate once: an ECDSA P-256 key, a subject of `CN=Droprr <device id>`, and a validity of 20 years. Its private key is protected like the tokens: DPAPI on Windows and the Keychain on Apple. It's never exported or logged.
- **Fingerprint (`fp`):** the SHA-256 of the certificate's DER encoding, as 64 lowercase hex characters, always in full.
- **Pinning:** a client accepts a LAN server only if the server's certificate fingerprint equals the one pinned for that peer. It doesn't check the chain, the host name, or the expiry. On a mismatch, it refuses the connection over that address, falls back to Tailscale if the peer has a Tailscale host, and shows "`<name>`'s identity changed. Pair again." Only pairing again replaces a pinned fingerprint.
- **Where a pin comes from:** the [pairing QR code](#pairing-qr), a `/pair` response, a confirmed [LAN pairing](#lan-pairing-post-pairrequest), or a `/ping` answered over Tailscale, which already authenticates the device. A protocol 1 peer can be upgraded that last way, without pairing again. Discovery never sets or changes a pin.

### Discovery

DNS-SD (Bonjour, mDNS) only, with no custom UDP multicast, because raw multicast on the iPhone needs a restricted entitlement.

- **Service:** `_droprr._tcp`. The instance name is the device name, and the advertised port is the HTTPS port.
- **TXT record:**

  | Key | Value |
  | --- | --- |
  | `v` | `2`, the protocol version |
  | `id` | The [device id](#device-identity) |
  | `name` | The device name |
  | `platform` | `windows`, `macos`, or `ios` |
  | `port` | The HTTPS port, for example `53319` |
  | `fp` | The certificate [fingerprint](#device-identity), in full |

- **Who advertises:** computers whenever Local network is on, and the iPhone only while Droprr is open.
- **Who browses:** every device while Local network is on. The iPhone browses only while open.
- **Trust:** discovery only finds addresses; it never grants trust. When a found instance's `id` matches a paired peer and its `fp` matches that peer's pin, the browser records the instance's addresses as the peer's LAN addresses, with the time it was seen. An instance whose `fp` doesn't match is ignored.
- **APIs:** Windows uses `DnsServiceRegister`, `DnsServiceBrowse`, and `DnsServiceResolve` from `dnsapi.dll` (Windows 10 1809 and later). They work in an unpackaged app on .NET 10 without extra packages. Apple uses Network.framework (`NWListener` and `NWBrowser` with Bonjour).

### Additions to existing messages

- **`GET /ping`** adds `"id"`, `"fp"`, and `"tlsPort"`, and reports `"protocol": 2`. A protocol 1 client ignores the extra fields.
- **Pairing QR:** still payload version `v=1`, with three optional keys that older apps ignore: `id`, `fp`, and `lan`, a comma-separated list of the desktop's current LAN `host:port` pairs for HTTPS (IPv6 in brackets). A scanner that gets `fp` pins it right away.
- **`POST /pair`:** the request may add `"id"`, `"fp"`, `"tlsPort"`, and `"lan"` (an array of `host:port` strings) for the caller, and the response adds the desktop's `"id"`, `"fp"`, `"tlsPort"`, and `"lan"`. Each side stores the other's values.

### LAN pairing (`POST /pair/request`)

Pairing by picking a device that discovery found, without a QR code and without either side showing a token.

1. The requester picks a discovered device and connects to it over HTTPS, accepting whatever certificate it presents, because there's no pin yet. It remembers that certificate's fingerprint as `fpServer`.
2. It sends `POST /pair/request` **without a token**:

   ```json
   { "id": "<requester id>", "name": "iPhone", "platform": "ios", "fp": "<requester fp>" }
   ```

   A computer also sends `"tlsPort"`, `"lan"`, `"host"` (its Tailscale name, if any), and `"token"` (a device token it minted for the receiver), as in [`POST /pair`](#post-pair).
3. Both screens show the same **six-digit code**: the SHA-256 of the two fingerprints in sorted order, joined with `:`, with its first 4 bytes read as a big-endian unsigned integer, modulo 1,000,000, and zero-padded to six digits. The requester computes it from `fpServer` and its own `fp`, and the receiver from its own `fp` and the request's `fp`. Someone in the middle would have to present a different certificate, which changes the code, so the person can see the mismatch.
4. The receiver asks: "Pair with `<name>`? Make sure `<name>` shows `<code>`." The request stays open until the person answers, for up to 60 seconds.
5. **Accept:** the receiver adds or updates the peer (matched by `id`), pins the request's `fp`, mints a device token, and answers `200` with the same body as [`POST /pair`](#post-pair), plus its `id`, `fp`, `tlsPort`, and `lan`. The requester pins `fpServer` and stores the token. **Decline:** `403` with `"declined"`. **No answer:** `408` with `"timed out"`.

**Limits:** only over HTTPS on `53319`, never on plain HTTP. One request at a time: a second one while a prompt is open gets `429`. After three declines or timeouts from the same address within 10 minutes, the receiver answers `429` to that address for 10 minutes. A request is never accepted without a person confirming it.

### Sending

- **Peer record:** besides today's fields, a device stores each peer's `id`, its Tailscale host, its last known LAN addresses with the time they were seen, its pinned `fp`, its `tlsPort`, and the path last used (`lan` or `tailscale`).
- **Order:** if the peer has a pin and a LAN address seen within the last 2 minutes (or still advertised), the sender connects over HTTPS to each LAN address in turn with a connect timeout of about 1.5 seconds. If none answers, it falls back to Tailscale (plain HTTP on the HTTP port, as in protocol 1). It doesn't race the two paths, so a body is never sent twice.
- **Status:** the result names the path, for example "Sent to MacBook (Wi-Fi)" or "Sent to MacBook (Tailscale)", and the peer's last-used path is updated.
- **Addresses:** whenever discovery sees a paired peer's `id` with a new address and a matching `fp`, the stored LAN addresses are replaced.

### Phones

- **Sending to an iPhone:** if the phone is advertising right now (Droprr is open) and has a pin, the computer sends to it directly over HTTPS with `POST /send`. Otherwise it queues the item in the phone's [inbox](#inbox-phone-pull), as today.
- **Inbox polling:** the phone polls whichever path to the computer answers first: LAN HTTPS if the computer is discovered, otherwise Tailscale. The inbox endpoints and their scoping are unchanged.

### Platform notes

- **iPhone:** `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_droprr._tcp`) in Info.plist. Apple's apps handle their own Local Network prompts.
- **Windows firewall:** the HTTPS port needs an inbound rule for the **Private** profile only. Public networks are ignored: no rule there, and no advertising on interfaces whose network category is Public. Without an installer, the app checks for its rule when Local network is on (reading rules needs no elevation). If the rule is missing, Settings shows "Allow Droprr on your private network", which runs one elevated `netsh advfirewall firewall add rule` for the port (a single UAC prompt). It never elevates on its own at startup.
- **Mac:** the existing network server entitlement covers the HTTPS listener.

## Implementation notes

- **Binding:** a listener may bind to all interfaces (`0.0.0.0` or `::`) instead of specific addresses, as long as it immediately drops any connection whose source address isn't loopback, in `100.64.0.0/10` (Tailscale IPv4), or in `fd7a:115c:a1e0::/48` (Tailscale IPv6). This helps on platforms where the Tailscale address is hard to find or changes often.
- **Peer platforms:** a desktop records each peer's `platform` from `POST /pair` or its last successful `/ping`, and its peer editor has an "iPhone" toggle that sets `"platform": "ios"`. When `GET /inbox?for=<name>` arrives with a name that isn't a known peer, the desktop adds it as an `"ios"` peer, so it can be picked as a send target. None of this changes the wire format.
- **Private endpoints:** an app may add loopback-only endpoints for its own parts, such as the Mac share extension handing items to the Mac app's outbox. They aren't part of this protocol, and other devices must not rely on them.
- **Windows hardening:** the Windows app stores every token encrypted for the signed-in user (DPAPI), marks received files with the Mark of the Web (`Zone.Identifier`, internet zone), opens only common media, document, and text types directly (anything else is shown in Explorer), and keeps clipboard writes out of clipboard history and cloud clipboard. None of this changes the wire format.
- **Link files:** platforms may save links in their native shortcut format. Windows saves `Link <date time>.url`, and macOS saves `Link <date time>.webloc`.
