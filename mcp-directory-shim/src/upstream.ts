// Upstream access for the GrowthKit MCP Worker (mcp.growthkit.tools).
//
// The Worker's MCP endpoint expects `Authorization: Bearer <OAuth access token>`
// (looked up in oauth_tokens server-side) — NOT a raw gk_ token. This module runs
// the Worker's own OAuth code flow programmatically to turn either
//   - a user-provided gk_ token  → full session (role derived server-side), or
//   - the demo path (`demo=1`)   → is_demo session (server-side DEMO_USER_TOKEN;
//     read-only, tool-allowlisted, rate-limited, all enforced by the Worker)
// into a cached access token. The shim never sees or stores the demo gk_ token —
// no secrets are required anywhere in this package.
//
// Safety note: the demo path deliberately uses `demo=1` (→ is_demo access token)
// instead of minting the demo gk_ token via the `demo-token` Edge Function and
// passing it as user_token — the latter would create a NON-demo session (role
// derived from the gk_ prefix) and lose the Worker's demo enforcement.
//
// Deliberately runtime-agnostic: Web Crypto + fetch only (Node >= 20; would run
// unchanged on any edge runtime). The token cache is in-memory per process —
// worst case an extra OAuth dance after a restart, which is cheap and safe.

const upstreamBase = process.env.GK_UPSTREAM_URL ?? "https://mcp.growthkit.tools";

// The Worker's /authorize + /token do not require pre-registered clients today
// (client_id is only checked for presence). If that is ever hardened, add a
// one-time Dynamic Client Registration call to POST /register here.
const CLIENT_ID = "growthkit-directory-shim";
const REDIRECT_URI = "http://localhost/shim-callback"; // never listened on — we parse the 302 Location

const REFRESH_MARGIN_MS = 2 * 60 * 1000; // refresh when <2min of the 1h TTL remain
const MAX_CACHE_ENTRIES = 500;

interface TokenSet {
  accessToken: string;
  refreshToken: string | null;
  expiresAt: number; // epoch ms
}

export class UpstreamAuthError extends Error {}
export class UpstreamUnavailableError extends Error {}

const tokenCache = new Map<string, TokenSet>();
const pendingMints = new Map<string, Promise<TokenSet>>();

function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function sha256Bytes(input: string): Promise<Uint8Array> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return new Uint8Array(digest);
}

async function cacheKey(gkToken: string | null): Promise<string> {
  if (!gkToken) return "demo";
  // Never keep raw gk_ tokens as map keys longer than needed — hash them.
  return b64url(await sha256Bytes(gkToken));
}

