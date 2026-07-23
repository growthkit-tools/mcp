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
  token, and additionally curates `tools/list` down to the tools that return
  rich demo data (memory suite + campaign/lead scoring core).
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

- **Glama:** connect the public repo → Glama builds from this Dockerfile and
  hosts the shim → listing + tool calls in their inspector. No self-hosting
  needed.
- **Smithery** ([URL-based publishing](https://smithery.ai/docs/build/publish.md)
  — container builds via smithery.yaml no longer exist): needs a reachable URL.
  Run this same container on Cloudflare Containers, Fly.io or Railway, then:

  ```bash
  smithery mcp publish "https://<your-host>/mcp" -n @growthkit-tools/growthkit-demo \
    --config-schema '{"type":"object","properties":{"gkToken":{"type":"string","title":"GrowthKit token (optional)","description":"Your gk_ workspace token. Leave empty to explore the read-only demo workspace."}}}'
  ```

  The Smithery gateway forwards session config as flat query params
  (`?gkToken=…` — the default `x-from` delivery), which this shim reads
  natively. An MCPB/stdio release is also possible via `dist/stdio.js` if a
  local distribution is wanted later.

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
