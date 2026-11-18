# mcp-gateway (PAT / local-dev MVP)

Loopback-only sidecar that exposes provider tools to OpenMausBot over MCP SSE.
This slice is a **local PAT gateway with bearer-gated SSE** — not a complete
multi-account OAuth product. OAuth consent UI, live token refresh registration,
and AES-at-rest wiring are deferred.

## Requirements

- Node.js 24+
- A stable `GATEWAY_INTERNAL_KEY` (required; gateway refuses to start without it)

## Quick start

```bash
# from repo root
pnpm install
export GATEWAY_INTERNAL_KEY="$(openssl rand -hex 24)"
export AUTH_DIR="$HOME/.mcp-gateway/auth"
pnpm --filter mcp-gateway start
```

Endpoints (default `http://127.0.0.1:8318`):

| Path | Auth | Purpose |
| --- | --- | --- |
| `/healthz` | none | liveness |
| `/sse`, `/message` | `Authorization: Bearer <GATEWAY_INTERNAL_KEY>` | MCP SSE |
| `/`, `/api/*` | same bearer | admin dashboard + account API |

Bind stays on loopback. Non-loopback `HOST` is rejected unless
`GATEWAY_ALLOW_NON_LOOPBACK=1` is set **and** `GATEWAY_INTERNAL_KEY` is present.

## Add a PAT

```bash
pnpm --filter mcp-gateway cli -- auth github --alias work --pat ghp_xxx
```

Admin HTTP also accepts `POST /api/accounts` with a bearer, but responses never
echo `apiKey` or OAuth tokens — only metadata such as `hasApiKey` /
`tokenExpiresAt`.

Credentials live under `AUTH_DIR` as `0600` JSON files (plaintext v1 posture).

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

- Live OAuth start / callback / token exchange in CLI or dashboard
- Registered provider refresh handlers at bootstrap
- AES-GCM encryption for auth-dir
- Custom REST YAML load + SSRF controls
- OpenMausBot Settings 1-click UX
