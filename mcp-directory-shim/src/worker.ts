// Cloudflare Worker entry — the URL-deploy surface of the shim (Smithery
// hosted-URL listing or any directory that just needs an HTTPS MCP endpoint).
//
// Stateless: every request builds a fresh Server bound to the request's
// resolved gk_ token (or demo) and hands it to createMcpHandler from the
// Cloudflare `agents` SDK (route /mcp, JSON responses, no sessions) — the
// handler wires up a per-request WorkerTransport with CORS included.
// core.ts / upstream.ts / allowlist.ts are reused unchanged; src/http.ts stays
// the Node/container entry (Glama Docker), src/stdio.ts the Inspector entry.
//
// Requires nodejs_compat (AsyncLocalStorage inside the agents SDK; process.env
// in upstream.ts) — see wrangler.toml.

import { createMcpHandler } from "agents/mcp";
import { looksLikeGkToken, SHIM_NAME, SHIM_VERSION } from "./core.js";
import { buildServer } from "./proxy.js";
import { DEMO_RATE_LIMIT_MESSAGE, demoRateLimitOk } from "./ratelimit.js";

// Only for responses this entry writes itself (health, DELETE ack, throttle);
// /mcp responses get equivalent CORS from the WorkerTransport defaults.
const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, Mcp-Session-Id, Mcp-Protocol-Version, X-Gk-Token",
  "Access-Control-Expose-Headers": "Mcp-Session-Id",
  "Access-Control-Max-Age": "86400",
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

/** Decode base64 or base64url (Smithery sends either) without Buffer. */
function decodeBase64(b64: string): string | null {
  try {
    const normalized = b64.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
    const bytes = Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
    return new TextDecoder().decode(bytes);
  } catch {
    return null;
  }
}

/** Resolve the session's gk_ token from header / flat query / base64 config. */
function resolveGkToken(url: URL, request: Request): string | null {
  const header = request.headers.get("x-gk-token");
  if (looksLikeGkToken(header)) return header;

  const qp = url.searchParams.get("gkToken");
  if (looksLikeGkToken(qp)) return qp;

  // Smithery gateway delivery: ?config=<base64(JSON)> → cfg.gkToken.
  const b64 = url.searchParams.get("config");
  if (b64) {
    const decoded = decodeBase64(b64);
    if (decoded) {
      try {
        const parsed = JSON.parse(decoded);
        if (looksLikeGkToken(parsed?.gkToken)) return parsed.gkToken;
      } catch {
        /* malformed config → fall through to demo */
      }
    }
  }

  return null;
}

function clientKey(request: Request): string {
  return request.headers.get("cf-connecting-ip") ?? "unknown";
}

export default {
  async fetch(request: Request, env: unknown, ctx: unknown): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/healthz")) {
      return json(200, { name: SHIM_NAME, version: SHIM_VERSION, status: "ok" });
    }

    if (url.pathname !== "/mcp") {
      return json(404, { error: "not_found" });
    }

    // DELETE = session close. Stateless server → nothing to tear down; ack
    // cleanly with 204 (mirrors src/http.ts — never a 500).
    if (request.method === "DELETE") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }
    if (request.method !== "POST") {
      return new Response(JSON.stringify({ error: "method_not_allowed" }), {
        status: 405,
        headers: { Allow: "POST, DELETE", "Content-Type": "application/json", ...CORS_HEADERS },
      });
    }

    const gkToken = resolveGkToken(url, request);

    // Per-client demo throttle on tool execution only (handshake/list stay
    // cheap). Peek at a clone — the transport reads the original body itself.
    // In-memory per isolate here (weaker than the container's single process);
    // the upstream KV limit stays the authoritative backstop.
    if (gkToken === null) {
      let body: any = null;
      try {
        body = await request.clone().json();
      } catch {
        /* malformed JSON → let the transport answer with a parse error */
      }
      if (body?.method === "tools/call" && !demoRateLimitOk(clientKey(request))) {
        return json(200, {
          jsonrpc: "2.0",
          id: body.id ?? null,
          result: { content: [{ type: "text", text: DEMO_RATE_LIMIT_MESSAGE }], isError: true },
        });
      }
    }

    // Fresh Server per request — createMcpHandler's stateless contract
    // (a connected server may not be reused across requests).
    const handler = createMcpHandler(buildServer(gkToken), {
      route: "/mcp",
      enableJsonResponse: true, // plain JSON responses, no SSE stream
    });
    return handler(request, env, ctx as any);
  },
};
