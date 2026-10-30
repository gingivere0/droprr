// The Droprr website's browser side (docs/PROTOCOL.md, "Browser access over the internet"). It reads a computer's
// code (from the link the camera opened, or by scanning it here), meets the computer through the relay, and then
// talks to it directly over a WebRTC data channel. The computer's key from the code is checked against the
// connection, so the relay can't pose as the computer. Everything from the network is shown as text, never HTML.
"use strict";

const $ = (id) => document.getElementById(id);
const { RelaySocket, Link, randomId, sdpFingerprint, ICE_SERVERS } = self.DroprrRtc;

// A local relay for development, only when the page itself is served from this machine.
const RELAY = (["localhost", "127.0.0.1"].includes(location.hostname) && new URLSearchParams(location.search).get("relay"))
  || self.DROPRR_RELAY;

const STORE = "droprr.computers";
const ID_KEY = "droprr.browserId";
const ID = /^[A-Za-z0-9_-]{43}$/;
const SECRET = /^[A-Za-z0-9_-]{22}$/;

let link = null;
let session = null;
let chosenFiles = [];
const received = new Map();

function storage(key, value) {
  try {
    if (value === undefined) return localStorage.getItem(key);
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch { /* private mode: nothing is remembered */ }
  return null;
}

function browserId() {
  let id = storage(ID_KEY);
  if (!id || !/^[A-Za-z0-9_-]{22}$/.test(id)) {
    id = randomId(16);
    storage(ID_KEY, id);
  }
  return id;
}

// Computers this browser connected to: room -> { room, fp, token, name }.
function computers() {
  try {
    const list = JSON.parse(storage(STORE) || "{}");
    return list && typeof list === "object" ? list : {};
  } catch {
    return {};
  }
}

function remember(room, values) {
  const list = computers();
  if (values === null) delete list[room];
  else list[room] = { ...(list[room] || {}), ...values, room, seen: Date.now() };
  storage(STORE, JSON.stringify(list));
}

function setStatus(element, text, kind) {
  element.textContent = text;
  element.className = "status" + (kind ? " " + kind : "");
}

function guessBrowserName() {
  const ua = navigator.userAgent;
  const device = /iPhone/.test(ua) ? "iPhone"
    : /iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1) ? "iPad"
    : /Android/.test(ua) ? "Android"
    : /Macintosh/.test(ua) ? "Mac"
    : /Windows/.test(ua) ? "Windows"
    : "Browser";
  const browser = /CriOS|Chrome\//.test(ua) && !/Edg/.test(ua) ? "Chrome"
    : /FxiOS|Firefox\//.test(ua) ? "Firefox"
    : /EdgiOS|Edg\//.test(ua) ? "Edge"
    : /Safari\//.test(ua) ? "Safari"
    : "";
  return browser ? `${device} (${browser})` : device;
}

