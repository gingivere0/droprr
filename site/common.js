// What both browser pages share: the website (site/guest.js) and the page each computer serves itself
// (web/app.js, which loads this file as /web/common.js). Helpers, and the list of files chosen to send with its
// file picker, drag and drop, paste, and Clear. Both pages use the same element ids for these.
"use strict";

const $ = (id) => document.getElementById(id);

function setStatus(element, text, kind) {
  element.textContent = text;
  element.className = "status" + (kind ? " " + kind : "");
}

// "iPhone (Safari)", "Windows (Edge)", and so on: the name a computer lists this browser under.
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

// A single http(s) link, which is sent as a link rather than text.
function isWebUrl(text) {
  if (/\s/.test(text.trim())) return false;
  try {
    const url = new URL(text.trim());
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

// --- Choosing files to send -----------------------------------------------------------------------------------

const chosen = {
  files: [],

  add(files) {
    for (const file of files) this.files.push(file);
    this.render();
  },

  remove(file) {
    const index = this.files.indexOf(file);
    if (index >= 0) this.files.splice(index, 1);
    this.render();
  },

  clear() {
    this.files = [];
    this.render();
  },

  render() {
    const list = $("chosen");
    list.replaceChildren();
    for (const file of this.files) {
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
      remove.setAttribute("aria-label", `Remove ${file.name || "File"}`);
      remove.addEventListener("click", () => this.remove(file));
      row.append(name, size, remove);
      list.append(row);
    }
    $("drop-hint").textContent = this.files.length ? `${this.files.length} chosen · tap to add more` : "";
  },
};

$("files").addEventListener("change", () => {
  chosen.add($("files").files);
  $("files").value = "";
});

const drop = $("drop");
drop.addEventListener("dragover", (event) => { event.preventDefault(); drop.classList.add("over"); });
drop.addEventListener("dragleave", () => drop.classList.remove("over"));
drop.addEventListener("drop", (event) => {
  event.preventDefault();
  drop.classList.remove("over");
  if (event.dataTransfer?.files?.length) chosen.add(event.dataTransfer.files);
});

document.addEventListener("paste", (event) => {
  if ($("app").hidden || event.target === $("text")) return;
  const files = [...(event.clipboardData?.files || [])];
  if (files.length) {
    event.preventDefault();
    chosen.add(files);
  }
});

$("clear").addEventListener("click", () => {
  chosen.clear();
  $("text").value = "";
  setStatus($("send-status"), "");
});

chosen.render();
