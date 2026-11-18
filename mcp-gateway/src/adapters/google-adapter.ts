import type { GatewayToolDefinition, ServiceAdapter } from "./base-adapter.ts";
import type { ProviderType } from "../types.ts";
import { requireAccountToken, throwForUpstreamStatus } from "../errors.ts";
import { fetchWith429Retry, readRetryAfterSeconds } from "../http-retry.ts";
import {
  calendarListSchema,
  driveSearchSchema,
  gmailSearchSchema,
  gmailSendSchema,
  parseToolArgs,
} from "../tool-args.ts";

export class GoogleAdapter implements ServiceAdapter {
  readonly provider: ProviderType = "google";

  getTools(alias: string): GatewayToolDefinition[] {
    return [
      {
        name: `google__${alias}__gmail_send_mail`,
        description: `Send an email from Google Workspace account '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            to: { type: "string", description: "Recipient email address" },
            subject: { type: "string", description: "Subject of the email" },
            body: { type: "string", description: "Plain text or HTML body" },
          },
          required: ["to", "subject", "body"],
        },
        execute: async (args, cred) => {
          const token = requireAccountToken(cred, "oauth");
          const parsed = parseToolArgs(gmailSendSchema, args);

          const to = parsed.to.replace(/[\r\n]/g, "");
          const subject = parsed.subject.replace(/[\r\n]/g, "");
          const rawMessage = Buffer.from(
            `To: ${to}\r\nSubject: ${subject}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n${parsed.body}`,
          ).toString("base64url");

          const res = await fetchWith429Retry("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {
            method: "POST",
            headers: {
              Authorization: `Bearer ${token}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ raw: rawMessage }),
          });

          if (!res.ok) {
            throwForUpstreamStatus(
              "google",
              alias,
              res.status,
              await res.text(),
              "Gmail",
              readRetryAfterSeconds(res),
            );
          }
          const result = (await res.json()) as { id?: string };
          return { text: `Email sent successfully (id: ${result.id})` };
        },
      },
      {
        name: `google__${alias}__gmail_search`,
        description: `Search emails in Google Workspace account '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            query: { type: "string", description: "Search query string (e.g., 'from:user@example.com', 'is:unread')" },
            maxResults: { type: "number", description: "Maximum messages to return", default: 10 },
          },
          required: ["query"],
        },
        execute: async (args, cred) => {
          const token = requireAccountToken(cred, "oauth");
          const parsed = parseToolArgs(gmailSearchSchema, args);

          const maxResults = parsed.maxResults && parsed.maxResults > 0 ? parsed.maxResults : 10;
          const params = new URLSearchParams({
            q: parsed.query,
            maxResults: String(maxResults),
          });
          const url = `https://gmail.googleapis.com/gmail/v1/users/me/messages?${params.toString()}`;
          const res = await fetchWith429Retry(url, {
            headers: { Authorization: `Bearer ${token}` },
          });

          if (!res.ok) {
            throwForUpstreamStatus(
              "google",
              alias,
              res.status,
              await res.text(),
              "Gmail",
              readRetryAfterSeconds(res),
            );
          }
          const data = (await res.json()) as { messages?: unknown[] };
          return { text: JSON.stringify(data.messages || [], null, 2) };
        },
      },
      {
        name: `google__${alias}__calendar_list_events`,
        description: `List upcoming calendar events for Google Workspace account '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            maxResults: { type: "number", description: "Maximum events to return", default: 10 },
          },
        },
        execute: async (args, cred) => {
          const token = requireAccountToken(cred, "oauth");
          const parsed = parseToolArgs(calendarListSchema, args);
          const maxResults = parsed.maxResults && parsed.maxResults > 0 ? parsed.maxResults : 10;
          const params = new URLSearchParams({
            maxResults: String(maxResults),
            orderBy: "startTime",
            singleEvents: "true",
            timeMin: new Date().toISOString(),
          });
          const url = `https://www.googleapis.com/calendar/v3/calendars/primary/events?${params.toString()}`;
          const res = await fetchWith429Retry(url, {
            headers: { Authorization: `Bearer ${token}` },
          });

          if (!res.ok) {
            throwForUpstreamStatus(
              "google",
              alias,
              res.status,
              await res.text(),
              "Calendar",
              readRetryAfterSeconds(res),
            );
          }
          const data = (await res.json()) as { items?: unknown[] };
          return { text: JSON.stringify(data.items || [], null, 2) };
        },
      },
      {
        name: `google__${alias}__drive_search_files`,
        description: `Search files in Google Drive for account '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            query: { type: "string", description: "Drive search query (e.g. name contains 'report')", default: "" },
            pageSize: { type: "number", description: "Maximum files to return", default: 10 },
          },
        },
        execute: async (args, cred) => {
          const token = requireAccountToken(cred, "oauth");
          const parsed = parseToolArgs(driveSearchSchema, args);
          const pageSize = parsed.pageSize && parsed.pageSize > 0 ? parsed.pageSize : 10;
          const params = new URLSearchParams({
            pageSize: String(pageSize),
            fields: "files(id,name,mimeType,modifiedTime,webViewLink)",
          });
          if (parsed.query) {
            params.set("q", parsed.query);
          }
          const url = `https://www.googleapis.com/drive/v3/files?${params.toString()}`;
          const res = await fetchWith429Retry(url, {
            headers: { Authorization: `Bearer ${token}` },
          });

          if (!res.ok) {
            throwForUpstreamStatus(
              "google",
              alias,
              res.status,
              await res.text(),
              "Drive",
              readRetryAfterSeconds(res),
            );
          }
          const data = (await res.json()) as { files?: unknown[] };
          return { text: JSON.stringify(data.files || [], null, 2) };
        },
      },
    ];
  }
}
