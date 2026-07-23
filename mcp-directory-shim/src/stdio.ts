#!/usr/bin/env node
// stdio entry — for local testing with the MCP Inspector, MCPB bundles and any
// stdio-based client. Config: --gk-token=gk_… argv or GK_TOKEN env; neither →
// demo mode (no secret needed).

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { buildServer } from "./proxy.js";

function resolveGkToken(): string | null {
  const arg = process.argv.find((a) => a.startsWith("--gk-token="))?.slice("--gk-token=".length);
  const candidate = arg ?? process.env.GK_TOKEN ?? null;
  if (candidate && candidate.startsWith("gk_") && candidate.length >= 8 && candidate.length <= 200) {
    return candidate;
  }
  return null;
}

const gkToken = resolveGkToken();
const server = buildServer(gkToken);
await server.connect(new StdioServerTransport());
console.error(`growthkit-directory-shim (stdio) ready — ${gkToken ? "user token session" : "demo mode"}`);