function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++; }
  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${units[unit]}`;
}

function isWebUrl(text) {
  if (/\s/.test(text.trim())) return false;
  try {
    const url = new URL(text.trim());
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

// "<room>.<secret>.<fp>" from a code or link, or null.
function parseCode(text) {
  let fragment = text.trim();
  try {
    const url = new URL(fragment);
    if (url.origin !== location.origin) return null;
    fragment = url.hash.slice(1);
  } catch { /* a bare fragment */ }
  const [room, secret, fp, app] = fragment.replace(/^#/, "").split(".");
  if (!ID.test(room || "") || !SECRET.test(secret || "") || !ID.test(fp || "")) return null;
  // The one code may also carry what the Droprr app needs to pair (base64url JSON, never a token).
  return { room, secret, fp, app: /^[A-Za-z0-9_-]{1,2000}$/.test(app || "") ? app : null };
}

// --- Connecting -----------------------------------------------------------------------------------------------

function connect(target) {
  disconnect(false);
  const saved = computers()[target.room] || {};
  // A new code's key wins over a remembered one.
  const fp = target.fp || saved.fp;
  const name = target.name || saved.name || "your computer";
  if (!RELAY || /example\.workers\.dev/.test(RELAY)) {
    setStatus($("start-status"), "This copy of the page isn't set up with an introduction server yet.", "error");
    return;
  }
  setStatus($("start-status"), `Connecting to ${name}…`);
  const current = { room: target.room, fp, name, pc: null, relay: null, done: false };
  session = current;

  const fail = (text) => {
    if (session !== current || current.done) return;
    current.done = true;
    current.relay?.close();
    current.pc?.close();
    session = null;
    showStart();
    setStatus($("start-status"), text, "error");
  };
  const timeout = setTimeout(() => fail(`Couldn't reach ${name}. Make sure it's on and on the same Wi-Fi, then try again.`), 25000);

  const pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
  current.pc = pc;
  const channel = pc.createDataChannel("droprr", { ordered: true });
  pc.onicecandidate = (event) => current.relay?.send({ m: { t: "ice", c: event.candidate ? event.candidate.toJSON() : null } });
  const pending = [];
  const addCandidate = async (candidate) => {
    try { await pc.addIceCandidate(candidate || null); } catch { /* a candidate this browser can't use */ }
  };
  pc.onconnectionstatechange = () => {
    if (pc.connectionState === "failed") fail(`Couldn't connect to ${name} directly. Both devices need to be on the same Wi-Fi.`);
  };

  current.relay = new RelaySocket(`${RELAY}/join/${target.room}`, {
    onOpen: async () => {
      if (pc.localDescription) return;
      await pc.setLocalDescription(await pc.createOffer());
      current.relay.send({ m: { t: "offer", sdp: pc.localDescription.sdp } });
    },
    onMessage: async (data) => {
      if (data.t === "offline") return fail(`${name} isn't online right now. Open Droprr on it and try again.`);
      if (data.t === "refused") return fail(`${name} didn't accept this browser. Scan its code again.`);
      if (data.t !== "msg" || !data.m) return;
      const m = data.m;
      if (m.t === "answer" && typeof m.sdp === "string") {
        // The computer's key from its code must be the one on this connection; otherwise it's someone else.
        if (!fp || sdpFingerprint(m.sdp) !== fp) {
          return fail(`That isn't the computer whose code you scanned. Scan its code again.`);
        }
        await pc.setRemoteDescription({ type: "answer", sdp: m.sdp });
        for (const c of pending.splice(0)) await addCandidate(c);
      } else if (m.t === "ice") {
        // Candidates can arrive before the answer is applied; dropping them made first tries fail.
        if (pc.remoteDescription) await addCandidate(m.c);
        else pending.push(m.c);
      }
    },
    onClose: (code) => {
      if (code === 4003) fail(`${name} didn't accept this browser. Scan its code again.`);
    },
  });

  channel.onopen = () => {
    clearTimeout(timeout);
    current.relay.close();
    link = new Link(channel, {
      onControl: (message) => {
        if (message.t === "welcome") {
          current.done = true;
          current.name = String(message.name || name).slice(0, 64);
          remember(current.room, { fp, token: String(message.token || ""), name: current.name });
          showApp(current.name);
        } else if (message.t === "denied") {
          // Only a refused token is forgotten; a stale code says nothing about a token this browser has.
          if (!target.secret) remember(current.room, { token: "" });
          fail(`${name} didn't accept this browser${message.e ? ` (${message.e})` : ""}. Scan its code again.`);
        } else if (message.t === "invite") {
          showInvite(message);
        } else if (message.t === "bye") {
          // The other side disconnected this browser and forgot its token.
          remember(current.room, { token: "" });
          disconnect(false);
          showStart();
          setStatus($("start-status"), `${current.name} disconnected this browser. Scan its code to connect again.`, "error");
        }
      },
      onItem: async (item) => addReceived(item),
      onProgress: showProgress,
      onClose: () => {
        if (session !== current) return;
        link = null;
        session = null;
        if (current.done) {
          showStart();
          setStatus($("start-status"), `Disconnected from ${current.name}.`, "error");
        } else {
          fail(`${name} closed the connection.`);
        }
      },
    });
    link.control({
      t: "hello", v: 1, id: browserId(), name: guessBrowserName(),
      secret: target.secret || undefined, token: target.secret ? undefined : saved.token || undefined,
    });
  };
}

