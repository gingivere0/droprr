// Droprr over WebRTC (docs/PROTOCOL.md, "Browser access over the internet"), shared by the website (the browser
// side) and the page the computer apps run in their built-in browser engine (the computer side). It covers the
// relay connection, the peer connection, and items sent over the "droprr" data channel.
"use strict";

(function (global) {
  const CHUNK = 16 * 1024;
  const HIGH_WATER = 1024 * 1024;
  const ICE_SERVERS = [{ urls: "stun:stun.cloudflare.com:3478" }];

  function base64url(bytes) {
    let text = "";
    for (const b of new Uint8Array(bytes)) text += String.fromCharCode(b);
    return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  function fromBase64url(text) {
    const plain = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4));
    return Uint8Array.from(plain, (c) => c.charCodeAt(0));
  }

  function randomId(bytes = 16) {
    return base64url(crypto.getRandomValues(new Uint8Array(bytes)));
  }

  // The SHA-256 DTLS fingerprint in an SDP ("a=fingerprint:sha-256 AB:CD:…") as base64url, or null.
  function sdpFingerprint(sdp) {
    const match = /a=fingerprint:sha-256 ([0-9A-Fa-f:]+)/.exec(sdp || "");
    if (!match) return null;
    const hex = match[1].replace(/:/g, "");
    if (hex.length !== 64) return null;
    return base64url(Uint8Array.from(hex.match(/../g), (h) => parseInt(h, 16)));
  }

  // Same length and same characters, without stopping at the first difference.
  function sameSecret(a, b) {
    if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length || a.length === 0) return false;
    let diff = 0;
    for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return diff === 0;
  }

  // A WebSocket to the relay that reconnects with backoff. onMessage gets parsed JSON.
  class RelaySocket {
    constructor(url, { onMessage, onOpen, onClose, keepalive = false } = {}) {
      this.url = url;
      this.onMessage = onMessage;
      this.onOpen = onOpen;
      this.onClose = onClose;
      this.keepalive = keepalive;
      this.closed = false;
      this.delay = 1000;
      this.connect();
    }

    connect() {
      if (this.closed) return;
      const ws = new WebSocket(this.url);
      this.ws = ws;
      ws.onopen = () => {
        this.delay = 1000;
        if (this.keepalive) this.ping = setInterval(() => ws.readyState === 1 && ws.send("ping"), 30000);
        this.onOpen?.();
      };
      ws.onmessage = (event) => {
        if (event.data === "pong") return;
        let data;
        try { data = JSON.parse(event.data); } catch { return; }
        this.onMessage?.(data);
      };
      ws.onclose = (event) => {
        clearInterval(this.ping);
        this.onClose?.(event.code);
        // Refused, or replaced by a newer connection from the same computer: don't fight it.
        if (!this.closed && event.code !== 4003 && event.code !== 4000) {
          setTimeout(() => this.connect(), this.delay);
          this.delay = Math.min(this.delay * 2, 30000);
        }
      };
    }

    send(data) {
      if (this.ws?.readyState === 1) this.ws.send(JSON.stringify(data));
    }

    close() {
      this.closed = true;
      this.ws?.close();
    }
  }

  // Items over an open "droprr" data channel, in both directions, one at a time each way.
  //   text:  { t: "text", id, kind: "text" | "url", content }
  //   file:  { t: "file", id, name, size, type }, then binary chunks of at most 16 KB totaling size, then { t: "done", id }
  //   reply: { t: "saved", id } or { t: "failed", id, e }
  // Anything else (hello, welcome, …) goes to onControl. Until accepting() is true (the computer side: until the
  // browser's hello was accepted), items and file chunks are ignored, so nothing piles up in memory unasked.
  class Link {
    constructor(channel, { onControl, onItem, onProgress, onClose, accepting = () => true } = {}) {
      this.channel = channel;
      this.onControl = onControl;
      this.onItem = onItem;
      this.onProgress = onProgress;
      this.onClose = onClose;
      this.accepting = accepting;
      this.incoming = null;
      this.waiting = new Map();
      this.queue = Promise.resolve();
      channel.binaryType = "arraybuffer";
      channel.bufferedAmountLowThreshold = HIGH_WATER / 4;
      channel.onmessage = (event) => this.receive(event.data);
      channel.onclose = () => {
        for (const { reject } of this.waiting.values()) reject(new Error("disconnected"));
        this.waiting.clear();
        this.onClose?.();
      };
    }

    get open() {
      return this.channel.readyState === "open";
    }

    control(message) {
      if (this.open) this.channel.send(JSON.stringify(message));
    }

    async receive(data) {
      if (typeof data !== "string") {
        const item = this.incoming;
        if (!item || !this.accepting()) return;
        // More than the file said it was: refuse it rather than keep collecting.
        if (item.received + data.byteLength > item.size) {
          this.incoming = null;
          this.control({ t: "failed", id: item.id, e: "too large" });
          return;
        }
        item.parts.push(data);
        item.received += data.byteLength;
        this.onProgress?.({ direction: "in", id: item.id, name: item.name, done: item.received, total: item.size });
        return;
      }
      let message;
      try { message = JSON.parse(data); } catch { return; }
      if (!message || typeof message !== "object") return;
      if (["text", "file", "done"].includes(message.t) && !this.accepting()) return;
      switch (message.t) {
        case "text":
          this.deliver({ id: message.id, kind: message.kind === "url" ? "url" : "text", content: String(message.content ?? "") });
          break;
        case "file":
          this.incoming = {
            id: message.id, name: String(message.name || "File"), size: Number(message.size) || 0,
            type: String(message.type || "application/octet-stream"), parts: [], received: 0,
          };
          break;
        case "done": {
          const item = this.incoming;
          this.incoming = null;
          if (!item || item.id !== message.id) return;
          if (item.received !== item.size) {
            this.control({ t: "failed", id: item.id, e: "incomplete" });
            return;
          }
          this.deliver({ id: item.id, kind: "file", name: item.name, blob: new Blob(item.parts, { type: item.type }) });
          break;
        }
        case "saved":
        case "failed": {
          const waiter = this.waiting.get(message.id);
          this.waiting.delete(message.id);
          if (message.t === "saved") waiter?.resolve();
          else waiter?.reject(new Error(message.e || "the other side couldn't save it"));
          break;
        }
        default:
          this.onControl?.(message);
      }
    }

    // The receiver's handler saves the item; its result decides the reply.
    async deliver(item) {
      try {
        await this.onItem?.(item);
        this.control({ t: "saved", id: item.id });
      } catch (error) {
        this.control({ t: "failed", id: item.id, e: String(error?.message || error).slice(0, 200) });
      }
    }

    reply(id) {
      return new Promise((resolve, reject) => this.waiting.set(id, { resolve, reject }));
    }

    async drain() {
      while (this.channel.bufferedAmount > HIGH_WATER) {
        if (!this.open) throw new Error("disconnected");
        await new Promise((resolve) => {
          this.channel.onbufferedamountlow = () => { this.channel.onbufferedamountlow = null; resolve(); };
          setTimeout(resolve, 250);
        });
      }
    }

    // Queued so items go one after another. Resolves once the other side has saved it.
    sendText(content, kind) {
      return this.enqueue(async () => {
        const id = randomId(9);
        const saved = this.reply(id);
        this.control({ t: "text", id, kind: kind === "url" ? "url" : "text", content });
        await saved;
      });
    }

    sendFile(blob, name) {
      return this.enqueue(async () => {
        const id = randomId(9);
        const saved = this.reply(id);
        this.control({ t: "file", id, name: name || blob.name || "File", size: blob.size, type: blob.type || "application/octet-stream" });
        for (let offset = 0; offset < blob.size; offset += CHUNK) {
          await this.drain();
          if (!this.open) throw new Error("disconnected");
          this.channel.send(await blob.slice(offset, offset + CHUNK).arrayBuffer());
          this.onProgress?.({ direction: "out", id, name, done: Math.min(offset + CHUNK, blob.size), total: blob.size });
        }
        this.control({ t: "done", id });
        await saved;
      });
    }

    enqueue(task) {
      const run = this.queue.then(task, task);
      this.queue = run.catch(() => {});
      return run;
    }
  }

  global.DroprrRtc = { ICE_SERVERS, RelaySocket, Link, base64url, fromBase64url, randomId, sdpFingerprint, sameSecret };
})(typeof self !== "undefined" ? self : this);