async function oauthDance(gkToken: string | null): Promise<TokenSet> {
  // PKCE (S256) — optional upstream, verified when a challenge is present.
  const verifier = b64url(crypto.getRandomValues(new Uint8Array(48)));
  const challenge = b64url(await sha256Bytes(verifier));

  const form = new URLSearchParams({
    response_type: "code",
    client_id: CLIENT_ID,
    redirect_uri: REDIRECT_URI,
    code_challenge: challenge,
    code_challenge_method: "S256",
  });
  if (gkToken) form.set("user_token", gkToken);
  else form.set("demo", "1");

  let authRes: Response;
  try {
    authRes = await fetch(`${upstreamBase}/authorize`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
      redirect: "manual",
    });
  } catch {
    throw new UpstreamUnavailableError("GrowthKit upstream unreachable");
  }

  if (authRes.status !== 302) {
    // 400/401 HTML for an invalid gk_ token; 503 when the demo is unavailable.
    if (gkToken) throw new UpstreamAuthError("GrowthKit token was rejected — check your gk_ token.");
    throw new UpstreamUnavailableError("GrowthKit demo is temporarily unavailable.");
  }
  const location = authRes.headers.get("location") ?? "";
  const code = new URL(location).searchParams.get("code");
  if (!code) throw new UpstreamAuthError("Authorization failed (no code returned).");

  const tokenRes = await fetch(`${upstreamBase}/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code,
      client_id: CLIENT_ID,
      redirect_uri: REDIRECT_URI,
      code_verifier: verifier,
    }).toString(),
  });
  if (!tokenRes.ok) throw new UpstreamAuthError("Token exchange failed.");
  const data = (await tokenRes.json()) as { access_token?: string; refresh_token?: string; expires_in?: number };
  if (!data.access_token) throw new UpstreamAuthError("Token exchange returned no access token.");

  return {
    accessToken: data.access_token,
    refreshToken: data.refresh_token ?? null,
    expiresAt: Date.now() + (data.expires_in ?? 3600) * 1000,
  };
}

async function refresh(set: TokenSet): Promise<TokenSet | null> {
  if (!set.refreshToken) return null;
  try {
    const res = await fetch(`${upstreamBase}/token`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: set.refreshToken }).toString(),
    });
    if (!res.ok) return null;
    const data = (await res.json()) as { access_token?: string; expires_in?: number };
    if (!data.access_token) return null;
    return {
      accessToken: data.access_token,
      refreshToken: set.refreshToken,
      expiresAt: Date.now() + (data.expires_in ?? 3600) * 1000,
    };
  } catch {
    return null;
  }
}

/** Resolve (mint/refresh/reuse) an upstream access token for a session. */
export async function resolveAccessToken(gkToken: string | null): Promise<string> {
  const key = await cacheKey(gkToken);
  const cached = tokenCache.get(key);
  if (cached && cached.expiresAt - Date.now() > REFRESH_MARGIN_MS) return cached.accessToken;

  // Single-flight per key so concurrent requests don't stampede the OAuth flow.
  let pending = pendingMints.get(key);
  if (!pending) {
    pending = (async () => {
      const refreshed = cached ? await refresh(cached) : null;
      const set = refreshed ?? (await oauthDance(gkToken));
      if (tokenCache.size >= MAX_CACHE_ENTRIES && !tokenCache.has(key)) {
        const oldest = tokenCache.keys().next().value;
        if (oldest !== undefined) tokenCache.delete(oldest);
      }
      tokenCache.set(key, set);
      return set;
    })().finally(() => pendingMints.delete(key));
    pendingMints.set(key, pending);
  }
  return (await pending).accessToken;
}

/** Drop a cached token (after an upstream 401). */
export async function invalidateToken(gkToken: string | null): Promise<void> {
  tokenCache.delete(await cacheKey(gkToken));
}

/** One JSON-RPC call against the upstream MCP endpoint. Returns the raw `result`. */
export async function upstreamRpc(method: string, params: unknown, accessToken: string): Promise<any> {
  let res: Response;
  try {
    res = await fetch(`${upstreamBase}/`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        Authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
  } catch {
    throw new UpstreamUnavailableError("GrowthKit upstream unreachable");
  }
  if (res.status === 401) throw new UpstreamAuthError("Upstream session expired");
  if (!res.ok) throw new UpstreamUnavailableError(`GrowthKit upstream returned HTTP ${res.status}`);
  const data = (await res.json()) as { result?: unknown; error?: { message?: string } };
  if (data.error) {
    // Upstream JSON-RPC error messages are user-safe (no tokens/stacktraces).
    throw new UpstreamUnavailableError(data.error.message ?? "Upstream error");
  }
  return data.result;
}

/**
 * Resolve a token and run one RPC; on a 401 (expired/revoked access token)
 * re-mint once and retry, then give up cleanly.
 */
export async function callUpstream(method: string, params: unknown, gkToken: string | null): Promise<any> {
  const accessToken = await resolveAccessToken(gkToken);
  try {
    return await upstreamRpc(method, params, accessToken);
  } catch (e) {
    if (!(e instanceof UpstreamAuthError)) throw e;
    await invalidateToken(gkToken);
    const fresh = await resolveAccessToken(gkToken);
    return upstreamRpc(method, params, fresh);
  }
}