// show: back to the start screen (the Disconnect button). Only then is a device that connected to this browser
// forgotten; replacing one connection with another isn't a disconnect.
function disconnect(show = true, forget = show) {
  const current = session;
  const currentLink = link;
  session = null;
  link = null;
  if (current?.hosted && current.id && forget) {
    // Disconnect from a device that connected to this browser forgets it: its token stops working, so it can't
    // reconnect (or send) without scanning this browser's code again. It's told why first.
    const peers = hostPeers();
    delete peers[current.id];
    storage(HOST_PEERS, JSON.stringify(peers));
    currentLink?.control({ t: "bye" });
    setTimeout(() => current.pc?.close(), 300);
    if (!Object.keys(peers).length && hosting && !hosting.secret) {
      hosting.relay.close();
      hosting = null;
    }
  } else if (current) {
    current.relay?.close();
    current.pc?.close();
  }
  if (show) showStart();
}

// --- Screens --------------------------------------------------------------------------------------------------

function showStart() {
  stopScan();
  $("app").hidden = true;
  $("disconnect").hidden = true;
  $("start").hidden = false;
  $("where").textContent = "Send between this browser and your computer";
  document.title = "Droprr";
  const list = $("computers");
  list.replaceChildren();
  const known = Object.values(computers()).filter((c) => c.token).sort((a, b) => (b.seen || 0) - (a.seen || 0));
  for (const computer of known) {
    const row = document.createElement("li");
    row.className = "computer";
    const name = document.createElement("span");
    name.className = "item-name";
    name.textContent = computer.name || "Computer";
    const go = document.createElement("button");
    go.type = "button";
    go.className = "primary";
    go.textContent = "Connect";
    go.addEventListener("click", () => connect({ room: computer.room }));
    const forget = document.createElement("button");
    forget.type = "button";
    forget.className = "link";
    forget.textContent = "Forget";
    forget.addEventListener("click", () => { remember(computer.room, null); showStart(); });
    row.append(name, go, forget);
    list.append(row);
  }
  $("known").hidden = known.length === 0;
}

// --- Sharing ----------------------------------------------------------------------------------------------------

// Show QR code asks the computer for a code another phone can join it with; the code shows blurred until tapped.
$("show-qr").addEventListener("click", () => {
  if (!link) return;
  if (!$("share-code").hidden) {
    hideInvite();
    return;
  }
  setStatus($("share-status"), "Getting a code…");
  link.control({ t: "invite" });
});

$("qr-plate").addEventListener("click", () => {
  $("qr-plate").classList.remove("blurred");
  $("qr-plate").setAttribute("aria-label", "QR code to connect another phone");
});

function showInvite(message) {
  const code = typeof message.link === "string" ? parseCode(message.link) : null;
  if (!code || !self.qrcode) {
    setStatus($("share-status"), `Couldn't get a code${message.e ? `: ${message.e}` : ""}.`, "error");
    return;
  }
  // The computer's own link to this website, so only this page's origin is ever encoded.
  const qr = self.qrcode(0, "M");
  qr.addData(`${location.origin}${location.pathname}#${code.room}.${code.secret}.${code.fp}`);
  qr.make();
  $("qr-image").src = qr.createDataURL(8, 0);
  $("qr-plate").classList.add("blurred");
  $("qr-plate").setAttribute("aria-label", "Tap to show the code");
  $("share-code").hidden = false;
  $("show-qr").textContent = "Hide QR code";
  setStatus($("share-status"), "");
  clearTimeout(inviteTimer);
  inviteTimer = setTimeout(hideInvite, 10 * 60 * 1000);
}

let inviteTimer = null;

function hideInvite() {
  clearTimeout(inviteTimer);
  $("share-code").hidden = true;
  $("qr-image").removeAttribute("src");
  $("show-qr").textContent = "Show QR code";
}

// --- Hosting --------------------------------------------------------------------------------------------------
//
// This browser as the host of its own room (docs/PROTOCOL.md, "Browsers as hosts"), so a Droprr iPhone app (or
// another browser) can connect to it: the start screen's Show QR code. Its host key stays in this browser's storage
// and its DTLS certificate in IndexedDB, so a device it accepted can reconnect later while this page is open.

