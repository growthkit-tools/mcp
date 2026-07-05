# GrowthKit MCP Worker — Repo Guide for Claude Code

Cloudflare Worker serving the GrowthKit MCP server at `mcp.growthkit.tools`.
Single hand-rolled file: `index.js` implements MCP JSON-RPC by hand (no SDK, no
`package.json`, no `node_modules`). `tools/list`, `tools/call`, `resources/list`,
`resources/read`, prompts and OAuth are all built manually.

## Deploy — do NOT run `wrangler deploy`

This Worker **auto-deploys on push to `main`** via Cloudflare's Git integration.
There is deliberately **no GitHub Actions workflow** in the repo — that is not a
mistake, do not add one and do not suggest a manual `wrangler deploy`.

Flow: **you show `git diff` → Chris reviews, commits, and pushes → Cloudflare
deploys automatically.** Never commit, push, or deploy yourself. (Same pattern as
the marketing site on Cloudflare Pages.)

## Styling reference for cards / visual UI — the extension is the source of truth

For any card / component / visual UI (visual cards, MCP-Apps HTML resources), the
**`chrome-extension` repo's `styles.css` is the visual source of truth** — the
`vc-*` classes (`vc-card`, `vc-card-header`, `vc-card-title`, `vc-card-body`,
`vc-lead-*`, `vc-action`, …) and the design tokens (`--gk-accent`, `--vc-bg`,
`--vc-item-*`, …).

When building HTML elements here, always take those as the reference, copy the
relevant styles **inline** (no cross-repo import — the MCP iframe has no access to
`styles.css`), and mirror the class names / design tokens. Goal: consistent card
look across the extension and MCP, no style drift / tech debt from divergent styles.

The `chrome-extension` repo is a **read-only reference — never edit it.** Also do
not copy its click handlers: the extension fires `callout-call` directly via
`fetch` (`panel.js`); in MCP Apps the click must go through the host bridge →
app-private `place_call`. Structure/look only.

## This repo is PUBLIC

This repo is **public** (made public for the MCP directory listings). Never commit
secrets, tokens, API keys, internal URLs with keys embedded, customer data, or any
`gk_` / `sb_secret_` values into the code. All secrets run through Worker env vars
(`wrangler secret put`); local secrets belong in `.dev.vars` / `.env` (gitignored).
If you are ever tempted to hardcode a real token/key as a constant while debugging:
**STOP and ask** — never hardcode.

`CLAUDE.md` itself is intentionally checked in — it is convention/workflow docs, no
secrets, and being public is fine (a good engineering signal).

## Future hardening for `place_call` (deferred — do not build yet)

Signed HMAC nonce, embedded into the `resources/read` card HTML and verified
server-side — makes a forged direct `place_call` impossible. Deliberately deferred;
build only on a concrete compliance / trust-center need. `place_call` is app-private
via `_meta.ui.visibility: ["app"]` (MCP-Apps / SEP-1865): it is listed in `tools/list`
but the host hides it from the model and only proxies the lead-call-card iframe's
`tools/call`, so the model can never see or invoke it — human-initiated only, which
already satisfies UWG § 7. (This replaced the earlier catalog-hiding approach of
omitting `place_call` from `tools/list`; an omitted tool can be rejected by the host
as "unknown" when the iframe calls it.)

## Discovery-Files — Sync-Invarianten (nie brechen)

Single Source of Truth: SERVER_NAME / SERVER_VERSION / PROTOCOL_VERSION / MCP_ENDPOINT
sind Module-Level-Consts in index.js. BEIDES liest sie:
- die initialize-Response
- /.well-known/mcp/server-card.json
→ Diese vier Werte NIE zweimal hardcoden.

server.json (Registry-Publish): name / version / description MÜSSEN mit der Card
übereinstimmen. Bei Version-Bump: (1) const in index.js, (2) server.json,
(3) ggf. Registry-Re-Publish. Die Card fällt automatisch aus der const.

tools: Card nutzt "tools": "dynamic" → kein Per-Tool-Sync. tools/list bleibt die
einzige Quelle des tatsächlichen Tool-Sets.

OAuth-Triplet — müssen konsistent auf dieselbe Resource/AS zeigen:
- /.well-known/oauth-protected-resource
- /.well-known/oauth-authorization-server
- authentication.resourceMetadata in der server-card.json
Ändern sich OAuth-Endpoints → alle drei anpassen.
