// Droprr's browser page (docs/PROTOCOL.md, "Browser access"). Served by the computer itself; every call goes back
// to the same origin. Access is the HttpOnly cookie the computer set when this browser used an access code, so the
// page never sees a token. Everything from the network is shown with textContent, never as HTML.
"use strict";

const $ = (id) => document.getElementById(id);

const POLL_MS = 3000;
let computer = "your computer";
let pollTimer = null;
let chosenFiles = [];
const shownItems = new Map();

// Every call sends X-Droprr-Web, which a page on another site can't add without a CORS preflight the computer
// never approves.
function api(path, options = {}) {
  return fetch(path, {
    credentials: "same-origin",
    cache: "no-store",
    ...options,
    headers: { "X-Droprr-Web": "1", ...(options.headers || {}) },
  });
}

async function errorText(response) {
  try {
    const body = await response.json();
    if (body && typeof body.error === "string") return body.error;
  } catch { /* not JSON */ }
  return `error ${response.status}`;
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

function formatTime(iso) {
  const date = new Date(iso);
  if (isNaN(date)) return "";
  const minutes = Math.round((Date.now() - date) / 60000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes} min ago`;
  return date.toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
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

// --- Access ---------------------------------------------------------------------------------------------------

function normalizeCode(code) {
  return code.toUpperCase().replace(/[^0-9A-Z]/g, "");
}

async function useCode(code, name) {
  const response = await api("/web/session", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code: normalizeCode(code), name }),
  });
  if (!response.ok) throw new Error(await errorText(response));
  return response.json();
}

async function start() {
  // A code from the QR (in the fragment, which never reaches the server's logs): used once, then removed.
  const fromLink = normalizeCode(decodeURIComponent(location.hash.slice(1)));
  if (fromLink) {
    history.replaceState(null, "", location.pathname);
    try {
      await useCode(fromLink, guessBrowserName());
    } catch (error) {
      showSignIn(`That code didn't work (${error.message}). Open a new one on your computer.`);
      return;
    }
  }
  await check();
}

async function check() {
  let response;
  try {
    response = await api("/ping");
  } catch {
    $("where").textContent = "Can't reach your computer. Is Droprr running?";
    setTimeout(check, POLL_MS);
    return;
  }
  if (response.status === 401) {
    showSignIn();
    return;
  }
  if (!response.ok) {
    $("where").textContent = await errorText(response);
    return;
  }
  const info = await response.json();
  computer = typeof info.name === "string" && info.name ? info.name : computer;
  showApp(typeof info.you === "string" ? info.you : "");
}

function showSignIn(message) {
  stopPolling();
  $("where").textContent = "Not connected";
  $("signout").hidden = true;
  $("app").hidden = true;
  $("signin").hidden = false;
  if (!$("browser-name").value) $("browser-name").value = guessBrowserName();
  setStatus($("signin-status"), message || "", message ? "error" : "");
}

function showApp(you) {
  $("signin").hidden = true;
  $("app").hidden = false;
  $("signout").hidden = false;
  $("where").textContent = you ? `Connected to ${computer} as ${you}` : `Connected to ${computer}`;
  $("inbox-title").textContent = `From ${computer}`;
  document.title = `Droprr · ${computer}`;
  startPolling();
}

$("signin-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const button = event.submitter || $("signin-form").querySelector("button");
  button.disabled = true;
  setStatus($("signin-status"), "Connecting…");
  try {
    await useCode($("code").value, $("browser-name").value.trim() || guessBrowserName());
    $("code").value = "";
    await check();
  } catch (error) {
    setStatus($("signin-status"), `Couldn't connect: ${error.message}`, "error");
  } finally {
    button.disabled = false;
  }
});

$("code").addEventListener("input", () => {
  const code = normalizeCode($("code").value).slice(0, 8);
  $("code").value = code.length > 4 ? `${code.slice(0, 4)}-${code.slice(4)}` : code;
});

$("signout").addEventListener("click", async () => {
  if (!confirm(`Disconnect this browser from ${computer}? You'll need a new code to connect again.`)) return;
  try { await api("/web/signout", { method: "POST" }); } catch { /* signed out locally anyway */ }
  shownItems.clear();
  $("items").replaceChildren();
  showSignIn();
});

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
    remove.setAttribute("aria-label", `Remove ${file.name}`);
    remove.addEventListener("click", () => {
      chosenFiles.splice(index, 1);
      renderChosen();
    });
    row.append(name, size, remove);
    list.append(row);
  });
  $("drop-hint").textContent = chosenFiles.length
    ? `${chosenFiles.length} chosen · tap to add more`
    : "";
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

