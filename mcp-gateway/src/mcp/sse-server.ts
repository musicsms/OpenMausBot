import { createServer, type IncomingMessage, type Server as HttpServer, type ServerResponse } from "node:http";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import type { GatewayConfig } from "../types.ts";
import type { AuthStore } from "../storage/auth-store.ts";
import type { McpRouter } from "./router.ts";
import { handleAdminRequest } from "../server/admin-routes.ts";
import { requireBearerAuth } from "../server/auth.ts";
import { GatewayToolError } from "../errors.ts";
import type { OAuthSessionManager } from "../auth/oauth-sessions.ts";

function createMcpServer(store: AuthStore, router: McpRouter): Server {
  const mcpServer = new Server(
    { name: "openmausbot-unified-gateway", version: "0.1.0" },
    { capabilities: { tools: {} } },
  );

  mcpServer.setRequestHandler(ListToolsRequestSchema, async () => {
    const accounts = await store.listAccounts();
    const tools = router.collectTools(accounts);
    return {
      tools: tools.map((t) => ({
        name: t.name,
        description: t.description,
        inputSchema: t.parameters,
      })),
    };
  });

  mcpServer.setRequestHandler(CallToolRequestSchema, async (request) => {
    const accounts = await store.listAccounts();
    try {
      const result = await router.executeTool(
        request.params.name,
        (request.params.arguments as Record<string, unknown>) || {},
        accounts,
      );
      return {
        content: [{ type: "text", text: result.text }],
      };
    } catch (err) {
      if (err instanceof GatewayToolError) {
        return {
          isError: true,
          content: [{ type: "text", text: JSON.stringify(err.toPublicPayload()) }],
        };
      }
      const message = err instanceof Error ? err.message : String(err);
      return {
        isError: true,
        content: [{ type: "text", text: message }],
      };
    }
  });

  return mcpServer;
}

export function createGatewayServer(
  config: GatewayConfig,
  store: AuthStore,
  router: McpRouter,
  options?: { oauthSessions?: OAuthSessionManager },
): HttpServer {
  const transports = new Map<string, SSEServerTransport>();

  const httpServer = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const host = req.headers.host || `${config.host}:${config.port}`;
    const url = new URL(req.url || "/", `http://${host}`);

    if (url.pathname === "/healthz") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok" }));
      return;
    }

    if (!requireBearerAuth(req, res, config.internalKey)) {
      return;
    }

    if (url.pathname === "/sse") {
      if (req.method !== "GET") {
        res.writeHead(405, { "Content-Type": "application/json", Allow: "GET" });
        res.end(JSON.stringify({ error: "Method not allowed" }));
        return;
      }
      const mcpServer = createMcpServer(store, router);
      const transport = new SSEServerTransport("/message", res);
      const sessionId = transport.sessionId;
      transports.set(sessionId, transport);

      transport.onclose = () => {
        transports.delete(sessionId);
      };

      await mcpServer.connect(transport);
      return;
    }

    if (url.pathname === "/message") {
      if (req.method !== "POST") {
        res.writeHead(405, { "Content-Type": "application/json", Allow: "POST" });
        res.end(JSON.stringify({ error: "Method not allowed" }));
        return;
      }
      const sessionId = url.searchParams.get("sessionId");
      if (!sessionId) {
        res.writeHead(400, { "Content-Type": "text/plain" });
        res.end("Missing sessionId");
        return;
      }
      const transport = transports.get(sessionId);
      if (transport) {
        await transport.handlePostMessage(req, res);
      } else {
        res.writeHead(400).end("No active SSE transport connection");
      }
      return;
    }

    try {
      const handled = await handleAdminRequest(req, res, store, {
        webPanelEnabled: config.webPanelEnabled,
        internalKey: config.internalKey,
        skipAuth: true,
        oauthSessions: options?.oauthSessions,
      });
      if (handled) {
        return;
      }
    } catch (err) {
      if (!res.headersSent) {
        res.writeHead(500, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: err instanceof Error ? err.message : "Internal server error" }));
      }
      return;
    }

    res.writeHead(404).end("Not found");
  });

  httpServer.on("close", () => {
    for (const transport of transports.values()) {
      transport.close().catch(() => {});
    }
    transports.clear();
  });

  return httpServer;
}
