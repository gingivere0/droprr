# Droprr protocol

Version 1, plus the [local network transport](#local-network-lan-transport) (protocol 2). The Windows and Mac apps implement all of version 1. The iPhone app receives directly only while it's open, and otherwise collects items through the [inbox](#inbox-phone-pull).

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
| [`GET /web`](#browser-access) | The [browser page](#browser-access); with `POST /web/session` and `POST /web/signout`, the only endpoints without a bearer token besides LAN pairing. |

Except where noted, all of them require the bearer token, and all use the error shape below.

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
| `409` | LAN pairing with a device that's already paired. See [Pairing rules](#pairing-rules). |
| `413` | Too large: a `/pair`, `/pair/request`, or `/pair/confirm` body over 64 KB, or a JSON text item over 16 MB. |
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

**Protocol 2.** The Windows, Mac, and iPhone apps implement it. Protocol 2 lets devices on the same Wi-Fi or wired network reach each other directly, without Tailscale. It's additive: everything above stays as it is, a protocol 1 device keeps working with a protocol 2 device over Tailscale, and the iOS Shortcuts are unaffected.

### Transports

| Transport | Port | Accepted from | Use |
| --- | --- | --- | --- |
| Plain HTTP | `53318` (the existing port setting) | Loopback and Tailscale (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) only | Exactly as in protocol 1: Tailscale peers, protocol 1 peers, and the iOS Shortcuts. |
| HTTPS | `53319` (the HTTP port + 1) | Loopback, Tailscale, and private LAN ranges: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `fe80::/10`, and `fd00::/8` | The LAN, where it's required, and Tailscale, where it's optional. |

- A receiver drops any connection from an address outside its port's list, as in [Implementation notes](#implementation-notes). Every request still needs a bearer token, except [`POST /pair/request` and `POST /pair/confirm`](#lan-pairing-post-pairrequest-post-pairconfirm).
- On HTTPS, every protocol 2 client presents its [device certificate](#device-identity) as the TLS client certificate, on every request. A receiver may require it.
- **Tokens and file contents never travel over plain HTTP outside Tailscale.** A sender uses only HTTPS for a LAN address.
- When the **Local network** setting is off, a device doesn't listen on `53319`, advertise, browse, or send over the LAN.

### Device identity

- **Device id:** each device generates a random id once (16 random bytes, base32, lowercase, without padding) and keeps it. Peers match on the id, never on the name, because names can change or repeat.
- **Certificate:** each device generates a self-signed certificate once: an ECDSA P-256 key, a subject of `CN=Droprr <device id>`, and a validity of 20 years. Its private key is protected like the tokens: DPAPI on Windows and the Keychain on Apple. It's never exported or logged.
- **Fingerprint (`fp`):** the SHA-256 of the certificate's DER encoding, as 64 lowercase hex characters, always in full.
- **Pinning:** a client accepts a LAN server only if the server's certificate fingerprint equals the one pinned for that peer. It doesn't check the chain, the host name, or the expiry. On a mismatch, it refuses the connection over that address, falls back to Tailscale if the peer has a Tailscale host, and shows "`<name>`'s identity changed. Pair again." Only pairing again replaces a pinned fingerprint.
- **Where a pin comes from:** the [pairing QR code](#pairing-qr), a `/pair` response, a confirmed [LAN pairing](#lan-pairing-post-pairrequest-post-pairconfirm) (the requester's certificate from the TLS handshake), or a `/ping` answered over Tailscale, which already authenticates the device. A protocol 1 peer can be upgraded that last way, without pairing again. Discovery never sets or changes a pin, and a pin is never moved from one peer to another (see [Pairing rules](#pairing-rules)).

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
- **Trust:** discovery only finds addresses; it never grants trust. When a found instance's `id` matches a paired peer and its `fp` matches that peer's pin, the browser records the instance's addresses as the peer's LAN addresses, with the time it was seen. An instance whose `fp` doesn't match is ignored. Names, like everything else in a TXT record, are shown and logged only after removing control and bidirectional-override characters, cut to 64 characters.
- **APIs:** Windows uses `DnsServiceRegister`, `DnsServiceBrowse`, and `DnsServiceResolve` from `dnsapi.dll` (Windows 10 1809 and later). They work in an unpackaged app on .NET 10 without extra packages. Apple uses Network.framework (`NWListener` and `NWBrowser` with Bonjour).

### Additions to existing messages

- **`GET /ping`** adds `"id"`, `"fp"`, and `"tlsPort"`, and reports `"protocol": 2`. A protocol 1 client ignores the extra fields.
- **Pairing QR:** still payload version `v=1`, with three optional keys that older apps ignore: `id`, `fp`, and `lan`, a comma-separated list of the desktop's current LAN `host:port` pairs for HTTPS (IPv6 in brackets). A scanner that gets `fp` pins it right away.
- **`POST /pair`:** the request may add `"id"`, `"fp"`, `"tlsPort"`, and `"lan"` (an array of `host:port` strings) for the caller, and the response adds the desktop's `"id"`, `"fp"`, `"tlsPort"`, `"lan"`, and `"host"` (its Tailscale name, if it has one). Each side stores the other's values. A protocol 2 iPhone also sends `"token"`, a device token it minted for this computer, as computers already do; see [Phones](#phones). When `/pair` is authenticated with a device token, the desktop updates the peer that token belongs to (matched by that, not by name), so a device can repeat `/pair` to add new fields without creating a duplicate. It can fill in a missing `id` or `fp` but never replace one (see [Pairing rules](#pairing-rules)).

### LAN pairing (`POST /pair/request`, `POST /pair/confirm`)

Pairing by picking a device that discovery found, without a QR code and without either side showing a token. It takes two requests, both over HTTPS on the TLS port and without a bearer token.

**Identity comes from TLS, not from JSON.** Every protocol 2 client presents its own [device certificate](#device-identity) as the TLS client certificate on every HTTPS request (not just pairing), and a receiver may require one on its HTTPS port. The receiver takes the requester's fingerprint from that certificate. A body `fp` that differs from it is `400`. Clients without a certificate (curl, Shortcuts) use plain HTTP over Tailscale.

1. The requester picks a discovered device and connects over HTTPS, presenting its certificate and accepting whatever certificate the receiver presents, because there's no pin yet. It remembers the receiver's fingerprint as `fpS`. (Its own is `fpR`.)
2. It makes a random 32-byte nonce `nonceR` and sends a commitment to it:

   ```http
   POST /pair/request
   { "id": "<requester id>", "name": "iPhone", "platform": "ios", "commit": "<hex SHA-256 of nonceR's 32 bytes>" }
   ```

   `fp` may be included; it must equal the client certificate's. The receiver answers right away, without asking anyone:

   ```json
   { "ok": true, "session": "<opaque string>", "nonce": "<nonceS: 32 random bytes, hex>" }
   ```

   Or `409` with `"already paired …"` when the requester's `id` **or** certificate fingerprint already belongs to a paired peer (see [Rules](#pairing-rules)), `429` while another pairing is in progress, and `400` for a missing certificate or bad fields.
3. Only now, holding `nonceS`, does the requester reveal `nonceR`, on a connection with the same client certificate, along with what [`POST /pair`](#post-pair) carries for it (`token`, `host`, `port`, `tlsPort`, `lan`):

   ```http
   POST /pair/confirm
   { "session": "<session>", "nonce": "<nonceR, hex>", "token": "...", "tlsPort": 53319, "lan": ["192.168.1.20:53319"] }
   ```

   The receiver checks that the session is its open one (sessions expire after 30 seconds), that the client certificate is the one from step 2 (else `404`), and that SHA-256 of `nonceR` equals the commitment (else `400`).
4. Both screens show the same **six-digit code**: SHA-256 of the UTF-8 string `fpLow:fpHigh:nonceR:nonceS` (the two fingerprints sorted, then the requester's nonce, then the receiver's, all lowercase hex), first 4 bytes as a big-endian unsigned integer, modulo 1,000,000, zero-padded to six digits. The requester shows it as soon as it has `nonceS`; the receiver shows it after step 3. Because the requester commits to its nonce before it sees the receiver's, and the receiver's is fixed before the requester's is revealed, nobody in the middle can choose certificates or nonces that make two different codes match.

   **Test vector.** With

   ```text
   fp A   = e4a47d3c3bdb35669a7b8864ac1eb1007374b3fff99a4cfea5faad8a98f9c991
   fp B   = 41a2a6ceda3570ff77b22160da5b2f526aa5b6da82d5baa33b89fd5e220421c7
   nonceR = 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
   nonceS = 202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f
   ```

   the commitment to `nonceR` is `630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd`, the hashed string is `41a2…21c7:e4a4…c991:0001…1e1f:2021…3e3f` (B sorts first), and the code is **`876152`**, whichever side computes it.
5. The receiver asks: "Pair with `<name>`? Only if you started pairing on `<name>` and it shows `<code>`." It shows the prompt without taking keyboard focus and with no default button, so typing elsewhere can't accept it. `/pair/confirm` stays open until the person answers, for up to 60 seconds.
6. **Accept:** the receiver adds a **new** peer with the requester's `id` and its certificate fingerprint pinned, mints a device token, and answers `200` with the same body as [`POST /pair`](#post-pair), plus its `id`, `fp`, `tlsPort`, `lan`, and `host`. When the receiver is an iPhone, the response's `token` is one the phone minted for the requester. The requester pins `fpS` and stores the token. **Decline:** `403` with `"declined"`. **No answer:** `408` with `"timed out"`.

**Limits:** only over HTTPS on the TLS port, never on plain HTTP (`404` there). Bodies over 64 KB are refused. One pairing at a time: a second `/pair/request` while a session or prompt is open gets `429`. After three declines, timeouts, or wrong reveals from the same address within 10 minutes, the receiver answers `429` to that address for 10 minutes. A request is never accepted without a person confirming it.

### Pairing rules

These keep one paired device from taking over another's record. They apply to every way of pairing.

- **No takeover by LAN pairing.** `/pair/request` and `/pair/confirm` never update an existing peer. A requester whose `id` or certificate fingerprint already belongs to a peer gets `409`; to pair again, remove the device first. A name that's already taken gets a new entry with a suffix (`MacBook (2)`), never the existing one.
- **The requester matches only by identity.** When the requester saves the result, it updates an existing peer only if that peer has the discovered device's `id` or pinned fingerprint, never by the name in the response, and it changes nothing until pairing succeeds. The device token it offered is accepted only while the pairing is in progress.
- **A device token can't change who a peer is.** A `/pair` authenticated with a device token updates only that token's peer. It can fill in a missing `id` or fingerprint (a protocol 1 pairing upgrading), but never replace one, never take one that belongs to another peer, and never change the peer between phone and computer.
- **Merging.** Two records are the same device only when they share a device id or a pinned fingerprint and don't have two different pins. A shared host alone is never enough. A merge only adds a pin to a record that has none; it never moves one.
- **Inbox fallback.** A main-token `GET /inbox?for=<name>` adds a phone only when no peer has that name; it never changes an existing peer.
- **Plain HTTP is for Tailscale only.** A sender resolves a peer's host and uses plain HTTP only if the address is in `100.64.0.0/10`, in `fd7a:115c:a1e0::/48`, or loopback. Otherwise it refuses, rather than send a token or a file unencrypted.

### Sending

- **Peer record:** besides today's fields, a device stores each peer's `id`, its Tailscale host, its last known LAN addresses with the time they were seen, its pinned `fp`, its `tlsPort`, and the path last used (`lan` or `tailscale`).
- **Order:** if the peer has a pin and a LAN address seen within the last 2 minutes (or still advertised), the sender connects over HTTPS to each LAN address in turn with a connect timeout of about 1.5 seconds. If none answers, it falls back to Tailscale (plain HTTP on the HTTP port, as in protocol 1). It doesn't race the two paths, so a body is never sent twice.
- **Status:** the result names the path, for example "Sent to MacBook (Wi-Fi)" or "Sent to MacBook (Tailscale)", and the peer's last-used path is updated.
- **Addresses:** whenever discovery sees a paired peer's `id` with a new address and a matching `fp`, the stored LAN addresses are replaced.

### Phones

- **A token for the computer:** a protocol 2 iPhone mints a [device token](#tokens) for each computer it pairs with and sends it as `"token"` in `POST /pair` and `POST /pair/confirm`, or returns it in the `/pair/confirm` response when the phone is the one being asked. The computer stores it as the token it sends to that phone. A protocol 1 phone sends none, so computers keep only queuing for it.
- **Upgrading an existing pairing:** when a protocol 2 iPhone sees from `/ping` that a computer it's already paired with speaks protocol 2, and it hasn't given that computer a token yet, it calls `POST /pair` on that computer once, authenticated with the token it already has, carrying `token`, `id`, `fp`, `tlsPort`, and `lan`. The computer updates that phone's existing peer (matched by the bearer token's device), so nobody has to pair again.
- **Sending to an iPhone:** if the computer has a token for the phone, has its pin, and the phone is advertising right now (Droprr is open), the computer sends to it directly over HTTPS with `POST /send`. Otherwise it queues the item in the phone's [inbox](#inbox-phone-pull), as today.
- **Inbox polling:** the phone polls whichever path to the computer answers first: LAN HTTPS if the computer is discovered, otherwise Tailscale. The inbox endpoints and their scoping are unchanged.

### Platform notes

- **iPhone:** `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_droprr._tcp`) in Info.plist. Apple's apps handle their own Local Network prompts.
- **Windows firewall:** the HTTPS port needs an inbound rule for the **Private** profile only. Public networks are ignored: no rule there, and no advertising on interfaces whose network category is Public. Without an installer, the app checks for its rule when Local network is on (reading rules needs no elevation). If the rule is missing, Settings shows "Allow Droprr on your private network", which runs one elevated `netsh advfirewall firewall add rule` for the port (a single UAC prompt). It never elevates on its own at startup.
- **Mac:** the existing network server entitlement covers the HTTPS listener.

## Browser access

A computer serves its own web page, so any phone's browser can send to it and receive from it without the Droprr app. There's no hosted service: the page comes from the computer, over the same two listeners as everything else. The Windows and Mac apps serve the same files, from `web/` in this repository.

### Addresses

| Path | Address | Notes |
| --- | --- | --- |
| Wi-Fi | `https://<private LAN address>:53319/web` | The computer's own certificate, so the browser warns once that the connection isn't private (see [Security](#security)). |
| Tailscale | `http://<MagicDNS name or Tailscale address>:53318/web` | No warning: Tailscale already encrypts and authenticates the connection. |

Plain HTTP stays Tailscale and loopback only, as everywhere else. The HTTPS port asks for a client certificate but doesn't require one, so browsers continue without one.

**A receiver that can't make client certificates optional** (the Mac, whose Network.framework listener either requires them or never asks) serves the page on a third listener instead, at the HTTP port + 2 (**`53320`**). It uses the same certificate and the same allowed addresses as the HTTPS port, asks for no client certificate, and serves only the page, `/web/session`, `/web/signout`, and the endpoints the cookie works on (below); everything else is `404` there. Its Wi-Fi address is then `https://<private LAN address>:53320/web`. The QR code always carries the full address, so a browser never needs to know which port a receiver uses. Windows keeps serving the page on `53319`, which avoids a second firewall rule.

### Connecting a browser

1. On the computer, the person chooses **Open in a browser**. It shows a QR code of `<address>#<code>` and, to type by hand, the address and the code.
2. **Access code:** 8 characters from Crockford's base32 alphabet (`0`–`9` and `A`–`Z` without `I`, `L`, `O`, and `U`), shown as `XXXX-XXXX`. Typing is forgiving: case, dashes, and spaces are ignored, `O` reads as `0`, and `I` and `L` as `1`. A code works **once**, only while that window is open, for at most **10 minutes**. Choosing **New code** replaces it. **Five wrong codes** close it until the person chooses New code. It's never saved or logged, and the QR keeps it in the URL fragment, which browsers never send.
3. The page sends it:

   ```http
   POST /web/session
   X-Droprr-Web: 1
   Content-Type: application/json

   { "code": "ABCD2345", "name": "iPhone (Safari)" }
   ```

   Response `200` `{ "ok": true, "name": "<computer name>", "device": "<the name this browser was saved as>" }`, with:

   ```http
   Set-Cookie: droprr=<device token>; Max-Age=2592000; Path=/; SameSite=Strict; HttpOnly[; Secure]
   ```

   `Secure` is added on HTTPS. Errors: `403` with `"wrong code"`, or with `"no code is open: …"` when there's no open code (expired, used, or closed), and `400` for a malformed body (over 4 KB is `413`).
4. The computer adds a new peer with platform **`"web"`** under that name (made unique with a suffix), with the cookie's value as its `acceptToken`. Like a protocol 1 phone it's **queue-only**: everything sent to it waits in its [inbox](#inbox-phone-pull). The person can remove it like any other device, which revokes the cookie.

### What the cookie works on

A request without an `Authorization` header may authenticate with the `droprr` cookie, as that browser's device token, only on:

- `GET /ping`, which for a browser answers `{ name, version, platform, protocol, you }` (`you` is the browser's peer name) and renews the cookie for another 30 days, so it expires only after 30 days unused;
- `POST /send`;
- `GET /inbox`, `GET /inbox/<id>`, and `DELETE /inbox/<id>`, scoped to that browser's queue as for any device token.

Never on `/pair` or the LAN pairing endpoints. `GET /inbox/<id>?inline=1` serves a photo or video (JPEG, PNG, GIF, WebP, HEIC, HEIF, MP4, MOV, and M4V) without `attachment`, under `Content-Security-Policy: sandbox`, for the page's View button; other types download as usual.

`POST /web/signout` (with the cookie and `X-Droprr-Web: 1`) removes the browser's peer and anything waiting for it, and clears the cookie.

### Security

- **Cross-site requests.** The cookie is `SameSite=Strict` and `HttpOnly`. Anything other than a `GET` (including `/web/session`) also needs the header `X-Droprr-Web: 1`, which another site can only add after a CORS preflight that receivers never approve, and an `Origin`, when present, must be the request's own origin.
- **DNS rebinding.** `/web/session` and cookie requests are refused unless the `Host` is an IP address, `localhost`, the computer's own name, or its MagicDNS name (full or short).
- **The page** (`/web`, `/web/app.js`, `/web/app.css`, `/web/icon.png`) needs no token and holds no secrets. It's served with `Content-Security-Policy: default-src 'self'; …; frame-ancestors 'none'`, `X-Content-Type-Options: nosniff`, and `Referrer-Policy: no-referrer`, and shows everything from the network as text, never HTML.
- **Wi-Fi certificate warning.** A browser can't pin the computer's certificate the way the apps do, so the first visit trusts whichever certificate answers. Someone actively intercepting the Wi-Fi at that moment could read the code and pose as the computer. On a home network that's unlikely; on any network you don't trust, use the Tailscale address, which has no warning and no such gap.

## Implementation notes

- **Binding:** a listener may bind to all interfaces (`0.0.0.0` or `::`) instead of specific addresses, as long as it immediately drops any connection whose source address isn't loopback, in `100.64.0.0/10` (Tailscale IPv4), or in `fd7a:115c:a1e0::/48` (Tailscale IPv6). This helps on platforms where the Tailscale address is hard to find or changes often.
- **Peer platforms:** a desktop records each peer's `platform` from `POST /pair` or its last successful `/ping`, and its peer editor has an "iPhone" toggle that sets `"platform": "ios"`. When `GET /inbox?for=<name>` arrives with a name that isn't a known peer, the desktop adds it as an `"ios"` peer, so it can be picked as a send target. None of this changes the wire format.
- **Private endpoints:** an app may add loopback-only endpoints for its own parts, such as the Mac share extension handing items to the Mac app's outbox. They aren't part of this protocol, and other devices must not rely on them.
- **Windows hardening:** the Windows app stores every token encrypted for the signed-in user (DPAPI), marks received files with the Mark of the Web (`Zone.Identifier`, internet zone), opens only common media, document, and text types directly (anything else is shown in Explorer), and keeps clipboard writes out of clipboard history and cloud clipboard. None of this changes the wire format.
- **Link files:** platforms may save links in their native shortcut format. Windows saves `Link <date time>.url`, and macOS saves `Link <date time>.webloc`.
