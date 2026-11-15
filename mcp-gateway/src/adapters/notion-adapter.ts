import type { GatewayToolDefinition, ServiceAdapter } from "./base-adapter.ts";
import type { AccountCredential, ProviderType } from "../types.ts";

export class NotionAdapter implements ServiceAdapter {
  readonly provider: ProviderType = "notion";

  getTools(alias: string): GatewayToolDefinition[] {
    return [
      {
        name: `notion__${alias}__search`,
        description: `Search pages and databases in Notion workspace '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            query: { type: "string", description: "Search query string" },
          },
          required: ["query"],
        },
        execute: async (args, cred: AccountCredential) => {
          const token = cred.apiKey || cred.tokens?.accessToken;
          if (!token) throw new Error(`Missing token for account '${alias}'`);
          if (typeof args.query !== "string") {
            throw new Error("Missing required argument 'query'");
          }

          const res = await fetch("https://api.notion.com/v1/search", {
            method: "POST",
            headers: {
              Authorization: `Bearer ${token}`,
              "Notion-Version": "2022-06-28",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ query: args.query, page_size: 5 }),
          });

          if (!res.ok) {
            throw new Error(`Notion API error (${res.status}): ${await res.text()}`);
          }
          const result = (await res.json()) as { results?: unknown[] };
          return { text: JSON.stringify(result.results || [], null, 2) };
        },
      },
      {
        name: `notion__${alias}__query_database`,
        description: `Query a database in Notion workspace '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            database_id: { type: "string", description: "Database ID to query" },
            page_size: { type: "number", description: "Page size limit" },
          },
          required: ["database_id"],
        },
        execute: async (args, cred: AccountCredential) => {
          const token = cred.apiKey || cred.tokens?.accessToken;
          if (!token) throw new Error(`Missing token for account '${alias}'`);
          if (!args.database_id || typeof args.database_id !== "string") {
            throw new Error("Missing required argument 'database_id'");
          }

          const payload: Record<string, unknown> = {
            page_size: typeof args.page_size === "number" ? args.page_size : 10,
          };
          if (args.filter && typeof args.filter === "object") {
            payload.filter = args.filter;
          }

          const res = await fetch(
            `https://api.notion.com/v1/databases/${encodeURIComponent(args.database_id)}/query`,
            {
              method: "POST",
              headers: {
                Authorization: `Bearer ${token}`,
                "Notion-Version": "2022-06-28",
                "Content-Type": "application/json",
              },
              body: JSON.stringify(payload),
            },
          );

          if (!res.ok) {
            throw new Error(`Notion API error (${res.status}): ${await res.text()}`);
          }
          const result = (await res.json()) as { results?: unknown[] };
          return { text: JSON.stringify(result.results || [], null, 2) };
        },
      },
    ];
  }
}
