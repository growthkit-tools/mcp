// MCP SDK wrapper around the shim core — used by the stdio entry (local
// Inspector tests), the Node http entry (src/http.ts) and the Cloudflare
// Worker entry (src/worker.ts).

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { callToolProxied, listToolsProxied, serverInfo, serverInstructions } from "./core.js";

export { SHIM_VERSION } from "./core.js";

/** Build a shim server bound to one session's gk_ token (null → demo mode). */
export function buildServer(gkToken: string | null): Server {
  const server = new Server(serverInfo(gkToken), {
    capabilities: { tools: { listChanged: false } },
    instructions: serverInstructions(gkToken),
  });

  server.setRequestHandler(ListToolsRequestSchema, async () => listToolsProxied(gkToken));

  server.setRequestHandler(CallToolRequestSchema, async (req) =>
    callToolProxied(gkToken, req.params.name, (req.params.arguments as Record<string, unknown>) ?? {})
  );

  return server;
}
