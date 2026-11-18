import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { randomBytes } from "node:crypto";

const DEVICE_TOKEN = `omb_${randomBytes(32).toString("base64url")}`;
const BOT_ID = "bot-main";
const THREAD_ID = "thread-main";

function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
    req.on("end", () => {
      try {
        const raw = Buffer.concat(chunks).toString("utf8") || "{}";
        resolve(JSON.parse(raw) as Record<string, unknown>);
      } catch (error) {
        reject(error);
      }
    });
    req.on("error", reject);
  });
}

function sendJson(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

export function createFakeCompanionServer(options?: { token?: string }) {
  const token = options?.token ?? DEVICE_TOKEN;

  const requireBearer = (req: IncomingMessage, res: ServerResponse): boolean => {
    const auth = req.headers.authorization ?? "";
    if (auth !== `Bearer ${token}`) {
      sendJson(res, 401, {
        error: "pair this device from Remote access settings on the host computer",
      });
      return false;
    }
    return true;
  };

  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url || "/", `http://${req.headers.host}`);
    const method = req.method ?? "GET";
    const path = url.pathname;

    void (async () => {
      if (method === "GET" && path === "/api/health") {
        return sendJson(res, 200, { app: "openmausbot" });
      }

      if (method === "POST" && path === "/api/pair") {
        const body = await readJson(req);
        const credential = body.credential ?? body.code;
        if (typeof credential !== "string" || typeof body.deviceName !== "string") {
          return sendJson(res, 400, { error: "invalid pairing request" });
        }
        return sendJson(res, 201, {
          token,
          device: {
            id: "device-1",
            name: body.deviceName,
            createdAt: Date.now(),
            lastSeenAt: Date.now(),
            cloudDesktopAccess: false,
            browserControlAccess: false,
            routes: "any",
          },
          serverName: "Studio",
          endpoints: [
            { url: `http://${req.headers.host}`, kind: "lan", priority: 200 },
          ],
        });
      }

      if (method === "GET" && path === "/api/companion/endpoints") {
        if (!requireBearer(req, res)) return;
        return sendJson(res, 200, {
          serverName: "Studio",
          endpoints: [{ url: `http://${req.headers.host}`, kind: "lan", priority: 200 }],
        });
      }

      if (method === "GET" && path === "/api/bots") {
        if (!requireBearer(req, res)) return;
        return sendJson(res, 200, [
          { id: BOT_ID, name: "Main", threadId: THREAD_ID },
        ]);
      }

      if (method === "GET" && path === "/api/events") {
        if (!requireBearer(req, res)) return;
        res.writeHead(200, {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
        });
        res.write(`data: ${JSON.stringify({ kind: "hello", cursor: "abcd1234:0", resumed: false })}\n\n`);
        res.write(
          `id: abcd1234:1\ndata: ${JSON.stringify({
            kind: "message",
            threadId: THREAD_ID,
            seq: 1,
            message: {
              id: "m1",
              role: "bot",
              kind: "text",
              text: "Xin chào! Tôi là OpenMausBot trên mobile.",
              botId: BOT_ID,
            },
          })}\n\n`,
        );
        res.write(
          `id: abcd1234:2\ndata: ${JSON.stringify({
            kind: "message",
            threadId: THREAD_ID,
            seq: 2,
            message: {
              id: "m2",
              role: "bot",
              kind: "options",
              text: "Run a command?",
              botId: BOT_ID,
              card: {
                title: "Run a command?",
                subtitle: "ls -la",
                options: ["Allow", "Deny"],
                requestId: "req-1",
                tool: "Bash",
                requestType: "permission",
              },
            },
          })}\n\n`,
        );
        setTimeout(() => res.end(), 50);
        return;
      }

      const botMessage = /^\/api\/bots\/([\w-]+)\/messages$/.exec(path);
      if (method === "POST" && botMessage) {
        if (!requireBearer(req, res)) return;
        const body = await readJson(req);
        if (typeof body.text !== "string" || !body.text.trim()) {
          return sendJson(res, 400, { error: "text required" });
        }
        return sendJson(res, 202, { ok: true, threadId: THREAD_ID });
      }

      const respond = /^\/api\/bots\/([\w-]+)\/respond$/.exec(path);
      if (method === "POST" && respond) {
        if (!requireBearer(req, res)) return;
        const body = await readJson(req);
        if (
          typeof body.threadId !== "string" ||
          typeof body.requestId !== "string" ||
          typeof body.behavior !== "string"
        ) {
          return sendJson(res, 400, { error: "invalid respond body" });
        }
        return sendJson(res, 200, { ok: true, outcome: body.behavior });
      }

      const cardPatch = /^\/api\/bots\/([\w-]+)\/cards\/([\w-]+)$/.exec(path);
      if (method === "PATCH" && cardPatch) {
        if (!requireBearer(req, res)) return;
        const body = await readJson(req);
        if (typeof body.answered !== "string" || typeof body.threadId !== "string") {
          return sendJson(res, 400, { error: "invalid card patch" });
        }
        return sendJson(res, 200, { ok: true });
      }

      // Match companion default-deny: inventing /healthz or thread POST must 404.
      return sendJson(res, 404, { error: `no route: ${method} ${path}` });
    })().catch((error: unknown) => {
      console.error("fake companion error", error);
      if (!res.headersSent) sendJson(res, 500, { error: "internal error" });
    });
  });

  return Object.assign(server, { token, botId: BOT_ID, threadId: THREAD_ID });
}

if (process.argv[1]?.endsWith("fake-companion.ts")) {
  const port = process.env.PORT ? parseInt(process.env.PORT, 10) : 8810;
  const fixedToken = process.env.FAKE_TOKEN;
  const server = createFakeCompanionServer(fixedToken ? { token: fixedToken } : undefined);
  server.listen(port, "127.0.0.1", () => {
    const addr = server.address();
    const resolvedPort = typeof addr === "object" && addr ? addr.port : port;
    console.log(`Fake companion listening on http://127.0.0.1:${resolvedPort}`);
    console.log(`Fake companion token ${server.token}`);
  });
}
