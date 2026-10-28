# Droprr protocol

Version 1. Every Droprr receiver (Windows, macOS, and any future iOS app) must implement exactly this.

Devices talk over plain HTTP inside a Tailscale network. Tailscale's WireGuard tunnel already encrypts and authenticates the connection between devices, and a shared bearer token keeps other devices on the tailnet out.

## Transport

- **Addresses:** a receiver accepts connections only from its Tailscale network and from localhost. The simplest way is to listen only on its Tailscale IPv4 address (in `100.64.0.0/10`) and on localhost. See [Implementation notes](#implementation-notes) for the alternative.
- **Port:** configurable. The default is **`53318`**.
- **Host names:** senders address peers by their Tailscale MagicDNS name, for example `http://my-pc:53318`.
- **Auth:** every request, including `/ping`, must send `Authorization: Bearer <token>`. A missing or wrong token gets `401`.
- **Encoding:** JSON bodies and responses are UTF-8 with `Content-Type: application/json`.

## Errors

Every error response, on any endpoint, has a 4xx or 5xx status and this body:

```json
{ "ok": false, "error": "human-readable message" }
```

| Status | Meaning |
| --- | --- |
| `400` | Bad body: empty content, unknown `type`, invalid URL, malformed JSON, or no items. |
| `401` | Missing or wrong token. |
| `404` | Unknown path. |
| `500` | The receiver failed, for example while writing to disk. |

## `GET /ping`

Checks that a device is reachable and the token is right.

```http
GET /ping HTTP/1.1
Authorization: Bearer <token>
```

Response `200`:

```json
{ "name": "My PC", "version": "0.1.0", "platform": "windows" }
```

- `name` (string): the device's display name from its settings.
- `version` (string): the app's version.
- `platform` (string): one of `"windows"`, `"macos"`, or `"ios"`.

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

- `url` is always a **url** item, and must be a valid absolute URL (otherwise `400`).
- `content`, `text`, and `file` are **text**, or **url** if the value is a single web URL.

This is what Shortcuts sends for a Form body whose field is Text rather than File.

## What a receiver does

- **Files** are saved to a `Droprr` folder in the user's Downloads (configurable). File names lose any path parts and invalid characters, and an existing file is never overwritten: the receiver adds ` (1)`, ` (2)`, and so on instead.
- **Text** is saved as `Text <date time>.txt` and copied to the clipboard.
- **Links** are saved as an internet shortcut and copied to the clipboard.
- A notification appears for each item.
- There's no size limit, so receivers should stream files to disk rather than hold them in memory.

## Inbox (phone pull)

A phone can't listen for incoming connections, so it pulls items from desktops instead.

- **Outbox:** each desktop keeps an outbox per peer. A send to a peer whose `/ping` reports `"platform": "ios"` is always queued in that peer's outbox and never pushed directly.
- **Polling:** the phone polls each desktop peer when its app opens, or when the "Get from PC" shortcut runs.
- **Expiry:** items expire 7 days after they're queued, whether or not they were fetched.

All inbox endpoints need the same `Authorization: Bearer <token>` header and use the [error shape](#errors) above.

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

1. It stores the token **per peer**. Each desktop has its own token, so the phone sends each desktop the token from that desktop's QR code, never one shared token.
2. It adds the peer, or updates an existing one matched by `host` or `name`, with the new name, host, `dns`, port, token, and platform. It should prefer `dns` for connecting when present, since the IP can change, and fall back to `host`.
3. It calls `GET /ping` with the new token to confirm the pairing, and tells the user whether it worked.

**Handling:** the code contains a secret. A desktop builds it only while the pairing window is open and never saves it to disk or writes it to a log. It warns the user that the code contains the token.

## Implementation notes

- **Binding:** a listener may bind to all interfaces (`0.0.0.0` or `::`) instead of specific addresses, as long as it immediately drops any connection whose source address isn't loopback, in `100.64.0.0/10` (Tailscale IPv4), or in `fd7a:115c:a1e0::/48` (Tailscale IPv6). This helps on platforms where the Tailscale address is hard to find or changes often.
- **Peer platforms:** a desktop stores each peer's `platform` from its last successful `/ping`, and its peer editor has an "iPhone" toggle that sets `"platform": "ios"`. When `GET /inbox?for=<name>` arrives with a name that isn't a known peer, the desktop adds it as an `"ios"` peer, so it can be picked as a send target. None of this changes the wire format.
- **Link files:** platforms may save links in their native shortcut format. Windows saves `Link <date time>.url`, and macOS saves `Link <date time>.webloc`.
