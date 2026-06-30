# GrowthKit Revenue Intelligence — MCP Server

[![smithery badge](https://smithery.ai/badge/growthkit/revenue-intelligence)](https://smithery.ai/server/growthkit/revenue-intelligence)
[![Glama score](https://glama.ai/mcp/connectors/tools.growthkit/revenue-intelligence/badges/score.svg)](https://glama.ai/mcp/connectors/tools.growthkit/revenue-intelligence)

> Sales intelligence for DACH & EU SMEs — lead scoring, ICP fit, CRM enrichment & writeback.

**GrowthKit Revenue Intelligence** is a remote [Model Context Protocol](https://modelcontextprotocol.io) server that gives Claude, ChatGPT, Cursor and other MCP clients a persistent, structured GTM brain: a chaptered long-term marketing memory, ICP-based lead scoring, CRM enrichment, and — uniquely — **strategy writeback into your CRM** rather than just into a dashboard.

It is built for owner-led B2B companies in the DACH/EU mid-market that don't have a dedicated GTM team to wire all of this together by hand.

- **Homepage:** https://growthkit.tools/en/mcp
- **Server URL:** `https://mcp.growthkit.tools`
- **Hosted:** remote MCP over Streamable HTTP, OAuth 2.0 with PKCE. No local install.

---

## Quick start

Add the server to any MCP-compatible client (Claude Desktop, Claude.ai, ChatGPT, Cursor, VS Code, Cline, …):

```json
{
  "mcpServers": {
    "growthkit": {
      "url": "https://mcp.growthkit.tools"
    }
  }
}
```

On first connect you'll be taken through an OAuth screen. Paste your GrowthKit
token (`gk_…`) to connect your own workspace, or click **Try the demo** to explore
a read-only sample workspace — no signup required.

Don't have a token yet? See plans & pricing: https://growthkit.tools/en/pricing

---

## What it does

GrowthKit organises GTM knowledge into a **chaptered memory** (icp, strategy,
campaigns, analytics, brand, competitors, learnings, pipeline, signals, playbook)
and lets the assistant read and write that memory, score leads against your ICP,
enrich companies and contacts, and push the result back into your CRM.

### Capability areas

- **Structured marketing memory** — semantic search, batch embedding, auto-tagging, full version history with an audit trail.
- **ICP lead scoring** — scores company/contact pairs against your ICP and surfaces the highest-fit leads, with per-dimension breakdowns and data-completeness filtering.
- **CRM read & writeback** — search/create companies, contacts and deals; structured segment queries; notes and follow-up activities. *(Twenty live; Pipedrive, HubSpot, Salesforce and others on the roadmap.)*
- **Enrichment** — company and person enrichment, contact discovery, email finding and verification.
- **Campaigns** — create and manage campaign briefings, import and triage leads through their lifecycle.
- **Tasks & reminders** — ICE-prioritised tasks and scheduled reminders.
- **Email** — draft or send via your connected Gmail account (Microsoft 365 on the roadmap).
- **Guided playbooks** — onboarding, ICP workshop, competitor analysis, campaign brief, content brief and weekly review *(available on the Growth and Pro plans)*.

> Discovery methods (`tools/list`, `prompts/list`, `resources/list`) are open so
> registries and inspectors can enumerate capabilities without authenticating.
> Everything that touches your data is gated behind OAuth and role-/plan-based
> access control.

---

## Roles & access

Access is scoped by token type — `admin`, `team`, `view` — with chapter-level
read/write permissions, plus a read-only `demo` surface. Plan-gated features
(such as the guided playbook bodies) additionally require a Growth or Pro plan.

---

## Architecture

```
MCP client ──▶ MCP protocol layer (this repo) ──▶ GrowthKit backend
                     │
                     └─ OAuth 2.0 (PKCE), role/plan gating, demo surface
```

This repository contains the **MCP protocol layer**: it speaks the MCP protocol,
handles the OAuth flow, enforces role- and plan-based access control, and routes
tool calls to the GrowthKit backend. The backend itself — scoring logic, data
store and automation — is not part of this repository.

EU-hosted, GDPR-aligned.

---

## Links

- Website: https://growthkit.tools
- MCP overview: https://growthkit.tools/en/mcp
- Pricing: https://growthkit.tools/en/pricing
- GTM Advisory: https://growthkit.consulting
- Smithery: https://smithery.ai/server/growthkit/revenue-intelligence
- Glama: https://glama.ai/mcp/connectors/tools.growthkit/revenue-intelligence

---

<sub>GrowthKit is built in public. This repository is the MCP server surface only;
the product backend and proprietary GTM logic live elsewhere.</sub>