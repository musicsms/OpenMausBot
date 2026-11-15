import { createServer, type Server } from "node:http";

export interface CallbackServer {
  port: number;
  waitForCode: () => Promise<string>;
  close: () => Promise<void>;
}

export function createLocalOAuthCallbackServer(preferredPort = 0): Promise<CallbackServer> {
  return new Promise((resolve, reject) => {
    let capturedCodePromiseResolve: (code: string) => void;
    let capturedCodePromiseReject: (err: Error) => void;

    const codePromise = new Promise<string>((res, rej) => {
      capturedCodePromiseResolve = res;
      capturedCodePromiseReject = rej;
    });

    const server: Server = createServer((req, res) => {
      const url = new URL(req.url || "/", `http://${req.headers.host}`);
      if (url.pathname === "/callback") {
        const code = url.searchParams.get("code");
        if (code) {
          res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
          res.end("<h1>Xác thực thành công!</h1><p>Bạn có thể đóng cửa sổ này và quay lại terminal.</p>");
          capturedCodePromiseResolve(code);
          return;
        }
      }
      res.writeHead(400, { "Content-Type": "text/plain" });
      res.end("Missing auth code");
    });

    server.listen(preferredPort, "127.0.0.1", () => {
      const addr = server.address();
      const port = typeof addr === "object" && addr ? addr.port : preferredPort;
      resolve({
        port,
        waitForCode: () => codePromise,
        close: () =>
          new Promise<void>((done) => {
            server.close(() => done());
          }),
      });
    });

    server.on("error", reject);
  });
}
