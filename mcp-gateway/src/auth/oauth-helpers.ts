import { createServer, type Server } from "node:http";
import { escapeHtml } from "../server/web-panel.ts";

export interface CallbackServer {
  port: number;
  waitForCode: () => Promise<string>;
  close: () => Promise<void>;
}

export function createLocalOAuthCallbackServer(preferredPort = 0): Promise<CallbackServer> {
  return new Promise((resolve, reject) => {
    let capturedCodePromiseResolve: (code: string) => void;
    let capturedCodePromiseReject: (err: Error) => void;
    let settled = false;

    const codePromise = new Promise<string>((res, rej) => {
      capturedCodePromiseResolve = (code) => {
        if (!settled) {
          settled = true;
          res(code);
        }
      };
      capturedCodePromiseReject = (err) => {
        if (!settled) {
          settled = true;
          rej(err);
        }
      };
    });
    codePromise.catch(() => {});

    const server: Server = createServer((req, res) => {
      const host = req.headers.host || "127.0.0.1";
      const url = new URL(req.url || "/", `http://${host}`);
      if (url.pathname === "/callback") {
        const error = url.searchParams.get("error");
        if (error) {
          const errorDesc = url.searchParams.get("error_description") || error;
          res.writeHead(400, { "Content-Type": "text/html; charset=utf-8" });
          res.end(`<h1>Authentication Failed</h1><p>${escapeHtml(errorDesc)}</p>`);
          capturedCodePromiseReject(new Error(errorDesc));
          return;
        }

        const code = url.searchParams.get("code");
        if (code) {
          res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
          res.end("<h1>Authentication Successful!</h1><p>You can close this window and return to your terminal.</p>");
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
            if (!settled) {
              capturedCodePromiseReject(new Error("Server closed before authorization completed"));
            }
            server.close(() => done());
          }),
      });
    });

    server.on("error", reject);
  });
}
