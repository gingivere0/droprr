// Browsers as hosts (docs/PROTOCOL.md): the iPhone app's side. The app runs this page hidden and uses it to join a
// browser's room as a WebRTC guest, the way the website's guest.js joins a computer's: relay /join/<room>, an
// offer, the browser's key checked against the code, then hello with the code's secret or the token it gave this
// phone. Items move over the shared Link framing in both directions.
//
// The app calls window.droprrGuest.connect / send / disconnect, and hears back through the "droprr" message
// handler: welcome, denied, failed, closed, text, file parts, sent and progress. Files to send are read from
// out/<id> on this page's own origin, which the app serves.
"use strict";

(function () {
  const { RelaySocket, Link, ICE_SERVERS, sdpFingerprint, sameSecret, base64url, randomId } = self.DroprrRtc;
  const PART = 512 * 1024;
  const links = new Map(); // room -> { pc, relay, link, done }

  const post = (message) => window.webkit.messageHandlers.droprr.postMessage(message);

  function toBase64(bytes) {
    let text = "";
    const view = new Uint8Array(bytes);
    for (let i = 0; i < view.length; i += 0x8000) text += String.fromCharCode.apply(null, view.subarray(i, i + 0x8000));
    return btoa(text);
  }

  // Files go to the app in parts, then it saves them.
  async function deliver(room, item, nextKey) {
    if (item.kind !== "file") {
      post({ t: "text", room, kind: item.kind, content: item.content });
      return;
    }
    const key = nextKey();
    post({ t: "fileStart", room, key, name: item.name, size: item.blob.size });
    for (let offset = 0; offset < item.blob.size; offset += PART) {
      post({ t: "filePart", key, data: toBase64(await item.blob.slice(offset, offset + PART).arrayBuffer()) });
    }
    post({ t: "fileEnd", key });
  }

  function close(room) {
    const current = links.get(room);
    if (!current) return;
    links.delete(room);
    current.relay?.close();
    current.pc?.close();
  }

  // relay, room, fp (base64url), id (this phone's 16-byte base64url id), name, and secret (from a code) or token.
  function connect(options) {
    const { relay, room, fp, id, name, secret, token } = options;
    close(room);
    const current = { done: false };
    links.set(room, current);
    const fail = (reason) => {
      if (links.get(room) !== current || current.done) return;
      current.done = true;
      close(room);
      post({ t: "failed", room, e: reason });
    };
    const timeout = setTimeout(() => fail("unreachable"), 25000);

    const pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
    current.pc = pc;
    const channel = pc.createDataChannel("droprr", { ordered: true });
    const pending = [];
    const addCandidate = async (candidate) => {
      try { await pc.addIceCandidate(candidate || null); } catch { /* a candidate this phone can't use */ }
    };
    pc.onicecandidate = (event) => current.relay?.send({ m: { t: "ice", c: event.candidate ? event.candidate.toJSON() : null } });
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === "failed") fail("no direct connection");
    };

    current.relay = new RelaySocket(`${relay}/join/${room}`, {
      onOpen: async () => {
        if (pc.localDescription) return;
        await pc.setLocalDescription(await pc.createOffer());
        current.relay.send({ m: { t: "offer", sdp: pc.localDescription.sdp } });
      },
      onMessage: async (data) => {
        if (data.t === "offline") return fail("offline");
        if (data.t === "refused") return fail("refused");
        if (data.t !== "msg" || !data.m) return;
        const m = data.m;
        if (m.t === "answer" && typeof m.sdp === "string") {
          // The browser's key from its code must be the one on this connection; otherwise it's someone else. Codes
          // carry the key's first 22 characters (docs/PROTOCOL.md, "The code").
          if (!fp || fp.length < 22 || !(sdpFingerprint(m.sdp) || "").startsWith(fp)) return fail("wrong key");
          await pc.setRemoteDescription({ type: "answer", sdp: m.sdp });
          for (const c of pending.splice(0)) await addCandidate(c);
        } else if (m.t === "ice") {
          if (pc.remoteDescription) await addCandidate(m.c);
          else pending.push(m.c);
        }
      },
      onClose: (code) => {
        if (code === 4003) fail("refused");
      },
    });

    channel.onopen = () => {
      clearTimeout(timeout);
      current.relay.close();
      let rid = 0;
      current.link = new Link(channel, {
        onControl: (message) => {
          if (message.t === "welcome") {
            current.done = true;
            post({ t: "welcome", room, name: String(message.name || "").slice(0, 64), token: String(message.token || ""), kind: message.kind === "ios" ? "ios" : "web" });
          } else if (message.t === "bye") {
            // The browser disconnected this phone and forgot its token: don't reconnect.
            current.done = true;
            close(room);
            post({ t: "bye", room });
          } else if (message.t === "denied") {
            current.done = true;
            close(room);
            post({ t: "denied", room, e: String(message.e || "") });
          }
        },
        onItem: (item) => deliver(room, item, () => `${room}:${++rid}`),
        onProgress: (p) => post({ t: "progress", room, direction: p.direction, done: p.done, total: p.total }),
        onClose: () => {
          if (links.get(room) === current) links.delete(room);
          pc.close();
          post({ t: "closed", room });
        },
      });
      current.link.control({
        t: "hello", v: 1, id, name, kind: "ios",
        secret: secret || undefined, token: secret ? undefined : token || undefined,
      });
    };
  }

  // item: { req, kind: "text" | "url", content } or { req, kind: "file", out, name, type }.
  async function send(room, item) {
    const current = links.get(room);
    try {
      if (!current?.link?.open) throw new Error("not connected");
      if (item.kind === "file") {
        const response = await fetch(`out/${encodeURIComponent(item.out)}`);
        if (!response.ok) throw new Error("couldn't read the file");
        const blob = await response.blob();
        await current.link.sendFile(new Blob([blob], { type: item.type || "application/octet-stream" }), item.name);
      } else {
        await current.link.sendText(item.content, item.kind);
      }
      post({ t: "sent", req: item.req });
    } catch (error) {
      post({ t: "sent", req: item.req, e: String(error?.message || error).slice(0, 200) });
    }
  }

  // --- Hosting: this phone's own room (docs/PROTOCOL.md, "Phones as hosts"), so another iPhone or any browser can
  // connect to it, as a browser host does. Connected guests are in links too, under their id, so send() reaches them.

  let hosting = null;

  function certificate() {
    return new Promise((resolve) => {
      const request = indexedDB.open("droprr-phone-host", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("certs");
      request.onerror = () => resolve(null);
      request.onsuccess = () => {
        const read = request.result.transaction("certs").objectStore("certs").get("dtls");
        read.onerror = () => resolve(null);
        read.onsuccess = () => resolve(read.result || null);
      };
    }).then(async (stored) => {
      if (stored && stored.expires - Date.now() > 30 * 24 * 3600 * 1000) return stored;
      const fresh = await RTCPeerConnection.generateCertificate({ name: "ECDSA", namedCurve: "P-256", expires: 365 * 24 * 3600 * 1000 });
      await new Promise((resolve) => {
        const request = indexedDB.open("droprr-phone-host", 1);
        request.onerror = () => resolve();
        request.onsuccess = () => {
          const write = request.result.transaction("certs", "readwrite").objectStore("certs").put(fresh, "dtls");
          write.onsuccess = write.onerror = () => resolve();
        };
      });
      return fresh;
    });
  }

  // relay, key (the host key), room, name, and known: { id: token } for devices that may reconnect.
  async function host({ relay, key, room, name, known }) {
    if (hosting) {
      hosting.known = known;
      hosting.name = name;
    } else {
      const cert = await certificate();
      const sha = cert.getFingerprints().find((f) => f.algorithm === "sha-256");
      const h = {
        cert, name, known, room, secret: null, guests: new Map(),
        fp: base64url(Uint8Array.from(sha.value.split(":"), (x) => parseInt(x, 16))),
      };
      h.relay = new RelaySocket(`${relay}/host/${key}`, {
        keepalive: true,
        onMessage: (data) => {
          if (data.t === "from" && typeof data.cid === "string" && data.m) signal(h, data.cid, data.m);
        },
      });
      hosting = h;
    }
    post({ t: "hosting", fp: hosting.fp });
  }

  async function signal(h, cid, m) {
    let guest = h.guests.get(cid);
    if (m.t === "offer" && typeof m.sdp === "string" && m.sdp.length < 12000) {
      guest?.pc.close();
      const pc = new RTCPeerConnection({ iceServers: ICE_SERVERS, certificates: [h.cert] });
      guest = { pc, pending: [], accepted: false };
      h.guests.set(cid, guest);
      pc.onicecandidate = (event) => h.relay.send({ t: "to", cid, m: { t: "ice", c: event.candidate ? event.candidate.toJSON() : null } });
      pc.ondatachannel = (event) => {
        if (event.channel.label === "droprr" && !guest.link) accept(h, cid, guest, event.channel);
      };
      setTimeout(() => { if (!guest.accepted) pc.close(); }, 30000);
      await pc.setRemoteDescription({ type: "offer", sdp: m.sdp });
      for (const c of guest.pending.splice(0)) await pc.addIceCandidate(c || null).catch(() => {});
      await pc.setLocalDescription(await pc.createAnswer());
      h.relay.send({ t: "to", cid, m: { t: "answer", sdp: pc.localDescription.sdp } });
    } else if (m.t === "ice" && guest) {
      if (guest.pc.remoteDescription) await guest.pc.addIceCandidate(m.c || null).catch(() => {});
      else guest.pending.push(m.c);
    }
  }

  // A device that scanned this phone's code (its secret) or reconnects (the token it was given).
  function accept(h, cid, guest, channel) {
    let rid = 0;
    let id = null;
    guest.link = new Link(channel, {
      accepting: () => guest.accepted,
      onControl: (message) => {
        if (message.t !== "hello" || guest.hello) return;
        guest.hello = true;
        const claimed = String(message.id || "");
        const known = h.known[claimed];
        const byToken = !!known && sameSecret(message.token, known);
        if (!/^[A-Za-z0-9_-]{22}$/.test(claimed) || !(byToken || (h.secret && sameSecret(message.secret, h.secret)))) {
          guest.link.control({ t: "denied", e: "scan this iPhone's code again" });
          setTimeout(() => guest.pc.close(), 500);
          return;
        }
        id = claimed;
        const token = byToken ? known : randomId(32);
        h.known[id] = token;
        guest.accepted = true;
        links.get(id)?.pc?.close();
        links.set(id, { done: true, pc: guest.pc, link: guest.link });
        guest.link.control({ t: "welcome", name: h.name, token, kind: "ios" });
        post({ t: "guest", room: id, name: String(message.name || "").slice(0, 64), token, kind: message.kind === "ios" ? "ios" : "web", isNew: !byToken });
      },
      onItem: (item) => deliver(id, item, () => `${id}:${++rid}`),
      onProgress: (p) => post({ t: "progress", room: id, direction: p.direction, done: p.done, total: p.total }),
      onClose: () => {
        h.guests.delete(cid);
        guest.pc.close();
        if (!id || links.get(id)?.link !== guest.link) return;
        links.delete(id);
        post({ t: "closed", room: id });
      },
    });
  }

  // Tells a connected guest it's been removed, and stops accepting its token.
  function forget(id) {
    if (hosting) delete hosting.known[id];
    const current = links.get(id);
    if (!current) return;
    links.delete(id);
    current.link?.control({ t: "bye" });
    setTimeout(() => current.pc?.close(), 300);
  }

  window.droprrGuest = {
    connect,
    send,
    disconnect: close,
    connected: (room) => !!links.get(room)?.link?.open,
    host,
    openCode: (secret) => { if (hosting) hosting.secret = secret; },
    closeCode: () => { if (hosting) hosting.secret = null; },
    forget,
  };
  post({ t: "ready", secure: window.isSecureContext, webrtc: typeof RTCPeerConnection === "function" });
})();
