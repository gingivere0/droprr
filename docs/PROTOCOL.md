# Droprr protocol

Version 1. Every Droprr receiver (Windows, macOS, and any future iOS app) must implement exactly this.

Devices talk over plain HTTP inside a Tailscale network. Tailscale's WireGuard tunnel already encrypts and authenticates the connection between devices, and a shared bearer token keeps other devices on the tailnet out.

## Transport

- **Addresses:** a receiver listens only on its Tailscale IPv4 address (in `100.64.0.0/10`) and on localhost. It never binds to LAN or public interfaces.
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
| `415` | `/send` body isn't `multipart/form-data` or `application/json`. |
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

A multipart body may also carry plain form fields named `text` or `url`. Each one is handled like the matching JSON form below, which helps clients such as iOS Shortcuts that find form bodies easier to build. Other form fields are ignored.

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

## What a receiver does

- **Files** are saved to a `Droprr` folder in the user's Downloads (configurable). File names lose any path parts and invalid characters, and an existing file is never overwritten: the receiver adds ` (1)`, ` (2)`, and so on instead.
- **Text** is saved as `Text <date time>.txt` and copied to the clipboard.
- **Links** are saved as an internet shortcut (`Link <date time>.url` on Windows) and copied to the clipboard.
- A notification appears for each item.
- There's no size limit, so receivers should stream files to disk rather than hold them in memory.
