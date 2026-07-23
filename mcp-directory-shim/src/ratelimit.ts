// Tiny in-memory fixed-window rate limiter for the public demo path.
//
// Why it exists: the Worker's own demo rate limit is per SOURCE IP (30/min via
// Cloudflare KV) — but all shim traffic egresses from the shim, so that upstream
// limit becomes a shared budget for every demo user of the shim. This per-client
// limiter keeps one noisy playground session from exhausting the shared budget.
//
// Runtime note: state is in-memory per process (no timers, cleanup is inline;
// single container) — the upstream KV limit stays the authoritative backstop.

const WINDOW_MS = 60_000;
const LIMIT_PER_WINDOW = 10; // demo tool calls per client per minute
const SWEEP_THRESHOLD = 5_000;

const windows = new Map<string, { start: number; count: number }>();

export function demoRateLimitOk(clientKey: string): boolean {
  const now = Date.now();

  // Inline cleanup so the map can't grow unbounded.
  if (windows.size > SWEEP_THRESHOLD) {
    const cutoff = now - WINDOW_MS;
    for (const [key, w] of windows) if (w.start < cutoff) windows.delete(key);
  }

  const w = windows.get(clientKey);
  if (!w || now - w.start >= WINDOW_MS) {
    windows.set(clientKey, { start: now, count: 1 });
    return true;
  }
  w.count += 1;
  return w.count <= LIMIT_PER_WINDOW;
}

export const DEMO_RATE_LIMIT_MESSAGE =
  "The GrowthKit demo is rate-limited to keep it available for everyone. " +
  "Please wait a minute and try again — or get your own workspace: https://growthkit.tools/en/pricing";
