// The computer side of Browser access over the internet (docs/PROTOCOL.md). The Droprr app runs this page in its
// built-in browser engine, hidden. It stays connected to the relay as the host of this computer's room, answers
// browsers that scanned the code, and moves items between their data channels and the app through the app's
// /api bridge (same origin, handled by the app itself):
//
//   GET  /api/config                    { relay, key, name, secret }: secret is the current code's, or null
//   POST /api/ready  { fp }             this page's DTLS fingerprint, for the code
//   POST /api/hello  { id, name, secret?, token? }  ->  { ok, peer, token } or { ok: false, error }
//   POST /api/p/<peer>/send             an item from that browser (the body as in POST /send)
//   GET  /api/p/<peer>/inbox            items waiting for it; GET or DELETE /api/p/<peer>/inbox/<id>
//   POST /api/status { browsers }       the peers connected right now
//
// The app posts { t: "config" } when the code changes, and { t: "outbox" } when it queued something.
"use strict";

const { RelaySocket, Link, ICE_SERVERS } = self.DroprrRtc;
const POLL_MS = 2000;
const CERT_DB = "droprr-host";
const RENEW_BEFORE_MS = 30 * 24 * 3600 * 1000;

let config = null;
let relay = null;
let certificate = null;
let listening = false;
const guests = new Map(); // relay cid -> { pc, link, peer }

function log(text) {
  console.log(`[droprr host] ${text}`);
}

async function api(path, options = {}) {
  const response = await fetch(path, { cache: "no-store", ...options });
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
  return response;
}

