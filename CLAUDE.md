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
build only on a concrete compliance / trust-center need. Catalog-hiding (keeping
`place_call` out of `tools/list`) already satisfies UWG § 7 (human-initiated calls).
