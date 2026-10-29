// Droprr's introduction server (docs/PROTOCOL.md, "Browser access over the internet"). It passes WebRTC connection
// details between a computer and the browsers that scanned its code, and nothing else: no files, no text, and no
// storage. Everything that matters is encrypted end to end by WebRTC, and the browser checks the computer's key from
// the QR code, so this relay can't read or impersonate anything.
//
//   wss://<relay>/host/<key>   the computer, with its secret 32-byte key (base64url). Its room is SHA-256(key), so
//                              only the computer can be the host of its own room.
//   wss://<relay>/join/<room>  a browser, with the room from the QR code.
//
// Messages are JSON text. A browser sends { m } and the computer receives { t: "from", cid, m }; the computer sends
// { t: "to", cid, m } and that browser receives { t: "msg", m }. The relay adds { t: "join", cid } and
// { t: "leave", cid } for the computer, and { t: "offline" } for browsers when there's no computer.

const ID = /^[A-Za-z0-9_-]{43}$/;
const MAX_GUESTS = 16;
const MAX_MESSAGE = 16 * 1024;
const RATE_WINDOW_MS = 10_000;
const RATE_MAX = 300;

function base64url(bytes) {
  let text = "";
  for (const b of new Uint8Array(bytes)) text += String.fromCharCode(b);
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64url(text) {
  const plain = atob(text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4));
  return Uint8Array.from(plain, (c) => c.charCodeAt(0));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/") {
      return new Response("Droprr introduction server. It only passes connection details between devices.\n", {
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }
    const match = url.pathname.match(/^\/(host|join)\/([^/]+)$/);
    if (!match || !ID.test(match[2])) return new Response("not found", { status: 404 });
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected a WebSocket", { status: 426 });
    }
    const [, role, value] = match;
    const room = role === "host" ? base64url(await crypto.subtle.digest("SHA-256", fromBase64url(value))) : value;
    const stub = env.ROOMS.get(env.ROOMS.idFromName(room));
    const forwarded = new Request(request.url, { headers: request.headers });
    forwarded.headers.set("X-Droprr-Role", role);
    return stub.fetch(forwarded);
  },
};

// One room per computer. Uses WebSocket hibernation, so an idle computer costs nothing between messages.
export class Room {
  constructor(state) {
    this.state = state;
    // The computer's keepalive is answered without waking the room.
    state.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  host() {
    return this.state.getWebSockets("host")[0];
  }

  async fetch(request) {
    const role = request.headers.get("X-Droprr-Role");
    const [client, server] = Object.values(new WebSocketPair());
    if (role === "host") {
      // The newest connection wins, so a computer that restarted or changed networks takes over at once.
      for (const old of this.state.getWebSockets("host")) old.close(4000, "replaced");
      this.state.acceptWebSocket(server, ["host"]);
      server.serializeAttachment({ role: "host", start: Date.now(), count: 0 });
    } else {
      if (this.state.getWebSockets("guest").length >= MAX_GUESTS) return new Response("too many browsers", { status: 429 });
      const cid = base64url(crypto.getRandomValues(new Uint8Array(9)));
      this.state.acceptWebSocket(server, ["guest", `g:${cid}`]);
      server.serializeAttachment({ role: "guest", cid, start: Date.now(), count: 0 });
      const host = this.host();
      if (host) host.send(JSON.stringify({ t: "join", cid }));
      else server.send(JSON.stringify({ t: "offline" }));
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  // Counts messages per socket; a socket over the limit is closed.
  allowed(ws) {
    const info = ws.deserializeAttachment();
    const now = Date.now();
    if (now - info.start > RATE_WINDOW_MS) {
      info.start = now;
      info.count = 0;
    }
    info.count++;
    ws.serializeAttachment(info);
    if (info.count > RATE_MAX) {
      ws.close(4029, "too many messages");
      return null;
    }
    return info;
  }

  webSocketMessage(ws, message) {
    if (typeof message !== "string" || message.length > MAX_MESSAGE) {
      ws.close(1009, "message too large");
      return;
    }
    const info = this.allowed(ws);
    if (!info) return;
    let data;
    try {
      data = JSON.parse(message);
    } catch {
      return;
    }
    if (info.role === "guest") {
      const host = this.host();
      if (host) host.send(JSON.stringify({ t: "from", cid: info.cid, m: data.m }));
      else ws.send(JSON.stringify({ t: "offline" }));
    } else if (data.t === "to" && typeof data.cid === "string") {
      for (const guest of this.state.getWebSockets(`g:${data.cid}`)) guest.send(JSON.stringify({ t: "msg", m: data.m }));
    } else if (data.t === "drop" && typeof data.cid === "string") {
      for (const guest of this.state.getWebSockets(`g:${data.cid}`)) {
        guest.send(JSON.stringify({ t: "refused" }));
        guest.close(4003, "refused");
      }
    }
  }

  webSocketClose(ws, code) {
    const info = ws.deserializeAttachment();
    if (info?.role === "guest") {
      this.host()?.send(JSON.stringify({ t: "leave", cid: info.cid }));
    } else if (info?.role === "host" && code !== 4000 && !this.state.getWebSockets("host").some((other) => other !== ws)) {
      for (const guest of this.state.getWebSockets("guest")) guest.send(JSON.stringify({ t: "offline" }));
    }
    try { ws.close(); } catch { /* already closed */ }
  }

  webSocketError(ws) {
    this.webSocketClose(ws, 1011);
  }
}
