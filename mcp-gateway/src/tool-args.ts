import { z } from "zod";
import { GatewayToolError } from "./errors.ts";

export function parseToolArgs<T>(schema: z.ZodType<T>, args: Record<string, unknown>): T {
  const parsed = schema.safeParse(args);
  if (!parsed.success) {
    const message = parsed.error.issues
      .map((issue) => {
        const path = issue.path.length > 0 ? issue.path.join(".") : "args";
        return `${path}: ${issue.message}`;
      })
      .join("; ");
    throw new GatewayToolError(message, "invalid_params");
  }
  return parsed.data;
}

export const gmailSendSchema = z.object({
  to: z.string().min(1, "Missing required argument 'to'"),
  subject: z.string(),
  body: z.string(),
});

export const gmailSearchSchema = z.object({
  query: z.string().min(1, "Missing required argument 'query'"),
  maxResults: z.number().positive().optional(),
});

export const calendarListSchema = z.object({
  maxResults: z.number().positive().optional(),
});

export const driveSearchSchema = z.object({
  query: z.string().optional(),
  pageSize: z.number().positive().optional(),
});

export const githubListReposSchema = z.object({
  visibility: z.enum(["all", "public", "private"]).optional(),
  perPage: z.number().positive().optional(),
});

export const githubGetIssueSchema = z.object({
  owner: z.string().min(1, "Missing required argument 'owner'"),
  repo: z.string().min(1, "Missing required argument 'repo'"),
  issue_number: z.union([z.number(), z.string()]).transform((value, ctx) => {
    const num = typeof value === "string" ? Number.parseInt(value, 10) : value;
    if (typeof num !== "number" || Number.isNaN(num)) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: "Missing required argument 'issue_number'" });
      return z.NEVER;
    }
    return num;
  }),
});

export const githubCreateIssueSchema = z.object({
  owner: z.string().min(1, "Missing required argument 'owner'"),
  repo: z.string().min(1, "Missing required argument 'repo'"),
  title: z.string().min(1, "Missing required argument 'title'"),
  body: z.string().optional(),
});

export const slackPostMessageSchema = z.object({
  channel: z.string().min(1, "Missing required argument 'channel'"),
  text: z.string(),
});

export const notionSearchSchema = z.object({
  query: z.string(),
});
