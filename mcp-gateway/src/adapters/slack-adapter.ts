import type { GatewayToolDefinition, ServiceAdapter } from "./base-adapter.ts";
import type { AccountCredential, ProviderType } from "../types.ts";
import { GatewayToolError, requireAccountToken, throwForUpstreamStatus } from "../errors.ts";
import { fetchWith429Retry, readRetryAfterSeconds } from "../http-retry.ts";
import { parseToolArgs, slackPostMessageSchema } from "../tool-args.ts";

function throwForSlackApiError(alias: string, error: string | undefined): never {
  const code = error || "unknown_error";
  if (code === "invalid_auth" || code === "not_authed" || code === "token_expired" || code === "account_inactive") {
    throw new GatewayToolError(
      `Token for 'slack:${alias}' was rejected by Slack (${code}). Re-authenticate via CLI or the gateway dashboard.`,
      "auth_required",
      { provider: "slack", alias },
    );
  }
  throw new GatewayToolError(`Slack API error: ${code}`, "upstream_error", { provider: "slack", alias });
}

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
          const token = requireAccountToken(cred);
          const parsed = parseToolArgs(slackPostMessageSchema, args);

          const res = await fetchWith429Retry("https://slack.com/api/chat.postMessage", {
            method: "POST",
            headers: {
              Authorization: `Bearer ${token}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ channel: parsed.channel, text: parsed.text }),
          });

          if (!res.ok) {
            throwForUpstreamStatus(
              "slack",
              alias,
              res.status,
              await res.text(),
              "Slack",
              readRetryAfterSeconds(res),
            );
          }
          const result = (await res.json()) as { ok?: boolean; error?: string };
          if (!result.ok) {
            throwForSlackApiError(alias, result.error);
          }
          return { text: `Message posted successfully to channel ${parsed.channel}` };
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
          const token = requireAccountToken(cred);

          const types = typeof args.types === "string" ? args.types : "public_channel";
          const res = await fetchWith429Retry(
            `https://slack.com/api/conversations.list?types=${encodeURIComponent(types)}`,
            {
              headers: { Authorization: `Bearer ${token}` },
            },
          );

          if (!res.ok) {
            throwForUpstreamStatus(
              "slack",
              alias,
              res.status,
              await res.text(),
              "Slack",
              readRetryAfterSeconds(res),
            );
          }
          const result = (await res.json()) as {
            ok?: boolean;
            error?: string;
            channels?: Array<{ id: string; name: string }>;
          };
          if (!result.ok) {
            throwForSlackApiError(alias, result.error);
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
