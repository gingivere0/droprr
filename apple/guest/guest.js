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
  const { RelaySocket, Link, ICE_SERVERS, sdpFingerprint } = self.DroprrRtc;
  const PART = 512 * 1024;
  const links = new Map(); // room -> { pc, relay, link, done }

  const post = (message) => window.webkit.messageHandlers.droprr.postMessage(message);

  function toBase64(bytes) {
    let text = "";
    const view = new Uint8Array(bytes);
    for (let i = 0; i < view.length; i += 0x8000) text += String.fromCharCode.apply(null, view.subarray(i, i + 0x8000));
    return btoa(text);
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
          // The browser's key from its code must be the one on this connection; otherwise it's someone else.
          if (!fp || sdpFingerprint(m.sdp) !== fp) return fail("wrong key");
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
            post({ t: "welcome", room, name: String(message.name || "").slice(0, 64), token: String(message.token || "") });
          } else if (message.t === "denied") {
            current.done = true;
            close(room);
            post({ t: "denied", room, e: String(message.e || "") });
          }
        },
        onItem: async (item) => {
          if (item.kind !== "file") {
            post({ t: "text", room, kind: item.kind, content: item.content });
            return;
          }
          // Files go to the app in parts, then it saves them.
          const key = `${room}:${++rid}`;
          post({ t: "fileStart", room, key, name: item.name, size: item.blob.size });
          for (let offset = 0; offset < item.blob.size; offset += PART) {
            post({ t: "filePart", key, data: toBase64(await item.blob.slice(offset, offset + PART).arrayBuffer()) });
          }
          post({ t: "fileEnd", key });
        },
        onProgress: (p) => post({ t: "progress", room, direction: p.direction, done: p.done, total: p.total }),
        onClose: () => {
          if (links.get(room) === current) links.delete(room);
          pc.close();
          post({ t: "closed", room });
        },
      });
      current.link.control({
        t: "hello", v: 1, id, name,
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

  window.droprrGuest = {
    connect,
    send,
    disconnect: close,
    connected: (room) => !!links.get(room)?.link?.open,
  };
  post({ t: "ready", secure: window.isSecureContext, webrtc: typeof RTCPeerConnection === "function" });
})();
