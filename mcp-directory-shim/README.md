# GrowthKit Directory Shim

> Try GrowthKit **without a key** — this thin proxy MCP server defaults to the
> GrowthKit demo workspace (fictional "ScaleUp Metrics GmbH", read-only: GTM
> memory + a seeded campaign with scored leads). Bring your own `gk_` token to
> work with your real workspace.

A containerized proxy in front of the real GrowthKit MCP server
(`https://mcp.growthkit.tools`), built for MCP directory listings
(Smithery, Glama): one-click testable in a playground, no OAuth screen, no
signup, no secrets anywhere in this package.

```
Directory gateway / MCP client  →  [shim]  →  mcp.growthkit.tools
                                    proxy +      (demo enforcement lives here:
                                    token mint    is_demo session, read-only
                                                  allowlist, rate limit)
```

## How it works

- **No config →** the shim runs the GrowthKit OAuth demo flow (`demo=1`)
  programmatically and caches the resulting `is_demo` access token. All demo
  safety is enforced **server-side** by the GrowthKit Worker (read-only tool
  allowlist, per-IP rate limit, simulated writes) — the shim only selects the
  token, and additionally curates `tools/list` to the read tools that return
  real data on a DIRECT call (memory suite + campaign/lead reads — mirrored
  from the llm-router demo suffix's allowed-reads list).
- **With `gkToken` config →** the same OAuth flow runs with your `gk_` token;
  you get the full tool set for your token's role, real workspace data, no
  demo filtering.
- `tools/call` responses are passed through verbatim; upstream errors are
  returned as clean MCP `isError` results (no stack traces, no token leakage).

## Config

| Key | Where | Meaning |
| --- | --- | --- |
| `gkToken` (optional) | query `?gkToken=` · header `x-gk-token` · legacy `?config=<base64 {"gkToken":…}>` · env `GK_TOKEN` | Your GrowthKit workspace token (`gk_…`). Omit for demo mode. |
| `PORT` | env | HTTP port (default `8080`). MCP endpoint is `POST /mcp`; health at `GET /healthz`. |
| `GK_UPSTREAM_URL` | env | Override the upstream (default `https://mcp.growthkit.tools`). For testing only. |

## Run locally

```bash
npm ci && npm run build

# stdio + MCP Inspector (demo mode — no token needed):
npx @modelcontextprotocol/inspector node dist/stdio.js

# streamable-http:
npm start           # → http://localhost:8080/mcp
```

Quick smoke test over HTTP:

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## Docker

```bash
docker build -t growthkit-directory-shim .
docker run --rm -p 8080:8080 growthkit-directory-shim
```

## Hosting & publishing (maintainers)

Config only — no code changes needed:

- **Smithery (primary — serverless container deploy, free hosting, counted
  tool calls):** connect the repo, set **Base Directory = `mcp-directory-shim`**
  in the deploy settings (this folder holds `smithery.yaml` + `Dockerfile`;
  without the base directory Smithery would build the whole repo), deploy.
  Smithery builds the container, hosts it serverless (~2 min idle timeout —
  the shim is stateless, a cold start just re-mints the cached demo token) and
  routes MCP traffic to `/mcp`. Playground calls go through Smithery's gateway
  and are counted. Session config arrives as `?config=<base64 JSON>`, which
  this shim decodes natively; two contracts are honored by design:
  1. `initialize` + `tools/list` never require user auth (lazy loading) — no
     config simply means demo mode.
  2. An empty `gkToken` (the `exampleConfig` default) falls through to demo.

  *Doc-drift note (2026-07-23):* Smithery's container docs pages are currently
  404 (docs restructure towards CLI publishing); the `smithery.yaml` format
  here matches the last documented schema used by many deployed servers. If
  the dashboard no longer offers the GitHub container deploy, fall back to
  URL-based publishing: run this container on Cloudflare Containers, Fly.io or
  Railway, then

  ```bash
  smithery mcp publish "https://<your-host>/mcp" -n @growthkit-tools/growthkit-demo \
    --config-schema '{"type":"object","properties":{"gkToken":{"type":"string","title":"GrowthKit token (optional)","description":"Your gk_ workspace token. Leave empty to explore the read-only demo workspace."}}}'
  ```

  (URL-publish forwards config as flat query params, `?gkToken=…` — also
  supported.) An MCPB/stdio release via `dist/stdio.js` is possible too.

- **Glama:** the same container is the artifact for Glama's free Dockerfile
  build (quality score); the repo is already listed via `glama.json` at repo
  root. Glama's paid gateway is deliberately not part of this plan.

## Rate limiting

Two layers, both documented deliberately:

1. **Upstream (authoritative):** the GrowthKit Worker rate-limits demo sessions
   per source IP (30 calls/min via Cloudflare KV) — since all shim traffic
   egresses from one container IP, this acts as a global budget for all demo
   users of the shim.
2. **In-shim:** a per-client in-memory limit (10 demo `tools/call`/min per IP)
   keeps a single noisy playground session from exhausting that shared budget.

## Security notes

- **Zero secrets.** The demo path uses the Worker's public OAuth `demo=1` flow;
  the demo `gk_` token stays server-side and never reaches this shim. A
  user-provided `gkToken` is used in-memory only (token cache keys are hashed)
  and never logged.
- Demo write-safety, tool gating and metering are enforced by the GrowthKit
  Worker (`is_demo` session) — the shim adds curation, not security.
- The real MCP stack (Worker / llm-router / n8n) is untouched by this package.