const HOST_KEY = "droprr.hostKey";
const HOST_PEERS = "droprr.hostPeers";
const { base64url, fromBase64url, sameSecret } = self.DroprrRtc;
let hosting = null;

function hostPeers() {
  try {
    const list = JSON.parse(storage(HOST_PEERS) || "{}");
    return list && typeof list === "object" ? list : {};
  } catch {
    return {};
  }
}

function hostCertificate() {
  return new Promise((resolve) => {
    let request;
    try { request = indexedDB.open("droprr-web-host", 1); } catch { resolve(null); return; }
    request.onupgradeneeded = () => request.result.createObjectStore("certs");
    request.onerror = () => resolve(null);
    request.onsuccess = () => {
      const db = request.result;
      const read = db.transaction("certs").objectStore("certs").get("dtls");
      read.onerror = () => resolve(null);
      read.onsuccess = () => resolve(read.result || null);
    };
  }).then(async (stored) => {
    if (stored && stored.expires - Date.now() > 30 * 24 * 3600 * 1000) return stored;
    const fresh = await RTCPeerConnection.generateCertificate({ name: "ECDSA", namedCurve: "P-256", expires: 365 * 24 * 3600 * 1000 });
    try {
      const request = indexedDB.open("droprr-web-host", 1);
      request.onsuccess = () => request.result.transaction("certs", "readwrite").objectStore("certs").put(fresh, "dtls");
    } catch { /* not remembered: devices scan again next time */ }
    return fresh;
  });
}

// Starts listening as a host (once per page), and returns the room details.
async function startHosting() {
  if (hosting) return hosting;
  if (!RELAY || /example\.workers\.dev/.test(RELAY)) throw new Error("this copy of the page has no introduction server");
  let key = storage(HOST_KEY);
  if (!key || !ID.test(key)) {
    key = randomId(32);
    storage(HOST_KEY, key);
  }
  const certificate = await hostCertificate();
  const sha = certificate.getFingerprints().find((f) => f.algorithm === "sha-256");
  const h = {
    key, certificate, secret: null, guests: new Map(),
    room: base64url(await crypto.subtle.digest("SHA-256", fromBase64url(key))),
    fp: base64url(Uint8Array.from(sha.value.split(":"), (x) => parseInt(x, 16))),
  };
  h.relay = new RelaySocket(`${RELAY}/host/${key}`, {
    keepalive: true,
    onMessage: (data) => {
      if (data.t === "from" && typeof data.cid === "string" && data.m) hostSignal(h, data.cid, data.m);
    },
  });
  hosting = h;
  return h;
}

