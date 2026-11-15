import type { GatewayToolDefinition, ServiceAdapter } from "./base-adapter.ts";
import type { ProviderType } from "../types.ts";

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
          const token = cred.apiKey || cred.tokens?.accessToken;
          if (!token) throw new Error(`Missing token for account '${alias}'`);

          const visibility = typeof args.visibility === "string" ? args.visibility : "all";
          const perPage = typeof args.perPage === "number" && args.perPage > 0 ? args.perPage : 10;
          const params = new URLSearchParams({
            sort: "updated",
            per_page: String(perPage),
            visibility,
          });
          const url = `https://api.github.com/user/repos?${params.toString()}`;

          const res = await fetch(url, {
            headers: {
              Authorization: `Bearer ${token}`,
              "User-Agent": "OpenMausBot-Unified-Gateway",
              Accept: "application/vnd.github+json",
            },
          });

          if (!res.ok) {
            throw new Error(`GitHub API error (${res.status}): ${await res.text()}`);
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
          const token = cred.apiKey || cred.tokens?.accessToken;
          if (!token) throw new Error(`Missing token for account '${alias}'`);
          if (!args.owner || typeof args.owner !== "string") throw new Error("Missing required argument 'owner'");
          if (!args.repo || typeof args.repo !== "string") throw new Error("Missing required argument 'repo'");
          if (args.issue_number === undefined || typeof args.issue_number !== "number") {
            throw new Error("Missing required argument 'issue_number'");
          }

          const url = `https://api.github.com/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/issues/${encodeURIComponent(String(args.issue_number))}`;

          const res = await fetch(url, {
            headers: {
              Authorization: `Bearer ${token}`,
              "User-Agent": "OpenMausBot-Unified-Gateway",
              Accept: "application/vnd.github+json",
            },
          });

          if (!res.ok) {
            throw new Error(`GitHub API error (${res.status}): ${await res.text()}`);
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
          const token = cred.apiKey || cred.tokens?.accessToken;
          if (!token) throw new Error(`Missing token for account '${alias}'`);
          if (!args.owner || typeof args.owner !== "string") throw new Error("Missing required argument 'owner'");
          if (!args.repo || typeof args.repo !== "string") throw new Error("Missing required argument 'repo'");
          if (!args.title || typeof args.title !== "string") throw new Error("Missing required argument 'title'");

          const url = `https://api.github.com/repos/${encodeURIComponent(args.owner)}/${encodeURIComponent(args.repo)}/issues`;

          const res = await fetch(url, {
            method: "POST",
            headers: {
              Authorization: `Bearer ${token}`,
              "User-Agent": "OpenMausBot-Unified-Gateway",
              Accept: "application/vnd.github+json",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              title: args.title,
              ...(typeof args.body === "string" ? { body: args.body } : {}),
            }),
          });

          if (!res.ok) {
            throw new Error(`GitHub API error (${res.status}): ${await res.text()}`);
          }

          const issue = (await res.json()) as { number: number; html_url: string; title: string };
          return { text: `Issue #${issue.number} created: ${issue.html_url}` };
        },
      },
    ];
  }
}
