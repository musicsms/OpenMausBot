#!/usr/bin/env node
// Isolated allowlist smoke against fake-companion.ts (not the user's live app).
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const fixture = join(here, "fake-companion.ts");
const token = "omb_fixedtokenfixedtokenfixedtokenfixedto";

const child = spawn(
  process.execPath,
  ["--experimental-strip-types", fixture],
  {
    env: { ...process.env, PORT: "0", FAKE_TOKEN: token },
    stdio: ["ignore", "pipe", "inherit"],
  },
);

function fail(message) {
  console.error(message);
  child.kill();
  process.exit(1);
}

const rl = createInterface({ input: child.stdout });
const port = await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error("fixture start timeout")), 5000);
  rl.on("line", (line) => {
    const match = /http:\/\/127\.0\.0\.1:(\d+)/.exec(line);
    if (match) {
      clearTimeout(timer);
      resolve(Number(match[1]));
    }
  });
  child.on("exit", (code) => reject(new Error(`fixture exited ${code}`)));
});

const base = `http://127.0.0.1:${port}`;

async function req(method, path, { body, auth } = {}) {
  const res = await fetch(`${base}${path}`, {
    method,
    headers: {
      ...(body ? { "Content-Type": "application/json" } : {}),
      ...(auth ? { Authorization: `Bearer ${auth}` } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = text;
  }
  return { status: res.status, json, headers: res.headers };
}

const health = await req("GET", "/api/health");
if (health.status !== 200 || health.json?.app !== "openmausbot") {
  fail(`health failed: ${JSON.stringify(health)}`);
}

const healthz = await req("GET", "/healthz");
if (healthz.status !== 404) fail(`expected /healthz 404, got ${healthz.status}`);

const pair = await req("POST", "/api/pair", {
  body: { credential: "omb_pair_test", deviceName: "Verify Phone" },
});
if (pair.status !== 201 || typeof pair.json?.token !== "string" || !pair.json.token.startsWith("omb_")) {
  fail(`pair failed: ${JSON.stringify(pair)}`);
}
if ("deviceToken" in pair.json) fail("pair must not return deviceToken");

const eventsRes = await fetch(`${base}/api/events`, {
  headers: { Authorization: `Bearer ${token}`, Accept: "text/event-stream" },
});
if (eventsRes.status !== 200) fail(`events status ${eventsRes.status}`);
const eventText = await eventsRes.text();
if (!eventText.includes('"kind":"hello"') || !eventText.includes('"kind":"message"')) {
  fail(`events payload unexpected: ${eventText}`);
}

const send = await req("POST", `/api/bots/bot-main/messages`, {
  auth: token,
  body: { text: "hello from verify" },
});
if (send.status !== 202) fail(`send failed: ${JSON.stringify(send)}`);

const respond = await req("POST", `/api/bots/bot-main/respond`, {
  auth: token,
  body: { threadId: "thread-main", requestId: "req-1", behavior: "allow" },
});
if (respond.status !== 200) fail(`respond failed: ${JSON.stringify(respond)}`);

const legacySend = await req("POST", "/api/threads/default/messages", {
  auth: token,
  body: { content: "legacy" },
});
if (legacySend.status !== 404) fail(`legacy thread POST should 404, got ${legacySend.status}`);

console.log("fake companion allowlist OK");
child.kill();
process.exit(0);