async function hostSignal(h, cid, m) {
  let guest = h.guests.get(cid);
  if (m.t === "offer" && typeof m.sdp === "string" && m.sdp.length < 12000) {
    guest?.pc.close();
    const pc = new RTCPeerConnection({ iceServers: ICE_SERVERS, certificates: [h.certificate] });
    guest = { pc, pending: [], accepted: false };
    h.guests.set(cid, guest);
    pc.onicecandidate = (event) => h.relay.send({ t: "to", cid, m: { t: "ice", c: event.candidate ? event.candidate.toJSON() : null } });
    pc.ondatachannel = (event) => {
      if (event.channel.label === "droprr" && !guest.link) acceptGuest(h, cid, guest, event.channel);
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

// A device that scanned this browser's code (with its secret) or reconnects (with the token it was given). This
// browser talks to one device at a time; a new one replaces the current connection.
function acceptGuest(h, cid, guest, channel) {
  const current = { name: "", pc: guest.pc, done: false, hosted: true };
  guest.link = new Link(channel, {
    onControl: (message) => {
      if (message.t !== "hello" || guest.hello) return;
      guest.hello = true;
      const id = String(message.id || "");
      const known = hostPeers()[id];
      const byToken = known && sameSecret(message.token, known.token);
      if (!/^[A-Za-z0-9_-]{22}$/.test(id) || !(byToken || (h.secret && sameSecret(message.secret, h.secret)))) {
        guest.link.control({ t: "denied", e: "scan this browser's code again" });
        setTimeout(() => guest.pc.close(), 500);
        return;
      }
      const token = byToken ? known.token : randomId(32);
      const name = String(message.name || "Device").replace(/[\u0000-\u001f\u007f‪-‮⁦-⁩]/g, "").slice(0, 64) || "Device";
      const peers = hostPeers();
      peers[id] = { token, name };
      storage(HOST_PEERS, JSON.stringify(peers));
      guest.accepted = true;
      guest.link.control({ t: "welcome", name: guessBrowserName(), token });
      if (session && session !== current) disconnect(false);
      current.name = name;
      current.id = id;
      current.done = true;
      session = current;
      link = guest.link;
      hideHostCode();
      showApp(name);
    },
    accepting: () => guest.accepted,
    onItem: async (item) => addReceived(item),
    onProgress: showProgress,
    onClose: () => {
      h.guests.delete(cid);
      guest.pc.close();
      if (session !== current) return;
      link = null;
      session = null;
      showStart();
      setStatus($("start-status"), `Disconnected from ${current.name}.`, "error");
    },
  });
}

// The start screen's Show QR code: this browser's own code, blurred until tapped, valid for 10 minutes.
$("host-qr").addEventListener("click", async () => {
  if (!$("host-code").hidden) {
    hideHostCode();
    return;
  }
  setStatus($("start-status"), "Getting a code…");
  try {
    const h = await startHosting();
    h.secret = randomId(16);
    const info = base64url(new TextEncoder().encode(JSON.stringify({ v: 1, p: "web", n: guessBrowserName() })));
    const qr = self.qrcode(0, "M");
    qr.addData(`${location.origin}${location.pathname}#${h.room}.${h.secret}.${h.fp}.${info}`);
    qr.make();
    $("host-image").src = qr.createDataURL(8, 0);
    $("host-plate").classList.add("blurred");
    $("host-code").hidden = false;
    $("host-qr").textContent = "Hide QR code";
    setStatus($("start-status"), "");
    clearTimeout(hostTimer);
    hostTimer = setTimeout(hideHostCode, 10 * 60 * 1000);
  } catch (error) {
    setStatus($("start-status"), `Couldn't make a code: ${error.message}`, "error");
  }
});

$("host-plate").addEventListener("click", () => $("host-plate").classList.remove("blurred"));

let hostTimer = null;

function hideHostCode() {
  clearTimeout(hostTimer);
  if (hosting) hosting.secret = null;
  $("host-code").hidden = true;
  $("host-image").removeAttribute("src");
  $("host-qr").textContent = "Show QR code";
}

function showApp(name) {
  stopScan();
  hideInvite();
  $("start").hidden = true;
  $("app").hidden = false;
  $("disconnect").hidden = false;
  $("where").textContent = `Connected to ${name}`;
  $("send-title").textContent = `Send to ${name}`;
  $("inbox-title").textContent = `From ${name}`;
  document.title = `Droprr · ${name}`;
  setStatus($("start-status"), "");
}

$("disconnect").addEventListener("click", () => disconnect());

// --- Scanning -------------------------------------------------------------------------------------------------

let scanStream = null;
let scanTimer = null;

async function startScan() {
  setStatus($("start-status"), "");
  if (!navigator.mediaDevices?.getUserMedia) {
    setStatus($("start-status"), "This browser can't use the camera here. Scan the code with your camera app instead.", "error");
    return;
  }
  try {
    scanStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" }, audio: false });
  } catch {
    setStatus($("start-status"), "Droprr needs the camera to scan. Allow it, or scan the code with your camera app.", "error");
    return;
  }
  const video = $("camera");
  video.srcObject = scanStream;
  await video.play().catch(() => {});
  $("scanner").hidden = false;
  $("scan").hidden = true;
  const canvas = document.createElement("canvas");
  const context = canvas.getContext("2d", { willReadFrequently: true });
  const detector = "BarcodeDetector" in self ? new self.BarcodeDetector({ formats: ["qr_code"] }) : null;
  const tick = async () => {
    if (!scanStream) return;
    let text = null;
    if (video.readyState >= 2 && video.videoWidth) {
      if (detector) {
        try { text = (await detector.detect(video))[0]?.rawValue || null; } catch { /* fall back below */ }
      }
      if (!text && self.jsQR) {
        const scale = Math.min(1, 640 / Math.max(video.videoWidth, video.videoHeight));
        canvas.width = Math.round(video.videoWidth * scale);
        canvas.height = Math.round(video.videoHeight * scale);
        context.drawImage(video, 0, 0, canvas.width, canvas.height);
        const image = context.getImageData(0, 0, canvas.width, canvas.height);
        text = self.jsQR(image.data, image.width, image.height, { inversionAttempts: "dontInvert" })?.data || null;
      }
    }
    const code = text && parseCode(text);
    if (code) {
      stopScan();
      connect(code);
      return;
    }
    if (text) setStatus($("start-status"), "That's not a Droprr code. Choose Add a device on the computer.", "error");
    scanTimer = setTimeout(tick, 150);
  };
  tick();
}

function stopScan() {
  clearTimeout(scanTimer);
  scanStream?.getTracks().forEach((track) => track.stop());
  scanStream = null;
  $("scanner").hidden = true;
  $("scan").hidden = false;
}

$("scan").addEventListener("click", startScan);
$("stop-scan").addEventListener("click", stopScan);

// --- Sending --------------------------------------------------------------------------------------------------

function renderChosen() {
  const list = $("chosen");
  list.replaceChildren();
  chosenFiles.forEach((file, index) => {
    const row = document.createElement("li");
    const name = document.createElement("span");
    name.textContent = file.name || "File";
    const size = document.createElement("span");
    size.className = "item-meta";
    size.textContent = formatSize(file.size);
    const remove = document.createElement("button");
    remove.type = "button";
    remove.className = "link";
    remove.textContent = "Remove";
    remove.addEventListener("click", () => {
      chosenFiles.splice(index, 1);
      renderChosen();
    });
    row.append(name, size, remove);
    list.append(row);
  });
  $("drop-hint").textContent = chosenFiles.length ? `${chosenFiles.length} chosen · tap to add more` : "";
}

function addFiles(files) {
  for (const file of files) chosenFiles.push(file);
  renderChosen();
}

$("files").addEventListener("change", () => {
  addFiles($("files").files);
  $("files").value = "";
});

const drop = $("drop");
drop.addEventListener("dragover", (event) => { event.preventDefault(); drop.classList.add("over"); });
drop.addEventListener("dragleave", () => drop.classList.remove("over"));
drop.addEventListener("drop", (event) => {
  event.preventDefault();
  drop.classList.remove("over");
  if (event.dataTransfer?.files?.length) addFiles(event.dataTransfer.files);
});

document.addEventListener("paste", (event) => {
  if ($("app").hidden || event.target === $("text")) return;
  const files = [...(event.clipboardData?.files || [])];
  if (files.length) {
    event.preventDefault();
    addFiles(files);
  }
});

$("clear").addEventListener("click", () => {
  chosenFiles = [];
  $("text").value = "";
  renderChosen();
  setStatus($("send-status"), "");
});

function showProgress(progress) {
  if (progress.direction !== "out") return;
  $("progress").hidden = false;
  $("progress").value = progress.total ? progress.done / progress.total : 1;
  setStatus($("send-status"), `Sending ${progress.name}… ${formatSize(progress.done)} of ${formatSize(progress.total)}`);
}

$("send-button").addEventListener("click", async () => {
  if (!link) return;
  const text = $("text").value;
  const files = chosenFiles.slice();
  if (!files.length && !text.trim()) {
    setStatus($("send-status"), "Choose a file or type something first.", "error");
    return;
  }
  const name = session?.name || "the computer";
  const button = $("send-button");
  button.disabled = true;
  let sent = 0;
  try {
    for (const file of files) {
      await link.sendFile(file, file.name);
      sent++;
      chosenFiles.splice(chosenFiles.indexOf(file), 1);
      renderChosen();
    }
    if (text.trim()) {
      await link.sendText(isWebUrl(text) ? text.trim() : text, isWebUrl(text) ? "url" : "text");
      sent++;
      $("text").value = "";
    }
    setStatus($("send-status"), `Sent ${sent === 1 ? "1 item" : `${sent} items`} to ${name}.`, "ok");
  } catch (error) {
    setStatus($("send-status"), `Couldn't send${sent ? ` everything (${sent} sent)` : ""}: ${error.message}`, "error");
  } finally {
    button.disabled = false;
    $("progress").hidden = true;
  }
});

// --- Receiving ------------------------------------------------------------------------------------------------

function addReceived(item) {
  const row = document.createElement("li");
  const head = document.createElement("div");
  head.className = "item-head";
  const title = document.createElement("span");
  title.className = "item-name";
  title.textContent = item.kind === "file" ? item.name : item.kind === "url" ? "Link" : "Text";
  const meta = document.createElement("span");
  meta.className = "item-meta";
  meta.textContent = item.kind === "file" ? formatSize(item.blob.size) : "just now";
  head.append(title, meta);
  row.append(head);

  const actions = document.createElement("div");
  actions.className = "item-actions";
  const button = (label, onClick, main) => {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = label;
    if (main) b.className = "main";
    b.addEventListener("click", onClick);
    actions.append(b);
    return b;
  };

  let url = null;
  if (item.kind === "file") {
    const file = new File([item.blob], item.name, { type: item.blob.type });
    url = URL.createObjectURL(file);
    // On a phone, Save opens the share sheet (Save Image, Save to Files); elsewhere it downloads.
    if (navigator.canShare?.({ files: [file] })) {
      button("Save", () => navigator.share({ files: [file] }).catch(() => {}), true);
      const download = document.createElement("a");
      download.href = url;
      download.download = item.name;
      download.textContent = "Download";
      actions.append(download);
    } else {
      const download = document.createElement("a");
      download.className = "main";
      download.href = url;
      download.download = item.name;
      download.textContent = "Download";
      actions.append(download);
    }
  } else {
    const text = document.createElement("p");
    text.className = "item-text";
    text.textContent = item.content;
    row.append(text);
    button("Copy", async (event) => {
      const target = event.currentTarget;
      try { await navigator.clipboard.writeText(item.content); target.textContent = "Copied"; }
      catch { target.textContent = "Couldn't copy"; }
      setTimeout(() => { target.textContent = "Copy"; }, 1500);
    }, true);
    if (item.kind === "url" && isWebUrl(item.content)) {
      const open = document.createElement("a");
      open.href = item.content.trim();
      open.target = "_blank";
      open.rel = "noopener noreferrer";
      open.textContent = "Open";
      actions.append(open);
    }
  }
  button("Remove", () => {
    if (url) URL.revokeObjectURL(url);
    row.remove();
    received.delete(item.id);
    $("inbox-empty").hidden = received.size > 0;
  });
  row.append(actions);
  received.set(item.id, row);
  $("items").prepend(row);
  $("inbox-empty").hidden = true;
}

// --- Start ----------------------------------------------------------------------------------------------------

// A code in the link: from the camera app, or a new one opened while this page is already open.
function connectFromLink() {
  const code = parseCode(location.hash);
  if (!code) return;
  // The code stays out of the address bar and history once it's read.
  history.replaceState(null, "", location.pathname + location.search);
  offerApp(code);
  connect(code);
}

// A phone with the Droprr app can pair it from the same code, while the window on the computer is open.
function offerApp(code) {
  const link = $("open-app");
  if (!code.app || !/iPhone|iPad|Macintosh/.test(navigator.userAgent)) {
    link.hidden = true;
    return;
  }
  link.href = `droprr://join?code=${encodeURIComponent(`${code.room}.${code.secret}.${code.fp}.${code.app}`)}`;
  link.hidden = false;
}

renderChosen();
showStart();
connectFromLink();
addEventListener("hashchange", connectFromLink);
// Devices this browser accepted before can reconnect while the page is open.
if (Object.keys(hostPeers()).length) startHosting().catch(() => {});