const postJson = (path, body) =>
  api(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

// One DTLS certificate kept in this page's storage, so the fingerprint in the code stays the same across restarts.
// Browsers limit certificates to a year, so it's replaced a month before it expires (browsers then scan again).
function openDb() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(CERT_DB, 1);
    request.onupgradeneeded = () => request.result.createObjectStore("certs");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function loadCertificate() {
  const db = await openDb();
  const stored = await new Promise((resolve) => {
    const read = db.transaction("certs").objectStore("certs").get("dtls");
    read.onsuccess = () => resolve(read.result || null);
    read.onerror = () => resolve(null);
  });
  if (stored && stored.expires - Date.now() > RENEW_BEFORE_MS) return stored;
  const fresh = await RTCPeerConnection.generateCertificate({ name: "ECDSA", namedCurve: "P-256", expires: 365 * 24 * 3600 * 1000 });
  await new Promise((resolve) => {
    const write = db.transaction("certs", "readwrite").objectStore("certs").put(fresh, "dtls");
    write.onsuccess = write.onerror = () => resolve();
  });
  return fresh;
}

function fingerprintOf(cert) {
  const sha = cert.getFingerprints().find((f) => f.algorithm === "sha-256");
  const bytes = Uint8Array.from(sha.value.split(":"), (h) => parseInt(h, 16));
  return self.DroprrRtc.base64url(bytes);
}

async function loadConfig() {
  config = await (await api("/api/config")).json();
}

function reportStatus() {
  const browsers = [...guests.values()].filter((g) => g.peer).map((g) => g.peer);
  postJson("/api/status", { browsers }).catch(() => {});
}

function connectRelay() {
  relay?.close();
  relay = new RelaySocket(`${config.relay}/host/${config.key}`, {
    keepalive: true,
    onOpen: () => log("relay connected"),
    onClose: (code) => log(`relay closed (${code})`),
    onMessage: (data) => {
      if (data.t === "join") return;
      if (data.t === "leave") return dropGuest(data.cid);
      if (data.t === "from" && typeof data.cid === "string" && data.m) handleSignal(data.cid, data.m);
    },
  });
}

function dropGuest(cid) {
  // The relay only introduces: a browser leaves it as soon as its data channel opens, which can be before this
  // side sees the channel, so leaving never closes the connection. A browser that never says hello is dropped by
  // the hello timeout instead.
  const guest = guests.get(cid);
  if (guest && !guest.pc.remoteDescription) {
    guest.pc.close();
    guests.delete(cid);
  }
}

async function handleSignal(cid, m) {
  let guest = guests.get(cid);
  if (m.t === "offer" && typeof m.sdp === "string" && m.sdp.length < 12000) {
    if (guest) guest.pc.close();
    const pc = new RTCPeerConnection({ iceServers: ICE_SERVERS, certificates: [certificate] });
    // Candidates that arrive while the offer is still being applied wait here; dropping them made first tries fail.
    guest = { pc, link: null, peer: null, pending: [] };
    guests.set(cid, guest);
    pc.onicecandidate = (event) => relay.send({ t: "to", cid, m: { t: "ice", c: event.candidate ? event.candidate.toJSON() : null } });
    pc.onconnectionstatechange = () => {
      if (["failed", "closed"].includes(pc.connectionState)) {
        if (guests.get(cid) === guest) guests.delete(cid);
        reportStatus();
      }
    };
    pc.ondatachannel = (event) => {
      if (event.channel.label === "droprr" && !guest.link) accept(cid, guest, event.channel);
    };
    // A browser that doesn't say hello soon is dropped.
    setTimeout(() => {
      if (guest.peer) return;
      pc.close();
      if (guests.get(cid) === guest) guests.delete(cid);
    }, 30000);
    await pc.setRemoteDescription({ type: "offer", sdp: m.sdp });
    for (const c of guest.pending.splice(0)) await addCandidate(pc, c);
    await pc.setLocalDescription(await pc.createAnswer());
    relay.send({ t: "to", cid, m: { t: "answer", sdp: pc.localDescription.sdp } });
  } else if (m.t === "ice" && guest) {
    if (guest.pc.remoteDescription) await addCandidate(guest.pc, m.c);
    else guest.pending.push(m.c);
  }
}

async function addCandidate(pc, candidate) {
  try { await pc.addIceCandidate(candidate || null); } catch { /* unusable candidate */ }
}

function accept(cid, guest, channel) {
  guest.link = new Link(channel, {
    onControl: async (message) => {
      // One hello per connection.
      if (message.t !== "hello" || guest.hello) return;
      guest.hello = true;
      let answer;
      try {
        answer = await (await postJson("/api/hello", {
          id: String(message.id || ""), name: String(message.name || "Browser").slice(0, 64),
          secret: typeof message.secret === "string" ? message.secret : null,
          token: typeof message.token === "string" ? message.token : null,
        })).json();
      } catch {
        answer = { ok: false, error: "the computer couldn't check this browser" };
      }
      if (!answer.ok) {
        guest.link.control({ t: "denied", e: answer.error || "not allowed" });
        setTimeout(() => guest.pc.close(), 500);
        return;
      }
      guest.peer = answer.peer;
      guest.link.control({ t: "welcome", name: config.name, token: answer.token });
      log(`browser connected: ${answer.peer}`);
      reportStatus();
      pump(guest);
    },
    onItem: (item) => save(guest, item),
    onClose: () => {
      guest.pc.close();
      if (guests.get(cid) === guest) guests.delete(cid);
      reportStatus();
    },
    // Nothing is taken from a browser until its hello was accepted.
    accepting: () => !!guest.peer,
  });
}

// An item from a browser goes to the app as if it had arrived at POST /send.
async function save(guest, item) {
  if (!guest.peer) throw new Error("not connected");
  const path = `/api/p/${encodeURIComponent(guest.peer)}/send`;
  if (item.kind === "file") {
    await api(path, {
      method: "POST",
      headers: { "Content-Type": item.blob.type || "application/octet-stream", "X-Droprr-Filename": encodeURIComponent(item.name) },
      body: item.blob,
    });
  } else {
    await postJson(path, { type: item.kind, content: item.content });
  }
}

// Sends whatever the app queued for this browser, oldest first, and removes each item once the browser saved it.
async function pump(guest) {
  const base = `/api/p/${encodeURIComponent(guest.peer)}/inbox`;
  while (guest.link?.open) {
    try {
      const { items } = await (await api(base)).json();
      for (const item of items || []) {
        if (!guest.link?.open) break;
        if (item.type === "file") {
          const blob = await (await api(`${base}/${encodeURIComponent(item.id)}`)).blob();
          await guest.link.sendFile(blob, item.name);
        } else {
          await guest.link.sendText(item.content, item.type);
        }
        await api(`${base}/${encodeURIComponent(item.id)}`, { method: "DELETE" });
      }
    } catch (error) {
      log(`sending to ${guest.peer} paused: ${error.message}`);
    }
    await new Promise((resolve) => {
      wakeups.add(resolve);
      setTimeout(resolve, POLL_MS);
    });
  }
}

// Resolved when the app says something was queued, so it goes out at once.
const wakeups = new Set();

function wake() {
  for (const resolve of wakeups) resolve();
  wakeups.clear();
}

async function start() {
  certificate = await loadCertificate();
  await loadConfig();
  await postJson("/api/ready", { fp: fingerprintOf(certificate) });
  connectRelay();
  if (listening) return;
  listening = true;
  self.chrome?.webview?.addEventListener("message", async (event) => {
    if (event.data?.t === "outbox") return wake();
    if (event.data?.t !== "config") return;
    const relayBefore = `${config.relay}/${config.key}`;
    await loadConfig();
    if (`${config.relay}/${config.key}` !== relayBefore) connectRelay();
  });
}

// Retried until it works (the app also reloads this page if it never reports ready).
async function startWithRetry(delay = 2000) {
  try {
    await start();
  } catch (error) {
    log(`couldn't start: ${error.message}; retrying`);
    setTimeout(() => startWithRetry(Math.min(delay * 2, 30000)), delay);
  }
}

startWithRetry();
