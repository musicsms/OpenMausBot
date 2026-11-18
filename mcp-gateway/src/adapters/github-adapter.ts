import type { GatewayToolDefinition, ServiceAdapter } from "./base-adapter.ts";
import type { ProviderType } from "../types.ts";
import { requireAccountToken, throwForUpstreamStatus } from "../errors.ts";
import { fetchWith429Retry, readRetryAfterSeconds } from "../http-retry.ts";
import {
  githubCreateIssueSchema,
  githubGetIssueSchema,
  githubListReposSchema,
  parseToolArgs,
} from "../tool-args.ts";

export class GitHubAdapter implements ServiceAdapter {
  readonly provider: ProviderType = "github";

  getTools(alias: string): GatewayToolDefinition[] {
    return [
      {
        name: `github__${alias}__list_repos`,
        description: `List repositories for GitHub account '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            visibility: { type: "string", enum: ["all", "public", "private"], default: "all" },
            perPage: { type: "number", description: "Number of repositories to return", default: 10 },
          },
        },
        execute: async (args, cred) => {
          const token = requireAccountToken(cred);
          const parsed = parseToolArgs(githubListReposSchema, args);

          const visibility = parsed.visibility ?? "all";
          const perPage = parsed.perPage && parsed.perPage > 0 ? parsed.perPage : 10;
          const params = new URLSearchParams({
            sort: "updated",
            per_page: String(perPage),
            visibility,
          });
          const url = `https://api.github.com/user/repos?${params.toString()}`;

          const res = await fetchWith429Retry(url, {
            headers: {
              Authorization: `Bearer ${token}`,
              "User-Agent": "OpenMausBot-Unified-Gateway",
              Accept: "application/vnd.github+json",
            },
          });

          if (!res.ok) {
            throwForUpstreamStatus(
              "github",
              alias,
              res.status,
              await res.text(),
              "GitHub",
              readRetryAfterSeconds(res),
            );
          }

          const repos = (await res.json()) as Array<{ full_name: string; html_url: string; private: boolean }>;
          return {
            text: JSON.stringify(
              repos.map((r) => ({
                name: r.full_name,
                url: r.html_url,
                private: r.private,
              })),
              null,
              2,
            ),
          };
        },
      },
      {
        name: `github__${alias}__get_issue`,
        description: `Get an issue from a GitHub repository for account '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            owner: { type: "string", description: "Repository owner (username or organization)" },
            repo: { type: "string", description: "Repository name" },
            issue_number: { type: "number", description: "Issue number" },
          },
          required: ["owner", "repo", "issue_number"],
        },
        execute: async (args, cred) => {
          const token = requireAccountToken(cred);
          const parsed = parseToolArgs(githubGetIssueSchema, args);

          const url = `https://api.github.com/repos/${encodeURIComponent(parsed.owner)}/${encodeURIComponent(parsed.repo)}/issues/${encodeURIComponent(String(parsed.issue_number))}`;

          const res = await fetchWith429Retry(url, {
            headers: {
              Authorization: `Bearer ${token}`,
              "User-Agent": "OpenMausBot-Unified-Gateway",
              Accept: "application/vnd.github+json",
            },
          });

          if (!res.ok) {
            throwForUpstreamStatus(
              "github",
              alias,
              res.status,
              await res.text(),
              "GitHub",
              readRetryAfterSeconds(res),
            );
          }

          const issue = (await res.json()) as {
            number: number;
            title: string;
            state: string;
            body?: string;
            html_url: string;
          };

          return {
            text: JSON.stringify(
              {
                number: issue.number,
                title: issue.title,
                state: issue.state,
                body: issue.body,
                html_url: issue.html_url,
              },
              null,
              2,
            ),
          };
        },
      },
      {
        name: `github__${alias}__create_issue`,
        description: `Create an issue in a GitHub repository for account '${alias}'`,
        parameters: {
          type: "object",
          properties: {
            owner: { type: "string", description: "Repository owner (username or organization)" },
            repo: { type: "string", description: "Repository name" },
            title: { type: "string", description: "Issue title" },
            body: { type: "string", description: "Issue markdown body" },
          },
          required: ["owner", "repo", "title"],
        },
        execute: async (args, cred) => {
          const token = requireAccountToken(cred);
          const parsed = parseToolArgs(githubCreateIssueSchema, args);

          const url = `https://api.github.com/repos/${encodeURIComponent(parsed.owner)}/${encodeURIComponent(parsed.repo)}/issues`;

          const res = await fetchWith429Retry(url, {
            method: "POST",
            headers: {
              Authorization: `Bearer ${token}`,
              "User-Agent": "OpenMausBot-Unified-Gateway",
              Accept: "application/vnd.github+json",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              title: parsed.title,
              ...(parsed.body !== undefined ? { body: parsed.body } : {}),
            }),
          });

          if (!res.ok) {
            throwForUpstreamStatus(
              "github",
              alias,
              res.status,
              await res.text(),
              "GitHub",
              readRetryAfterSeconds(res),
            );
          }

          const issue = (await res.json()) as { number: number; html_url: string; title: string };
          return { text: `Issue #${issue.number} created: ${issue.html_url}` };
        },
      },
    ];
  }
}
