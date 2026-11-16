// Runs the MCP server against a stand-in for the app's local API: node --test mcp/test/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const SERVER = fileURLToPath(new URL("../droprr-mcp.mjs", import.meta.url));

// A fake Droprr app: answers /local/ like docs/PROTOCOL.md says, and records each send.
async function fakeApp({ devices, token = "local-token" }) {
  const sends = [];
  const server = createServer(async (req, res) => {
    const reply = (status, body) => {
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(body));
    };
    if (req.headers.authorization !== `Bearer ${app.token}`) return reply(401, { ok: false, error: "unauthorized" });
    if (req.method === "GET" && req.url === "/local/devices") return reply(200, { ok: true, name: "Desk", devices });
    if (req.method === "POST" && req.url === "/local/send") {
      let raw = "";
      for await (const chunk of req) raw += chunk;
      const body = JSON.parse(raw);
      const device = devices.find((d) => d.name.toLowerCase() === body.to.toLowerCase());
      if (!device) return reply(404, { ok: false, error: `no device named "${body.to}"` });
      // The file must still be there while the app sends it.
      const contents = await Promise.all((body.files ?? []).map((f) => readFile(f, "utf8")));
      sends.push({ ...body, contents });
      return reply(200, { ok: true, to: device.name, path: device.kind === "computer" ? "wifi" : "queued" });
    }
    reply(404, { ok: false, error: "not found" });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const folder = await mkdtemp(join(tmpdir(), "droprr-mcp-test-"));
  const file = join(folder, "local-api.json");
  const app = {
    token, sends, file,
    async writeConnection() {
      await writeFile(file, JSON.stringify({ url: `http://127.0.0.1:${server.address().port}`, token: app.token }));
    },
    async close() {
      server.close();
      await rm(folder, { recursive: true, force: true });
    },
  };
  await app.writeConnection();
  return app;
}

// An MCP client over the server's stdio.
function client(connectionFile) {
  const child = spawn(process.execPath, [SERVER], {
    env: { ...process.env, DROPRR_CONNECTION_FILE: connectionFile, DROPRR_URL: "", DROPRR_TOKEN: "" },
    stdio: ["pipe", "pipe", "inherit"],
  });
  let buffer = "";
  let next = 1;
  const waiting = new Map();
  child.stdout.on("data", (data) => {
    buffer += data;
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const message = JSON.parse(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
      (waiting.get(message.id) ?? api.onRaw)?.(message);
    }
  });
  const request = (method, params) => new Promise((resolve) => {
    const id = next++;
    waiting.set(id, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
  const tool = async (name, args) => (await request("tools/call", { name, arguments: args })).result;
  const api = { request, tool, raw: (text) => child.stdin.write(text), onRaw: null, close: () => child.kill() };
  return api;
}

const DEVICES = [
  { name: "Phone", platform: "ios", kind: "phone", paired: true, waiting: 2 },
  { name: "Studio", platform: "macos", kind: "computer", paired: true, waiting: 0 },
  { name: "Old PC", platform: "unknown", kind: "computer", paired: false, waiting: 0 },
];

test("initializes and lists the tools", async () => {
  const app = await fakeApp({ devices: DEVICES });
  const mcp = client(app.file);
  try {
    const init = await mcp.request("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "1" } });
    assert.equal(init.result.protocolVersion, "2025-06-18");
    assert.equal(init.result.serverInfo.name, "droprr");
    const tools = (await mcp.request("tools/list")).result.tools.map((t) => t.name);
    assert.deepEqual(tools, ["list_devices", "send_text", "send_files", "send_file_content"]);
    assert.equal((await mcp.request("nope")).error.code, -32601);
    // A byte-order mark before the first message (Windows PowerShell 5.1 pipes) is ignored.
    const bom = await new Promise((resolve) => {
      mcp.onRaw = resolve;
      mcp.raw("\uFEFF" + JSON.stringify({ jsonrpc: "2.0", id: 99, method: "ping" }) + "\n");
    });
    assert.deepEqual(bom.result, {});
  } finally {
    mcp.close();
    await app.close();
  }
});

test("lists devices and sends text, files, and content", async () => {
  const app = await fakeApp({ devices: DEVICES });
  const mcp = client(app.file);
  try {
    const list = await mcp.tool("list_devices", {});
    assert.match(list.content[0].text, /Phone \(ios, phone, queued until Droprr opens there; 2 waiting\)/);
    assert.match(list.content[0].text, /Old PC \(computer, sent to directly; not paired yet\)/);
    assert.equal(list.structuredContent.devices.length, 3);

    const text = await mcp.tool("send_text", { device: "phone", text: "https://example.com" });
    assert.equal(text.isError, undefined);
    assert.match(text.content[0].text, /^Queued for Phone/);

    const files = await mcp.tool("send_files", { device: "Studio", paths: [app.file] });
    assert.equal(files.content[0].text, "Sent to Studio over Wi-Fi.");

    const content = await mcp.tool("send_file_content", { device: "Phone", filename: "../list.md", text: "- milk" });
    assert.match(content.content[0].text, /^Queued for Phone/);

    assert.equal(app.sends.length, 3);
    assert.deepEqual(app.sends[0], { to: "phone", text: "https://example.com", contents: [] });
    assert.deepEqual(app.sends[1].files, [app.file]);
    assert.match(app.sends[2].files[0], /list\.md$/);
    assert.deepEqual(app.sends[2].contents, ["- milk"]);
  } finally {
    mcp.close();
    await app.close();
  }
});

test("says what's wrong instead of failing", async () => {
  const app = await fakeApp({ devices: DEVICES });
  const mcp = client(app.file);
  try {
    // Two paired devices: it has to be told which.
    const which = await mcp.tool("send_text", { text: "hi" });
    assert.equal(which.isError, true);
    assert.match(which.content[0].text, /Say which device to send to: Phone, Studio/);

    const unknown = await mcp.tool("send_text", { device: "Toaster", text: "hi" });
    assert.equal(unknown.isError, true);
    assert.match(unknown.content[0].text, /no device named "Toaster"/);

    const relative = await mcp.tool("send_files", { device: "Phone", paths: ["notes.txt"] });
    assert.match(relative.content[0].text, /Use absolute paths/);

    const both = await mcp.tool("send_file_content", { device: "Phone", filename: "a.txt", text: "a", base64: "YQ==" });
    assert.match(both.content[0].text, /either text or base64/);
  } finally {
    mcp.close();
    await app.close();
  }
});

test("picks the only paired device, and follows a restarted app's new token", async () => {
  const app = await fakeApp({ devices: [DEVICES[0], DEVICES[2]] });
  const mcp = client(app.file);
  try {
    // The app restarts: new token, new connection file. The next call just works.
    app.token = "fresh-token";
    await app.writeConnection();
    const sent = await mcp.tool("send_text", { text: "hello" });
    assert.match(sent.content[0].text, /^Queued for Phone/);
  } finally {
    mcp.close();
    await app.close();
  }
});

test("says Droprr isn't running when there's no app", async () => {
  const mcp = client(join(tmpdir(), "droprr-no-such-file.json"));
  try {
    const result = await mcp.tool("list_devices", {});
    assert.equal(result.isError, true);
    assert.match(result.content[0].text, /Droprr isn't running/);
  } finally {
    mcp.close();
  }
});
