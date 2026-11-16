import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

export function createFakeCompanionServer() {
  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url || "/", `http://${req.headers.host}`);

    if (url.pathname === "/healthz") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok" }));
      return;
    }

    if (url.pathname === "/api/pair" && req.method === "POST") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ deviceToken: "mock-device-token-12345" }));
      return;
    }

    if (url.pathname.startsWith("/api/threads/") && url.pathname.endsWith("/messages")) {
      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      });
      res.write("data: Xin chào! Tôi là OpenMausBot trên mobile.\n\n");
      res.write("data: Đang chuẩn bị thực hiện task...\n\n");
      setTimeout(() => res.end(), 100);
      return;
    }

    if (url.pathname.includes("/cards/") || url.pathname.includes("/approvals")) {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "approved" }));
      return;
    }

    res.writeHead(404).end("Not found");
  });

  return server;
}

if (process.argv[1]?.endsWith("fake-companion.ts")) {
  const port = process.env.PORT ? parseInt(process.env.PORT, 10) : 8810;
  const server = createFakeCompanionServer();
  server.listen(port, "127.0.0.1", () => {
    const addr = server.address();
    const resolvedPort = typeof addr === "object" && addr ? addr.port : port;
    console.log(`Fake companion listening on http://127.0.0.1:${resolvedPort}`);
  });
}
