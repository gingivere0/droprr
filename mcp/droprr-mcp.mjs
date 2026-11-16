#!/usr/bin/env node
// Droprr's MCP server: lets AI assistants (Claude Desktop, Claude Code, and other MCP clients) send text, links,
// and files to your devices through the Droprr app running on this computer. It speaks MCP over stdio and calls
// the app's local API (docs/PROTOCOL.md, "Local API"), so pairing, Wi-Fi or Tailscale, and phone queues all work
// exactly as they do from the Send window. No dependencies: Node 18 or later.

import { mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { basename, isAbsolute, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const SERVER = { name: "droprr", version: "0.1.0" };
const PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];

// ---- The app's local API -----------------------------------------------------------------------------------

// Where the Droprr app writes its address and local token. DROPRR_URL and DROPRR_TOKEN override it.
export function connectionFile(platform = process.platform, env = process.env) {
  if (env.DROPRR_CONNECTION_FILE) return env.DROPRR_CONNECTION_FILE;
  if (platform === "win32") return join(env.APPDATA || join(homedir(), "AppData", "Roaming"), "Droprr", "local-api.json");
  if (platform === "darwin") return join(homedir(), "Library", "Application Support", "Droprr", "local-api.json");
  return join(env.XDG_CONFIG_HOME || join(homedir(), ".config"), "Droprr", "local-api.json");
}

class DroprrError extends Error {}

const NOT_RUNNING = "Droprr isn't running on this computer. Start the Droprr app and try again (Droprr 0.3.3 and older need an update first).";

// Read on every call: the token changes each time the app starts.
async function connection() {
  if (process.env.DROPRR_URL && process.env.DROPRR_TOKEN)
    return { url: process.env.DROPRR_URL, token: process.env.DROPRR_TOKEN };
  try {
    const { url, token } = JSON.parse(await readFile(connectionFile(), "utf8"));
    if (typeof url === "string" && typeof token === "string") return { url, token };
  } catch {
    // Missing or unreadable: the app hasn't run, or it's older than the local API.
  }
  throw new DroprrError(NOT_RUNNING);
}

async function call(method, path, body, retried = false) {
  const { url, token } = await connection();
  let response;
  try {
    response = await fetch(new URL(path, url), {
      method,
      headers: { Authorization: `Bearer ${token}`, ...(body ? { "Content-Type": "application/json" } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new DroprrError(NOT_RUNNING);
  }
  // The app restarted and wrote a new token since we read it: read it again, once.
  if (response.status === 401 && !retried) return call(method, path, body, true);
  const answer = await response.json().catch(() => ({}));
  if (!response.ok || answer.ok === false)
    throw new DroprrError(answer.error || `Droprr answered ${response.status}`);
  return answer;
}

const listDevices = () => call("GET", "/local/devices");

// The device named `name`, or the only device when there's exactly one and no name was given.
async function pickDevice(name) {
  if (typeof name === "string" && name.trim()) return name.trim();
  const { devices } = await listDevices();
  const paired = devices.filter((d) => d.paired);
  if (paired.length === 1) return paired[0].name;
  throw new DroprrError(paired.length === 0
    ? "No devices are paired with Droprr on this computer yet. Pair one in the Droprr app first."
    : `Say which device to send to: ${paired.map((d) => d.name).join(", ")}.`);
}

function describeSend(answer) {
  switch (answer.path) {
    case "queued": return `Queued for ${answer.to}. It arrives the next time Droprr opens there (items wait up to 7 days).`;
    case "wifi": return `Sent to ${answer.to} over Wi-Fi.`;
    default: return `Sent to ${answer.to} over Tailscale.`;
  }
}

// ---- Tools -------------------------------------------------------------------------------------------------

const deviceArg = {
  type: "string",
  description: "The device's name, as list_devices shows it (case doesn't matter). May be left out when only one device is paired.",
};

export const TOOLS = [
  {
    name: "list_devices",
    title: "List Droprr devices",
    description: "Lists the devices this computer's Droprr can send to: computers (sent to directly), phones, and browsers (items wait in a queue until Droprr opens there).",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  {
    name: "send_text",
    title: "Send text or a link",
    description: "Sends text or a link to one of your devices with Droprr. A single http(s) URL arrives as a link the person can open; anything else arrives as text and is copied to that device's clipboard.",
    inputSchema: {
      type: "object",
      properties: { device: deviceArg, text: { type: "string", description: "The text or link to send." } },
      required: ["text"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
  },
  {
    name: "send_files",
    title: "Send files",
    description: "Sends files from this computer to one of your devices with Droprr. Give absolute paths to files (not folders).",
    inputSchema: {
      type: "object",
      properties: {
        device: deviceArg,
        paths: { type: "array", items: { type: "string" }, minItems: 1, description: "Absolute paths of the files to send." },
        text: { type: "string", description: "Optional text or link to send after the files." },
      },
      required: ["paths"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
  },
  {
    name: "send_file_content",
    title: "Send content as a file",
    description: "Creates a file from content you provide and sends it to one of your devices with Droprr, for example a note, a list, or a generated image. Give either text (for text files) or base64 (for anything else).",
    inputSchema: {
      type: "object",
      properties: {
        device: deviceArg,
        filename: { type: "string", description: "The file's name, with its extension, for example \"shopping-list.md\"." },
        text: { type: "string", description: "The file's contents as UTF-8 text." },
        base64: { type: "string", description: "The file's contents, base64-encoded." },
      },
      required: ["filename"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
  },
];

const ok = (text, structuredContent) => ({ content: [{ type: "text", text }], ...(structuredContent ? { structuredContent } : {}) });

const handlers = {
  async list_devices() {
    const answer = await listDevices();
    if (answer.devices.length === 0)
      return ok(`${answer.name} has no devices yet. Pair one in the Droprr app first.`, { name: answer.name, devices: [] });
    const lines = answer.devices.map((d) => {
      const what = d.kind === "computer" ? "computer, sent to directly" : `${d.kind}, queued until Droprr opens there`;
      const notes = [!d.paired && "not paired yet", d.waiting > 0 && `${d.waiting} waiting`].filter(Boolean);
      return `- ${d.name} (${[d.platform === "unknown" ? null : d.platform, what].filter(Boolean).join(", ")}${notes.length ? `; ${notes.join(", ")}` : ""})`;
    });
    return ok(`Devices ${answer.name} can send to:\n${lines.join("\n")}`, { name: answer.name, devices: answer.devices });
  },

  async send_text({ device, text }) {
    if (typeof text !== "string" || !text.trim()) throw new DroprrError("Give the text to send.");
    const answer = await call("POST", "/local/send", { to: await pickDevice(device), text });
    return ok(describeSend(answer), answer);
  },

  async send_files({ device, paths, text }) {
    if (!Array.isArray(paths) || paths.length === 0) throw new DroprrError("Give at least one file path.");
    const relative = paths.find((p) => typeof p !== "string" || !isAbsolute(p));
    if (relative !== undefined) throw new DroprrError(`Use absolute paths: ${relative}`);
    const answer = await call("POST", "/local/send", { to: await pickDevice(device), files: paths.map((p) => resolve(p)), text });
    return ok(describeSend(answer), answer);
  },

  async send_file_content({ device, filename, text, base64 }) {
    const name = typeof filename === "string" ? basename(filename.replaceAll("\\", "/")).trim() : "";
    if (!name || name === "." || name === "..") throw new DroprrError("Give the file a name, like notes.md.");
    if ((text === undefined) === (base64 === undefined)) throw new DroprrError("Give either text or base64, not both.");
    const to = await pickDevice(device);
    const folder = await mkdtemp(join(tmpdir(), "droprr-mcp-"));
    try {
      const path = join(folder, name);
      await writeFile(path, text !== undefined ? Buffer.from(text, "utf8") : Buffer.from(base64, "base64"));
      const answer = await call("POST", "/local/send", { to, files: [path] });
      return ok(describeSend(answer), answer);
    } finally {
      // Droprr has sent the file, or copied it into the device's queue, by the time it answers.
      await rm(folder, { recursive: true, force: true });
    }
  },
};

async function callTool(name, args) {
  const handler = handlers[name];
  if (!handler) return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
  try {
    return await handler(args ?? {});
  } catch (error) {
    const message = error instanceof DroprrError ? error.message : `Droprr failed: ${error?.message ?? error}`;
    return { content: [{ type: "text", text: message }], isError: true };
  }
}

// ---- MCP over stdio (JSON-RPC 2.0, one message per line) ---------------------------------------------------

async function handle(message) {
  const { id, method, params } = message;
  switch (method) {
    case "initialize": {
      const asked = params?.protocolVersion;
      return {
        protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
        capabilities: { tools: {} },
        serverInfo: SERVER,
        instructions: "Droprr sends text, links, and files from this computer to the person's own devices (their phone, other computers, or a browser). Call list_devices to see device names. Sending to a phone queues the item until Droprr opens there.",
      };
    }
    case "ping":
      return {};
    case "tools/list":
      return { tools: TOOLS };
    case "tools/call":
      return callTool(params?.name, params?.arguments);
    default:
      if (id === undefined) return undefined; // A notification, such as notifications/initialized.
      throw Object.assign(new Error(`Method not found: ${method}`), { code: -32601 });
  }
}

function send(message) {
  process.stdout.write(JSON.stringify(message) + "\n");
}

export function serve() {
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  lines.on("line", async (line) => {
    if (!line.trim()) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
      return;
    }
    // Answers from the client (we never ask it anything) and notifications need no reply.
    if (message.method === undefined) return;
    try {
      const result = await handle(message);
      if (message.id !== undefined) send({ jsonrpc: "2.0", id: message.id, result });
    } catch (error) {
      if (message.id !== undefined)
        send({ jsonrpc: "2.0", id: message.id, error: { code: error.code ?? -32603, message: error.message } });
    }
  });
}

// Run directly (node droprr-mcp.mjs), not imported by the tests.
const entry = process.argv[1] ? await realpath(process.argv[1]).catch(() => process.argv[1]) : "";
if (entry === fileURLToPath(import.meta.url)) serve();
