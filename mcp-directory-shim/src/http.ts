// Streamable-HTTP entry — the transport a directory gateway (Smithery URL
// listing, Glama-hosted container) or any MCP client speaks to the shim.
//
// Stateless mode: every POST /mcp builds a fresh Server+Transport pair bound to
// the request's resolved gk_ token (or demo). Session config arrives per the
// current Smithery session-config spec as flat query params (default delivery:
// ?gkToken=…) — an x-gk-token header and the legacy ?config=<base64 json> form
// are accepted too. No config at all → demo mode.

import { createServer as createHttpServer, IncomingMessage, ServerResponse } from "node:http";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { looksLikeGkToken, SHIM_VERSION } from "./core.js";
import { buildServer } from "./proxy.js";
import { DEMO_RATE_LIMIT_MESSAGE, demoRateLimitOk } from "./ratelimit.js";

const PORT = Number(process.env.PORT ?? 8080);
const MAX_BODY_BYTES = 1_000_000;

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, Mcp-Session-Id, Mcp-Protocol-Version, X-Gk-Token",
  "Access-Control-Expose-Headers": "Mcp-Session-Id",
  "Access-Control-Max-Age": "86400",
};

/** Resolve the session's gk_ token from header / query / legacy config / env. */
function resolveGkToken(url: URL, req: IncomingMessage): string | null {
  const header = req.headers["x-gk-token"];
  if (looksLikeGkToken(header)) return header;

  const qp = url.searchParams.get("gkToken");
  if (looksLikeGkToken(qp)) return qp;

  const legacy = url.searchParams.get("config");
  if (legacy) {
    try {
      const parsed = JSON.parse(Buffer.from(legacy, "base64").toString("utf8"));
      if (looksLikeGkToken(parsed?.gkToken)) return parsed.gkToken;
    } catch {
      /* malformed config → fall through to demo */
    }
  }

  if (looksLikeGkToken(process.env.GK_TOKEN)) return process.env.GK_TOKEN as string;
  return null;
}

function clientKey(req: IncomingMessage): string {
  const xff = req.headers["x-forwarded-for"];
  const first = Array.isArray(xff) ? xff[0] : xff?.split(",")[0]?.trim();
  return first || req.socket.remoteAddress || "unknown";
}

function json(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json", ...CORS_HEADERS });
  res.end(JSON.stringify(body));
}

async function readBody(req: IncomingMessage): Promise<string> {
  let size = 0;
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > MAX_BODY_BYTES) throw new Error("body too large");
    chunks.push(chunk as Buffer);
  }
  return Buffer.concat(chunks).toString("utf8");
}

const httpServer = createHttpServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://localhost:${PORT}`);

  if (req.method === "OPTIONS") {
    res.writeHead(204, CORS_HEADERS);
    res.end();
    return;
  }

  if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/healthz")) {
    json(res, 200, { name: "growthkit-directory-shim", version: SHIM_VERSION, status: "ok" });
    return;
  }

  if (url.pathname !== "/mcp") {
    json(res, 404, { error: "not_found" });
    return;
  }

  if (req.method !== "POST") {
    // Stateless mode: no SSE stream to resume (GET) and no session to end (DELETE).
    json(res, 405, { error: "method_not_allowed" });
    return;
  }

  let rawBody: string;
  try {
    rawBody = await readBody(req);
  } catch {
    json(res, 413, { error: "payload_too_large" });
    return;
  }

  let body: any;
  try {
    body = JSON.parse(rawBody);
  } catch {
    json(res, 400, { jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
    return;
  }

  const gkToken = resolveGkToken(url, req);

  // Per-client demo throttle on tool execution only (handshake/list stay cheap).
  if (gkToken === null && body?.method === "tools/call") {
    if (!demoRateLimitOk(clientKey(req))) {
      json(res, 200, {
        jsonrpc: "2.0",
        id: body.id ?? null,
        result: { content: [{ type: "text", text: DEMO_RATE_LIMIT_MESSAGE }], isError: true },
      });
      return;
    }
  }

  const server = buildServer(gkToken);
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: undefined, // stateless
    enableJsonResponse: true,
  });
  res.on("close", () => {
    void transport.close();
    void server.close();
  });

  for (const [k, v] of Object.entries(CORS_HEADERS)) res.setHeader(k, v);

  try {
    await server.connect(transport);
    await transport.handleRequest(req, res, body);
  } catch (e) {
    console.error("request handling failed:", e instanceof Error ? e.message : e);
    if (!res.headersSent) {
      json(res, 500, { jsonrpc: "2.0", id: body?.id ?? null, error: { code: -32603, message: "Internal error" } });
    }
  }
});

httpServer.listen(PORT, "0.0.0.0", () => {
  console.log(`growthkit-directory-shim v${SHIM_VERSION} listening on :${PORT} (MCP at /mcp)`);
});
