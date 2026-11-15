import type { GatewayToolDefinition, ServiceAdapter } from "./base-adapter.ts";
import type { AccountCredential, ProviderType } from "../types.ts";

export class SlackAdapter implements ServiceAdapter {
  readonly provider: ProviderType = "slack";

  getTools(alias: string): GatewayToolDefinition[] {
    return [
      {
        name: `slack__${alias}__post_message`,
        description: `Post a message to a Slack channel using account '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            channel: { type: "string", description: "Channel ID or channel name with #" },
            text: { type: "string", description: "Message text" },
          },
          required: ["channel", "text"],
        },
        execute: async (args, cred: AccountCredential) => {
          const token = cred.apiKey || cred.tokens?.accessToken;
          if (!token) throw new Error(`Missing token for account '${alias}'`);
          if (!args.channel || typeof args.channel !== "string") {
            throw new Error("Missing required argument 'channel'");
          }
          if (typeof args.text !== "string") {
            throw new Error("Missing required argument 'text'");
          }

          const res = await fetch("https://slack.com/api/chat.postMessage", {
            method: "POST",
            headers: {
              Authorization: `Bearer ${token}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ channel: args.channel, text: args.text }),
          });

          if (!res.ok) {
            throw new Error(`Slack API error (${res.status}): ${await res.text()}`);
          }
          const result = (await res.json()) as { ok?: boolean; error?: string };
          if (!result.ok) {
            throw new Error(`Slack API error: ${result.error}`);
          }
          return { text: `Message posted successfully to channel ${args.channel}` };
        },
      },
      {
        name: `slack__${alias}__list_channels`,
        description: `List public channels for Slack workspace '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            types: { type: "string", description: "Channel types to list (default: public_channel)" },
          },
        },
        execute: async (args, cred: AccountCredential) => {
          const token = cred.apiKey || cred.tokens?.accessToken;
          if (!token) throw new Error(`Missing token for account '${alias}'`);

          const types = typeof args.types === "string" ? args.types : "public_channel";
          const res = await fetch(`https://slack.com/api/conversations.list?types=${encodeURIComponent(types)}`, {
            headers: { Authorization: `Bearer ${token}` },
          });

          if (!res.ok) {
            throw new Error(`Slack API error (${res.status}): ${await res.text()}`);
          }
          const result = (await res.json()) as {
            ok?: boolean;
            error?: string;
            channels?: Array<{ id: string; name: string }>;
          };
          if (!result.ok) {
            throw new Error(`Slack API error: ${result.error}`);
          }
          const channels = result.channels || [];
          return {
            text: JSON.stringify(
              channels.map((c) => ({ id: c.id, name: c.name })),
              null,
              2,
            ),
          };
        },
      },
    ];
  }
}
