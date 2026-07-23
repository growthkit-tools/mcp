// Runtime-agnostic shim core — consumed by BOTH entries:
//   - src/http.ts (Node streamable-http server, the container entrypoint)
//   - src/proxy.ts → src/stdio.ts (MCP SDK server for local Inspector tests)
//
// Surface: tools/list (upstream list; demo path additionally filtered to
// DEMO_ALLOWLIST) and tools/call (verbatim passthrough of the upstream result,
// incl. isError and the Worker's demo CTA blocks). Prompts/resources are
// deliberately not exposed through the shim — the directory playground surface
// is tools.

import { DEMO_ALLOWLIST, DEMO_BLOCKED_MESSAGE } from "./allowlist.js";
import { callUpstream, UpstreamAuthError } from "./upstream.js";

export const SHIM_NAME = "growthkit-directory-shim";
export const SHIM_VERSION = "0.2.0";

export function serverInfo(gkToken: string | null) {
  return {
    name: SHIM_NAME,
    title: gkToken === null ? "GrowthKit (Demo)" : "GrowthKit",
    version: SHIM_VERSION,
  };
}

export function serverInstructions(gkToken: string | null): string {
  return gkToken === null
    ? "GrowthKit demo workspace (fictional 'ScaleUp Metrics GmbH', read-only). " +
      "Explore the GTM memory (getChapterOverview → searchMemory) and the seeded " +
      "campaign with scored leads (listCampaigns → getTopLeads). " +
      "Bring your own gk_ token (gkToken config) to work with your real workspace."
    : "GrowthKit workspace session — full tool set per your token's role.";
}

export function errorResult(text: string) {
  return { content: [{ type: "text" as const, text }], isError: true };
}

function safeMessage(e: unknown, fallback: string): string {
  // Upstream error messages are user-safe; anything else gets the fallback.
  if (e instanceof Error && e.message && !/gk_|Bearer/i.test(e.message)) return e.message;
  return fallback;
}

/** tools/list through the shim: upstream list, demo path curated + suffixed. */
export async function listToolsProxied(gkToken: string | null): Promise<{ tools: any[] }> {
  try {
    const result = await callUpstream("tools/list", {}, gkToken);
    let tools = Array.isArray(result?.tools) ? result.tools : [];
    if (gkToken === null) {
      // Upstream already filters is_demo sessions to its DEMO_TOOLS —
      // curate further to the verified-non-empty subset.
      tools = tools
        .filter((t: any) => DEMO_ALLOWLIST.has(t.name))
        .map((t: any) => ({ ...t, description: t.description ? `${t.description} · Demo` : "· Demo" }));
    }
    return { tools };
  } catch (e) {
    if (e instanceof UpstreamAuthError) throw new Error(safeMessage(e, "Authorization with GrowthKit failed."));
    throw new Error(safeMessage(e, "GrowthKit upstream unavailable — try again shortly."));
  }
}

/** tools/call through the shim: demo guard, then verbatim passthrough. */
export async function callToolProxied(
  gkToken: string | null,
  name: string,
  args: Record<string, unknown>
): Promise<any> {
  if (gkToken === null && !DEMO_ALLOWLIST.has(name)) {
    return errorResult(DEMO_BLOCKED_MESSAGE);
  }

  try {
    // Verbatim passthrough — content, structuredContent, isError, _meta and
    // the Worker's demo CTA text blocks all flow through untouched.
    return await callUpstream("tools/call", { name, arguments: args }, gkToken);
  } catch (e) {
    if (e instanceof UpstreamAuthError) {
      return errorResult(
        gkToken === null
          ? "The GrowthKit demo session could not be established. Please try again shortly."
          : "Your GrowthKit token was rejected. Check the gkToken value in your connection config."
      );
    }
    return errorResult(safeMessage(e, "GrowthKit upstream unavailable — try again shortly."));
  }
}

export function looksLikeGkToken(v: unknown): v is string {
  return typeof v === "string" && v.startsWith("gk_") && v.length >= 8 && v.length <= 200;
}