// One multipart request: each file is a part with a filename, and the text (if any) a part without one, which the
// computer saves as text or a link. It's all or nothing, so a retry never duplicates files.
$("send-button").addEventListener("click", () => {
  const text = $("text").value;
  if (!chosenFiles.length && !text.trim()) {
    setStatus($("send-status"), "Choose a file or type something first.", "error");
    return;
  }
  const form = new FormData();
  for (const file of chosenFiles) form.append("file", file, file.name || "File");
  if (text.trim()) form.append(isWebUrl(text) ? "url" : "text", isWebUrl(text) ? text.trim() : text);
  const count = chosenFiles.length + (text.trim() ? 1 : 0);

  const button = $("send-button");
  const progress = $("progress");
  button.disabled = true;
  progress.hidden = false;
  progress.value = 0;
  setStatus($("send-status"), "Sending…");

  const request = new XMLHttpRequest();
  request.open("POST", "/send");
  request.setRequestHeader("X-Droprr-Web", "1");
  request.upload.addEventListener("progress", (event) => {
    if (!event.lengthComputable) return;
    progress.value = event.loaded / event.total;
    setStatus($("send-status"), `Sending… ${formatSize(event.loaded)} of ${formatSize(event.total)}`);
  });
  request.addEventListener("load", () => {
    button.disabled = false;
    progress.hidden = true;
    if (request.status === 401) {
      showSignIn("This browser was disconnected. Open a new code on your computer.");
      return;
    }
    let error = `error ${request.status}`;
    try { error = JSON.parse(request.responseText).error || error; } catch { /* keep the status */ }
    if (request.status >= 200 && request.status < 300) {
      setStatus($("send-status"), `Sent ${count === 1 ? "1 item" : `${count} items`} to ${computer}.`, "ok");
      chosenFiles = [];
      $("text").value = "";
      renderChosen();
    } else {
      setStatus($("send-status"), `Couldn't send: ${error}`, "error");
    }
  });
  request.addEventListener("error", () => {
    button.disabled = false;
    progress.hidden = true;
    setStatus($("send-status"), `Couldn't reach ${computer}. Nothing was sent.`, "error");
  });
  request.send(form);
});

// --- Receiving ------------------------------------------------------------------------------------------------

function startPolling() {
  stopPolling();
  poll();
}

function stopPolling() {
  clearTimeout(pollTimer);
  pollTimer = null;
}

async function poll() {
  clearTimeout(pollTimer);
  if (document.visibilityState === "visible") {
    try {
      const response = await api("/inbox");
      if (response.status === 401) {
        showSignIn("This browser was disconnected. Open a new code on your computer.");
        return;
      }
      if (response.ok) renderInbox((await response.json()).items || []);
    } catch { /* the computer is asleep or unreachable: try again shortly */ }
  }
  pollTimer = setTimeout(poll, POLL_MS);
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && !$("app").hidden) startPolling();
});

const VIEWABLE = /\.(jpe?g|png|gif|webp|heic|heif|mp4|mov|m4v)$/i;

function renderInbox(items) {
  const list = $("items");
  const ids = new Set(items.map((item) => item.id));
  for (const [id, row] of shownItems) {
    if (!ids.has(id)) {
      row.remove();
      shownItems.delete(id);
    }
  }
  // Newest first.
  for (const item of items) {
    if (!shownItems.has(item.id)) {
      const row = renderItem(item);
      shownItems.set(item.id, row);
      list.prepend(row);
    } else {
      shownItems.get(item.id).querySelector(".item-meta").textContent = itemMeta(item);
    }
  }
  $("inbox-empty").hidden = items.length > 0;
}

function itemMeta(item) {
  return item.type === "file" ? `${formatSize(item.size)} · ${formatTime(item.created)}` : formatTime(item.created);
}

function action(label, onClick, main) {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = label;
  if (main) button.className = "main";
  button.addEventListener("click", onClick);
  return button;
}

function renderItem(item) {
  const row = document.createElement("li");
  const head = document.createElement("div");
  head.className = "item-head";
  const name = document.createElement("span");
  name.className = "item-name";
  name.textContent = item.type === "file" ? item.name : item.type === "url" ? "Link" : "Text";
  const meta = document.createElement("span");
  meta.className = "item-meta";
  meta.textContent = itemMeta(item);
  head.append(name, meta);
  row.append(head);

  const actions = document.createElement("div");
  actions.className = "item-actions";
  const path = `/inbox/${encodeURIComponent(item.id)}`;

  if (item.type === "file") {
    const download = document.createElement("a");
    download.className = "main";
    download.href = path;
    download.download = item.name;
    download.textContent = "Download";
    actions.append(download);
    if (VIEWABLE.test(item.name)) {
      const view = document.createElement("a");
      view.href = `${path}?inline=1`;
      view.target = "_blank";
      view.rel = "noopener";
      view.textContent = "View";
      actions.append(view);
    }
  } else {
    const content = typeof item.content === "string" ? item.content : "";
    const text = document.createElement("p");
    text.className = "item-text";
    text.textContent = content;
    row.append(text);
    actions.append(action("Copy", (event) => copy(content, event.currentTarget), true));
    if (item.type === "url" && isWebUrl(content)) {
      const open = document.createElement("a");
      open.href = content.trim();
      open.target = "_blank";
      open.rel = "noopener noreferrer";
      open.textContent = "Open";
      actions.append(open);
    }
  }
  actions.append(action("Remove", async () => {
    const response = await api(path, { method: "DELETE" }).catch(() => null);
    if (response && (response.ok || response.status === 404)) {
      row.remove();
      shownItems.delete(item.id);
      $("inbox-empty").hidden = shownItems.size > 0;
    }
  }));
  row.append(actions);
  return row;
}

// The Clipboard API needs a secure context, which plain HTTP over Tailscale isn't, so fall back to a selection.
async function copy(text, button) {
  let done = false;
  try {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      done = true;
    }
  } catch { /* try the fallback */ }
  if (!done) {
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.append(area);
    area.select();
    area.setSelectionRange(0, text.length);
    try { done = document.execCommand("copy"); } catch { done = false; }
    area.remove();
  }
  const label = button.textContent;
  button.textContent = done ? "Copied" : "Couldn't copy";
  setTimeout(() => { button.textContent = label; }, 1500);
}

renderChosen();
start();
