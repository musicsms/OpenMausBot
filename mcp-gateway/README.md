# mcp-gateway (Phase-1 auth)

Loopback-only sidecar that exposes provider tools to OpenMausBot over MCP SSE.
Supports PAT accounts plus **Google OAuth** (consent + refresh), optional
AES-256-GCM auth-dir encryption, and a structured tool-error contract
(`auth_required`, rate-limit retries, Zod param validation).

## Requirements

- Node.js 24+
- A stable `GATEWAY_INTERNAL_KEY` (required; gateway refuses to start without it)
- For Google OAuth: `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`
- Optional: `AUTH_ENCRYPTION_KEY` (AES-256-GCM at rest). Set
  `AUTH_ENCRYPTION_REQUIRED=1` to refuse start when the key is missing.

## Quick start

```bash
# from repo root
pnpm install
export GATEWAY_INTERNAL_KEY="$(openssl rand -hex 24)"
export AUTH_DIR="$HOME/.mcp-gateway/auth"
# optional encryption:
# export AUTH_ENCRYPTION_KEY="$(openssl rand -hex 32)"
pnpm --filter mcp-gateway start
```

Endpoints (default `http://127.0.0.1:8318`):

| Path | Auth | Purpose |
| --- | --- | --- |
| `/healthz` | none | liveness |
| `/oauth/google/callback` | none (browser redirect) | Google OAuth callback for dashboard Connect |
| `/sse`, `/message` | `Authorization: Bearer <GATEWAY_INTERNAL_KEY>` | MCP SSE |
| `/`, `/api/*` | same bearer | admin dashboard + account / OAuth API |

Set `PUBLIC_BASE_URL` (e.g. `http://127.0.0.1:8318`) when the browser-reachable
origin differs from `HOST` (Docker / published port). Register that same origin
plus `/oauth/google/callback` as the Google Console redirect URI for dashboard
Connect. The CLI consent flow still uses an ephemeral loopback `/callback`.

Bind stays on loopback. Non-loopback `HOST` is rejected unless
`GATEWAY_ALLOW_NON_LOOPBACK=1` is set **and** `GATEWAY_INTERNAL_KEY` is present.

## Add credentials

### PAT / API key

```bash
pnpm --filter mcp-gateway cli -- auth github --alias work --pat ghp_xxx
```

### Google OAuth

```bash
export GOOGLE_CLIENT_ID=...
export GOOGLE_CLIENT_SECRET=...
pnpm --filter mcp-gateway cli -- auth google --alias work
```

The CLI starts a loopback callback with OAuth `state` + PKCE (S256), prints an
authorize URL, exchanges the code with `code_verifier`, and saves tokens under
`AUTH_DIR`. The dashboard “Connect Google” control uses
`POST /api/oauth/google/start` + status polling and completes on the gateway’s
published `/oauth/google/callback` (same `state` + PKCE).

Admin HTTP also accepts `POST /api/accounts` with a bearer, but responses never
echo `apiKey` or OAuth tokens — only metadata such as `hasApiKey` /
`tokenExpiresAt`.

Credentials live under `AUTH_DIR` as `0600` files. Without
`AUTH_ENCRYPTION_KEY` they are plaintext JSON (v1 posture). With the key set,
saves are AES-256-GCM; `init()` / `listAccounts()` migrates existing plaintext
files to encrypted form with an atomic replace. A wrong key surfaces
`unreadable` entries on `/api/accounts` and CLI `list` instead of silently
dropping accounts.

Google refresh tokens are refreshed in the background when a handler is
registered at bootstrap (Google is wired; missing handlers no-op safely).

## Connect OpenMausBot

Use the helper in `server/mcp-preset-gateway.ts`:

```ts
registerLocalGatewayPreset({}, "http://127.0.0.1:8318/sse", "unified-gateway", process.env.GATEWAY_INTERNAL_KEY);
```

That writes an SSE MCP entry with:

- `url: "http://127.0.0.1:8318/sse"`
- `headers.Authorization: "Bearer <key>"` (or `""` for vault resolution)
- `headerKeys: ["Authorization"]`

Prefer storing the key via the existing remote-MCP vault / `headerKeys` path
rather than a new Settings field.

## Docker Compose

```bash
export GATEWAY_INTERNAL_KEY="$(openssl rand -hex 24)"
docker compose -f mcp-gateway/docker-compose.yml up --build
```

Compose requires `GATEWAY_INTERNAL_KEY`, keeps `HOST=127.0.0.1`, and mounts the
auth-dir volume. The image installs with **pnpm** and the package lockfile.

## Tests

```bash
pnpm --filter mcp-gateway test
```

## Out of scope (later slices)

- Custom REST YAML load + SSRF controls
- OpenMausBot Settings 1-click UX
- Public / non-loopback production bind
