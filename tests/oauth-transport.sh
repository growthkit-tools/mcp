#!/usr/bin/env bash
# GrowthKit MCP Worker — OAuth-Transportweg: Geheimwerte gehoeren in den BODY,
# nicht in den Query-String (SPEC-fix-tranche-1-echte-credentials.md, Teil B).
#
#   bash tests/oauth-transport.sh
#
# ─────────────────────────────────────────────────────────────────────────────
# WAS HIER LAEUFT — UND WARUM NICHT GEGEN PRODUKTION.
#
# Gegenstand sind die fuenf Stellen aus Teil B: drei Lesezugriffe, die frueher
# `?<spalte>=eq.<geheimnis>` gebaut haben, und die zwei Schreibzugriffe
# dahinter, die jetzt ueber die `id` aus demselben Lookup filtern. Geprueft
# wird, WAS der Worker auf die Leitung legt und WO der Geheimwert dabei steht.
#
# Das geht nur gegen ein Backend, dessen Anfragen man mitlesen kann — also eine
# ECHTE Worker-Instanz (`wrangler dev`) gegen eine FALSCHE Supabase. Gegen
# Produktion waere es doppelt falsch: der OAuth-Pfad SCHREIBT (Token anlegen,
# Code loeschen), und ausgerechnet diese Suite duerfte ihre eigenen Geheimwerte
# nicht in fremde Logs tragen.
#
# ⚠️ WAS HIER NICHT GEPRUEFT WIRD: ob die drei RPCs in der Datenbank das
# zurueckgeben, was der Fake behauptet. Das ist supabase#124 und dort an der
# Datenbank verifiziert. Die Fixtures sind die NAHTSTELLE zwischen beiden
# Repos — ihre Feldnamen stammen aus der Migration, nicht aus einer Vermutung.
#
# ⚠️ DIE GEHEIMWERTE HIER SIND ATTRAPPEN. Sie sind bewusst leicht
# wiederzuerkennen (Praefix `acc-`, `ref-`, `code-`), weil die tragende
# Assertion eine SUCHE nach ihnen in jeder protokollierten URL ist.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
ko(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
sec(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
ende(){ printf '\n\033[1mErgebnis: %s grün, %s rot\033[0m\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

printf '\n\033[1m%s\033[0m\n' "oauth-transport — $REPO_ROOT/index.js"

for w in node jq curl; do
  command -v "$w" >/dev/null 2>&1 || { ko "$w fehlt — die Suite kann nicht laufen"; ende; exit 2; }
done
[ -f "$REPO_ROOT/index.js" ] || { ko "index.js nicht gefunden"; ende; exit 2; }

FIX=$(mktemp -d)
FAKE_PID=""; DEV_PID=""
aufraeumen(){
  [ -n "$DEV_PID" ]  && kill "$DEV_PID"  2>/dev/null
  [ -n "${DEV_PORT:-}" ] && pkill -f -- "wrangler dev --port ${DEV_PORT}\b" 2>/dev/null
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$FIX"
}
trap aufraeumen EXIT

freier_port(){ node -e 'const s=require("net").createServer();s.listen(0,()=>{console.log(s.address().port);s.close()})'; }
FAKE_PORT=$(freier_port); DEV_PORT=$(freier_port)
LOG="$FIX/anfragen.jsonl"; : > "$LOG"

# Die Attrappen-Geheimnisse. Sie stehen hier EINMAL und gehen als Umgebung an
# den Fake — zwei Kopien waeren zwei Wahrheiten (§7a).
ACC_OK="acc-11111111-1111-4111-8111-111111111111"
ACC_DEMO="acc-22222222-2222-4222-8222-222222222222"
ACC_EXP="acc-33333333-3333-4333-8333-333333333333"
REF_OK="ref-44444444-4444-4444-8444-444444444444"
CODE_OK="code-5555555-5555-4555-8555-555555555555"
ID_TOKEN="99999999-9999-4999-8999-999999999999"   # oauth_tokens.id (Handle)
ID_CODE="88888888-8888-4888-8888-888888888888"    # oauth_codes.id  (Handle)

# Client-Bindung und PKCE (Abschnitte F–J). client_id ist kein Geheimnis; die
# Werte sind Attrappen in UUID-Form, weil der Worker nur diese Form nachschlaegt.
CLIENT_OK="c0000000-0000-4000-8000-00000000c001"     # registriert: https://client.invalid/cb
CLIENT_LABEL="c0000000-0000-4000-8000-00000000c002"  # registriert: https://x.invalid/claude.ai/cb
CLIENT_FREMD="c0000000-0000-4000-8000-00000000c0ff"  # registriert, aber nicht der des Codes
CLIENT_UNBEKANNT="c0000000-0000-4000-8000-00000000dead"
REDIR_OK="https://client.invalid/cb"
# PKCE-Verifier: 43+ Zeichen (RFC 7636 §4.1). Die Challenge rechnet der Fake
# selbst aus demselben Wert — eine zweite, hier hingeschriebene Challenge waere
# eine zweite Wahrheit (§7a).
VERIFIER_OK="verifier-ok-0123456789abcdefghijklmnopqrstuvwxyz"
VERIFIER_P1="verifier-p1-0123456789abcdefghijklmnopqrstuvwxyz"
CODE_T1="code-t1-00000000-0000-4000-8000-0000000000t1"
CODE_T2="code-t2-00000000-0000-4000-8000-0000000000t2"
CODE_T3="code-t3-00000000-0000-4000-8000-0000000000t3"
CODE_T4="code-t4-00000000-0000-4000-8000-0000000000t4"
ID_T4="88888888-8888-4888-8888-0000000000f4"

# ── Der Fake ─────────────────────────────────────────────────────────────────
# Er spricht die drei RPCs aus supabase#124 und die Schreibpfade dahinter. Die
# ALTEN Wege (`?access_token=eq.` usw.) beantwortet er mit 500: liefe der Worker
# noch dort hin, faende die Assertion unten den Wert in der URL — und der
# Aufruf ginge zusaetzlich sichtbar schief.
cat > "$FIX/fake.mjs" <<'FAKE'
import { createServer } from "node:http";
import { appendFileSync } from "node:fs";
import { createHash, randomUUID } from "node:crypto";

const LOG = process.env.LOG_PATH;
const E = process.env;
const jetzt = Date.now();

// Feldnamen woertlich aus 20260920093000_oauth_und_invite_handles.sql.
// expires_at/refresh_expires_at sind dort `bigint` — Millisekunden, wie der
// Worker sie schreibt und mit Number() vergleicht.
const tokenZeile = (extra) => ({
  id: E.ID_TOKEN, client_id: "test-client", scope: "mcp:read mcp:write",
  expires_at: jetzt + 3600_000, refresh_expires_at: jetzt + 14 * 24 * 3600_000,
  user_token: "gk_view_faketoken", is_demo: false, mcp_client: "claude", lang: "de",
  created_at: new Date(jetzt).toISOString(), ...extra,
});
const s256 = (v) => createHash("sha256").update(v).digest("base64url");
const codeZeile = (extra) => ({
  id: E.ID_CODE, client_id: "test-client", redirect_uri: "https://client.invalid/cb",
  expires_at: jetzt + 600_000, resource: null,
  code_challenge: s256(E.VERIFIER_OK), code_challenge_method: "S256",
  scope: "mcp:read", user_token: "gk_view_faketoken",
  is_demo: false, mcp_client: "claude", lang: "de", ...extra,
});

// ⚠️ DIE CODES SIND ZUSTAND, nicht Konstante. Ein DELETE auf ?id=eq.<id> nimmt
// die Zeile heraus, und der naechste RPC-Aufruf findet sie nicht mehr — so wie
// die Datenbank. Ohne das waere "nach einem Fehlversuch ist der Code
// verbraucht" (T4) nicht messbar: ein zustandsloser Fake liefert denselben
// Code beliebig oft.
const codes = new Map([
  [E.CODE_OK, codeZeile({})],
  [E.CODE_T1, codeZeile({ id: randomUUID(), client_id: E.CLIENT_OK })],
  [E.CODE_T2, codeZeile({ id: randomUUID(), client_id: E.CLIENT_OK })],
  [E.CODE_T3, codeZeile({ id: randomUUID(), client_id: E.CLIENT_OK })],
  [E.CODE_T4, codeZeile({ id: E.ID_T4, client_id: E.CLIENT_OK })],
]);

// oauth_clients — Feldnamen aus der Tabelle: client_id, client_name, redirect_uris.
// client_name traegt absichtlich Markup: es muss escaped ankommen.
const clients = new Map([
  [E.CLIENT_OK,    { client_id: E.CLIENT_OK,    client_name: "Test <b>Client</b>", redirect_uris: ["https://client.invalid/cb"] }],
  [E.CLIENT_LABEL, { client_id: E.CLIENT_LABEL, client_name: "Label-Client",       redirect_uris: ["https://x.invalid/claude.ai/cb"] }],
  [E.CLIENT_FREMD, { client_id: E.CLIENT_FREMD, client_name: "Fremd",              redirect_uris: ["https://client.invalid/cb"] }],
]);

createServer((req, res) => {
  let roh = "";
  req.on("data", (c) => (roh += c));
  req.on("end", () => {
    let body = {};
    try { body = JSON.parse(roh || "{}"); } catch { /* Form ist Teil der Pruefung */ }
    appendFileSync(LOG, JSON.stringify({ pfad: req.url, methode: req.method, body }) + "\n");
    const sende = (status, daten) => {
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(daten));
    };

    if (req.url === "/rest/v1/rpc/gk_oauth_token_by_access") {
      if (body.p_access_token === E.ACC_OK)   return sende(200, [tokenZeile({})]);
      if (body.p_access_token === E.ACC_DEMO) return sende(200, [tokenZeile({ is_demo: true })]);
      if (body.p_access_token === E.ACC_EXP)  return sende(200, [tokenZeile({ expires_at: jetzt - 1000 })]);
      return sende(200, []);
    }
    if (req.url === "/rest/v1/rpc/gk_oauth_token_by_refresh") {
      return sende(200, body.p_refresh_token === E.REF_OK ? [tokenZeile({})] : []);
    }
    if (req.url === "/rest/v1/rpc/gk_oauth_code_by_code") {
      const z = codes.get(body.p_code);
      return sende(200, z ? [z] : []);
    }
    if (req.url.startsWith("/rest/v1/rpc/resolve_user_token")) return sende(200, "11111111-1111-1111-1111-111111111111");
    if (req.url.startsWith("/rest/v1/rpc/gk_meter")) return sende(200, [{ over_limit: false, new_count: 1, effective_limit: 100000 }]);

    // Schreibpfade — erlaubt ist nur der Filter auf die id.
    if (req.url.startsWith("/rest/v1/oauth_tokens?id=eq.") && req.method === "PATCH") return sende(204, {});
    if (req.url === "/rest/v1/oauth_tokens" && req.method === "POST") return sende(201, {});
    if (req.url.startsWith("/rest/v1/oauth_codes?id=eq.") && req.method === "DELETE") {
      const id = req.url.slice("/rest/v1/oauth_codes?id=eq.".length);
      for (const [c, z] of codes) if (z.id === id) codes.delete(c);
      return sende(204, {});
    }
    // /authorize legt den Code an; der Fake nimmt ihn in den Speicher auf, damit
    // der volle Fluss (P1) ihn danach einloesen kann.
    if (req.url === "/rest/v1/oauth_codes" && req.method === "POST") {
      codes.set(body.code, { id: randomUUID(), resource: null, ...body });
      return sende(201, {});
    }
    // Client-Lookup. client_id ist kein Geheimnis und darf im Query-String
    // stehen — die Transportregel dieser Suite gilt Codes und Tokens.
    if (req.url.startsWith("/rest/v1/oauth_clients?") && req.method === "GET") {
      const q = new URL(req.url, "http://fake").searchParams;
      const id = String(q.get("client_id") || "").replace(/^eq\./, "");
      const c = clients.get(id);
      return sende(200, c ? [c] : []);
    }
    if (req.url === "/rest/v1/oauth_clients" && req.method === "POST") return sende(201, {});
    // Token-Pruefung beim POST /authorize (n8n-embed validate_token).
    // `gk_view_netzfehler` reisst die Verbindung ab — so sieht ein Netzfehler
    // fuer den Worker aus: fetch wirft, statt eine Antwort zu liefern.
    if (req.url === "/functions/v1/n8n-embed" && body.action === "validate_token") {
      if (body.user_token === "gk_view_netzfehler") { req.socket.destroy(); return; }
      return sende(200, { valid: body.user_token === "gk_view_faketoken" });
    }

    // Die alten Wege. 500 statt 200: ein Rueckfall soll nicht bloss auffallen,
    // sondern scheitern.
    if (req.url.startsWith("/rest/v1/oauth_tokens") || req.url.startsWith("/rest/v1/oauth_codes")) {
      return sende(500, { error: "alter Weg mit Geheimwert in der URL", pfad: req.url });
    }
    return sende(404, { error: `unerwarteter Pfad: ${req.url}` });
  });
}).listen(Number(process.env.PORT), "127.0.0.1");
FAKE

LOG_PATH="$LOG" PORT="$FAKE_PORT" \
  ACC_OK="$ACC_OK" ACC_DEMO="$ACC_DEMO" ACC_EXP="$ACC_EXP" REF_OK="$REF_OK" CODE_OK="$CODE_OK" \
  ID_TOKEN="$ID_TOKEN" ID_CODE="$ID_CODE" \
  CLIENT_OK="$CLIENT_OK" CLIENT_LABEL="$CLIENT_LABEL" CLIENT_FREMD="$CLIENT_FREMD" \
  VERIFIER_OK="$VERIFIER_OK" CODE_T1="$CODE_T1" CODE_T2="$CODE_T2" CODE_T3="$CODE_T3" \
  CODE_T4="$CODE_T4" ID_T4="$ID_T4" \
  node "$FIX/fake.mjs" &
FAKE_PID=$!

for _ in $(seq 1 40); do
  curl -s -m 2 -o /dev/null "http://127.0.0.1:$FAKE_PORT/rest/v1/rpc/gk_meter" -X POST -d '{}' && break
  sleep 0.1
done
if curl -s -m 2 -X POST "http://127.0.0.1:$FAKE_PORT/rest/v1/rpc/gk_meter" -d '{}' | grep -q effective_limit; then
  ok "Fake-Backend laeuft auf 127.0.0.1:$FAKE_PORT"
else
  ko "Fake-Backend antwortet nicht — alles darunter waere ein Test gegen nichts"; ende; exit 2
fi

# ── Die Instanz ──────────────────────────────────────────────────────────────
# `--persist-to` in das Wegwerf-Verzeichnis: das Registrierungs-Limit (Abschnitt
# J) zaehlt im KV, und der Standardort .wrangler/state ueberlebt den Lauf. Ohne
# frisches KV waere der zweite Lauf binnen einer Stunde anders als der erste.
( cd "$REPO_ROOT" && npx --no-install wrangler dev \
    --port "$DEV_PORT" --ip 127.0.0.1 --show-interactive-dev-session false \
    --persist-to "$FIX/state" \
    --var "SUPABASE_URL:http://127.0.0.1:$FAKE_PORT" \
    --var "SUPABASE_SECRET_KEY:sb_secret_attrappe" \
    --var "N8N_AUTH_TOKEN:attrappe" \
    --var "MCP_TO_EDGE_SECRET:attrappe" \
    --var "PIXEL_SALT:attrappe" \
    > "$FIX/wrangler.log" 2>&1 ) &
DEV_PID=$!

BASE="http://127.0.0.1:$DEV_PORT"
mcp(){ # token  json-rpc-body
  local tok="$1"; shift
  if [ -n "$tok" ]; then
    curl -s -m 20 -X POST "$BASE/" -H 'content-type: application/json' -H "Authorization: Bearer $tok" -d "$1"
  else
    curl -s -m 20 -X POST "$BASE/" -H 'content-type: application/json' -d "$1"
  fi
}
tok_endpunkt(){ curl -s -m 20 -X POST "$BASE/token" -H 'content-type: application/json' -d "$1"; }

bereit=0
for _ in $(seq 1 120); do
  if mcp "" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq -e '.result.tools | type == "array"' >/dev/null 2>&1; then
    bereit=1; break
  fi
  sleep 0.5
done
[ "$bereit" = 1 ] || { ko "wrangler dev wurde nicht bereit — Log: $(tail -3 "$FIX/wrangler.log" | tr '\n' ' ')"; ende; exit 2; }

# §18a (g): serviert die Instanz DIESEN Checkout?
VER_DATEI=$(grep -m1 'const SERVER_VERSION' "$REPO_ROOT/index.js" | sed 's/.*"\(.*\)".*/\1/')
VER_LIVE=$(mcp "" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | jq -r '.result.serverInfo.version // ""')
if [ -n "$VER_DATEI" ] && [ "$VER_DATEI" = "$VER_LIVE" ]; then
  ok "Instanz serviert diesen Checkout (SERVER_VERSION $VER_LIVE)"
else
  ko "Instanz-Version '$VER_LIVE' != Datei '$VER_DATEI' — der Pruefling ist ein anderer"
fi

letzte(){ jq -c --arg p "$1" 'select(.pfad == $p)' "$LOG" | tail -1; }
hat_pfad(){ jq -e --arg p "$1" 'select(.pfad == $p)' "$LOG" >/dev/null 2>&1; }

# ═════════════════════════════════════════════════════════════════════════════
sec "A · Access-Token-Lookup (:1361) — RPC statt ?access_token=eq."

L=$(mcp "$ACC_OK" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
A=$(letzte "/rest/v1/rpc/gk_oauth_token_by_access")
if [ -z "$A" ]; then
  ko "gk_oauth_token_by_access wurde nicht gerufen — der Lookup nimmt einen anderen Weg"
else
  ok "Lookup laeuft ueber gk_oauth_token_by_access"
  [ "$(echo "$A" | jq -r '.methode')" = "POST" ] \
    && ok "als POST (der Wert kann damit im Body stehen)" || ko "Methode: $(echo "$A" | jq -r '.methode')"
  [ "$(echo "$A" | jq -r '.body.p_access_token')" = "$ACC_OK" ] \
    && ok "der access_token steht im BODY, als p_access_token" || ko "p_access_token fehlt im Body: $(echo "$A" | jq -c '.body')"
fi

# Die Aufloesung muss weiterhin wirken, sonst belegt der Transportweg nichts:
# user_token "gk_view_faketoken" -> Rolle view.
NAMEN=$(echo "$L" | jq -r '.result.tools[].name' | sort)
N_VIEW=$(echo "$NAMEN" | grep -c .)
# ⚠️ GEGEN DEN UNAUTHENTIFIZIERTEN KATALOG MESSEN, nicht gegen eine Zahl und
# nicht gegen "ist Tool X drin". Scheitert die Aufloesung ganz, bleibt
# userToken null — und dann liefert tools/list die VOLLE Liste, in der jedes
# gesuchte Tool ebenfalls steht. Genau so war diese Zeile im ersten Rotlauf
# gruen, ohne etwas zu belegen (§18a g).
N_OFFEN=$(mcp "" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq -r '.result.tools | length')
{ [ "${N_VIEW:-0}" -gt 0 ] && [ "${N_VIEW:-0}" -lt "${N_OFFEN:-0}" ] && echo "$NAMEN" | grep -qx listLeadSignals; } \
  && ok "die Sitzung ist aufgeloest: rollengefilterter Katalog ($N_VIEW von $N_OFFEN), listLeadSignals drin" \
  || ko "kein view-Katalog: $N_VIEW Tools gegenueber $N_OFFEN unauthentifiziert"
echo "$NAMEN" | grep -qx pipelineRun \
  && ko "view sieht pipelineRun — die Rolle kommt nicht aus dem aufgeloesten user_token" \
  || ok "GEGENRICHTUNG: pipelineRun fehlt, die Rolle wirkt"

# is_demo kommt aus derselben Zeile — ohne dieses Feld waere die Demo-Grenze weg.
D=$(mcp "$ACC_DEMO" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq -r '.result.tools[].name' | sort)
if [ -z "$D" ]; then
  ko "die Demo-Sitzung liefert gar keinen Katalog"
else
  echo "$D" | grep -qx updateLeadSignal \
    && ko "is_demo wirkt nicht: die Demo-Sitzung sieht ein Schreib-Tool" \
    || ok "is_demo aus der RPC-Zeile wirkt: kein Schreib-Tool im Demo-Katalog"
fi

# Ablauf: expires_at ist bigint (ms). Kaeme dort ein Zeitstempel-String an,
# waere Number() NaN und JEDES Token still abgelaufen — deshalb beide Faelle.
R=$(mcp "$ACC_EXP" '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"listCampaigns","arguments":{}}}')
[ "$(echo "$R" | jq -r '.error.data.path')" = "oauth" ] \
  && ok "abgelaufene Zeile: 401 auf dem oauth-Pfad" \
  || ko "abgelaufenes Token nicht abgewiesen: $(echo "$R" | jq -c '.error // .result' | head -c 120)"
R=$(mcp "acc-unbekannt" '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"listCampaigns","arguments":{}}}')
[ "$(echo "$R" | jq -r '.error.data.path')" = "oauth" ] \
  && ok "unbekannter Token: 401 auf dem oauth-Pfad (leeres RPC-Ergebnis)" \
  || ko "unbekannter Token nicht abgewiesen: $(echo "$R" | jq -c '.error // .result' | head -c 120)"

# ═════════════════════════════════════════════════════════════════════════════
sec "B · grant_type=refresh_token (:4494 Lookup, :4504 PATCH)"

T=$(tok_endpunkt "{\"grant_type\":\"refresh_token\",\"client_id\":\"test-client\",\"refresh_token\":\"$REF_OK\"}")
A=$(letzte "/rest/v1/rpc/gk_oauth_token_by_refresh")
if [ -z "$A" ]; then
  ko "gk_oauth_token_by_refresh wurde nicht gerufen"
else
  ok "Lookup laeuft ueber gk_oauth_token_by_refresh"
  [ "$(echo "$A" | jq -r '.body.p_refresh_token')" = "$REF_OK" ] \
    && ok "der refresh_token steht im BODY" || ko "p_refresh_token fehlt: $(echo "$A" | jq -c '.body')"
fi
P=$(letzte "/rest/v1/oauth_tokens?id=eq.$ID_TOKEN")
if [ -z "$P" ]; then
  ko "kein PATCH auf ?id=eq.<uuid> — der Schreibzugriff filtert weiter auf das Geheimnis"
else
  ok "PATCH filtert auf die id aus dem Lookup (?id=eq.$ID_TOKEN)"
  [ "$(echo "$P" | jq -r '.methode')" = "PATCH" ] || ko "Methode: $(echo "$P" | jq -r '.methode')"
  [ -n "$(echo "$P" | jq -r '.body.access_token // ""')" ] \
    && ok "der neue access_token steht im PATCH-Body" || ko "PATCH-Body ohne access_token: $(echo "$P" | jq -c '.body')"
fi
[ -n "$(echo "$T" | jq -r '.access_token // ""')" ] && [ "$(echo "$T" | jq -r '.scope')" = "mcp:read mcp:write" ] \
  && ok "die Antwort traegt einen neuen access_token und den scope aus der Zeile" \
  || ko "Antwort des Refresh-Grants: $(echo "$T" | head -c 140)"

T=$(tok_endpunkt '{"grant_type":"refresh_token","client_id":"test-client","refresh_token":"ref-unbekannt"}')
[ "$(echo "$T" | jq -r '.error')" = "invalid_grant" ] \
  && ok "GEGENRICHTUNG: unbekannter refresh_token -> invalid_grant" \
  || ko "unbekannter refresh_token: $(echo "$T" | head -c 140)"

# ═════════════════════════════════════════════════════════════════════════════
sec "C · grant_type=authorization_code (:4454 Lookup, :4473 DELETE)"

# Ein VOLLSTAENDIGER Grant: redirect_uri und code_verifier gehoeren dazu. Bis
# zum 29.09.2026 stand hier ein Aufruf ohne beides — er war gruen, weil der
# Worker beides nur pruefte, wenn es mitkam. Gegenstand dieses Abschnitts ist
# der Transportweg, nicht die Bindung; die steht in Abschnitt H.
T=$(tok_endpunkt "{\"grant_type\":\"authorization_code\",\"client_id\":\"test-client\",\"code\":\"$CODE_OK\",\"redirect_uri\":\"$REDIR_OK\",\"code_verifier\":\"$VERIFIER_OK\"}")
A=$(letzte "/rest/v1/rpc/gk_oauth_code_by_code")
if [ -z "$A" ]; then
  ko "gk_oauth_code_by_code wurde nicht gerufen"
else
  ok "Lookup laeuft ueber gk_oauth_code_by_code"
  [ "$(echo "$A" | jq -r '.body.p_code')" = "$CODE_OK" ] \
    && ok "der code steht im BODY" || ko "p_code fehlt: $(echo "$A" | jq -c '.body')"
fi
D=$(letzte "/rest/v1/oauth_codes?id=eq.$ID_CODE")
[ -n "$D" ] && [ "$(echo "$D" | jq -r '.methode')" = "DELETE" ] \
  && ok "DELETE filtert auf die id aus dem Lookup (?id=eq.$ID_CODE)" \
  || ko "kein DELETE auf ?id=eq.<uuid> — der Code wird weiter ueber sich selbst geloescht"
I=$(letzte "/rest/v1/oauth_tokens")
if [ -z "$I" ]; then
  ko "keine neue oauth_tokens-Zeile angelegt"
else
  ok "die neue Zeile wird per POST angelegt (Werte im Body, nicht in der URL)"
  [ "$(echo "$I" | jq -r '.body.user_token')" = "gk_view_faketoken" ] \
    && ok "das user_token aus der Code-Zeile wandert mit" || ko "user_token im Insert: $(echo "$I" | jq -r '.body.user_token // "fehlt"')"
fi
[ -n "$(echo "$T" | jq -r '.access_token // ""')" ] && [ -n "$(echo "$T" | jq -r '.refresh_token // ""')" ] \
  && ok "die Antwort traegt access_token und refresh_token" \
  || ko "Antwort des Code-Grants: $(echo "$T" | head -c 140)"

T=$(tok_endpunkt '{"grant_type":"authorization_code","client_id":"test-client","code":"code-unbekannt"}')
[ "$(echo "$T" | jq -r '.error')" = "invalid_grant" ] \
  && ok "GEGENRICHTUNG: unbekannter code -> invalid_grant" \
  || ko "unbekannter code: $(echo "$T" | head -c 140)"

# ═════════════════════════════════════════════════════════════════════════════
sec "D · Die tragende Invariante — kein Geheimwert in einer URL"

# Das ist der eigentliche Gegenstand der Tranche: was in der URL steht, steht im
# Gateway-Log. Geprueft wird ueber ALLE protokollierten Anfragen, nicht nur die
# fuenf Stellen — ein neuer Aufrufer faellt damit ebenfalls auf.
ANZ=$(wc -l < "$LOG" | tr -d ' ')
[ "${ANZ:-0}" -gt 0 ] \
  && ok "der Fake wurde erreicht ($ANZ Anfragen protokolliert)" \
  || { ko "keine einzige Anfrage protokolliert — alle Assertions liefen ueber einer leeren Menge (§18a a)"; ende; exit 1; }

TREFFER=""
for GEHEIM in "$ACC_OK" "$ACC_DEMO" "$ACC_EXP" "$REF_OK" "$CODE_OK"; do
  N=$(jq -r --arg g "$GEHEIM" 'select(.pfad | contains($g)) | .pfad' "$LOG" | wc -l | tr -d ' ')
  [ "${N:-0}" -eq 0 ] || TREFFER="$TREFFER $GEHEIM($N)"
done
[ -z "$TREFFER" ] \
  && ok "keiner der fuenf Geheimwerte steht in einer URL" \
  || ko "Geheimwert in der URL:$TREFFER — genau das, was Tranche 1 beseitigt"

# ⚠️ OHNE DIESE GEGENPROBE IST DIE ASSERTION DARUEBER WERTLOS. Waeren die Werte
# nie verschickt worden, waere sie ebenfalls gruen (§18a d).
IM_BODY=0
for GEHEIM in "$ACC_OK" "$REF_OK" "$CODE_OK"; do
  jq -e --arg g "$GEHEIM" 'select(.body | tostring | contains($g))' "$LOG" >/dev/null 2>&1 && IM_BODY=$((IM_BODY+1))
done
[ "$IM_BODY" -eq 3 ] \
  && ok "GEGENPROBE: alle drei Geheimwerte kamen sehr wohl an — im BODY" \
  || ko "nur $IM_BODY von 3 Geheimwerten im Body gefunden — die Assertion darueber belegt dann nichts"

# Die alten Wege duerfen im ganzen Lauf nicht vorkommen.
ALT=$(jq -r 'select(.pfad | test("/rest/v1/oauth_(tokens|codes)\\?(access_token|refresh_token|code)=")) | .pfad' "$LOG" | wc -l | tr -d ' ')
[ "${ALT:-0}" -eq 0 ] \
  && ok "kein Aufruf auf ?access_token=eq. / ?refresh_token=eq. / ?code=eq." \
  || ko "$ALT Aufrufe gehen noch den alten Weg"

# ═════════════════════════════════════════════════════════════════════════════
# CLIENT-BINDUNG UND PKCE (F–J)
#
# Was erzwungen wird:
#   * /authorize nimmt nur registrierte Clients an, und die redirect_uri muss
#     exakt einer ihrer registrierten redirect_uris entsprechen. Scheitert das,
#     antwortet eine Fehlerseite — ohne Weiterleitung (RFC 6749 §4.1.2.1).
#   * PKCE mit S256 ist Pflicht; `plain` wird nicht mehr angenommen.
#   * Die Consent-Seite gibt nur erlaubte Parameter zurueck, alles escaped, und
#     nennt den Host, an den weitergeleitet wird.
#   * /token prueft client_id, redirect_uri und code_verifier gegen den Code;
#     ein Code ist nach dem ersten Einloeseversuch verbraucht, auch einem
#     fehlgeschlagenen.
#   * /register nimmt nur plausible Metadaten an und zaehlt pro IP.
#
# ⚠️ WARUM EIN GRUND-HEADER. Jede Ablehnung von /authorize traegt
# `x-gk-oauth-error` (invalid_client | invalid_redirect_uri | invalid_request |
# temporarily_unavailable). Ohne ihn waere eine 400 aus dem falschen Grund —
# etwa ein gescheiterter Client-Lookup statt der redirect_uri-Pruefung — von der
# richtigen nicht zu unterscheiden (§18a g).
# ═════════════════════════════════════════════════════════════════════════════

qs(){ # name wert [name wert …] -> Query-String, Namen UND Werte kodiert
  local out="" k v
  while [ $# -ge 2 ]; do
    k=$(jq -rn --arg s "$1" '$s|@uri'); v=$(jq -rn --arg s "$2" '$s|@uri')
    out="${out:+$out&}$k=$v"; shift 2
  done
  printf '%s' "$out"
}
AB="$FIX/antwort.body"; AH="$FIX/antwort.hdr"
auth_get(){ curl -s -m 20 -o "$AB" -D "$AH" -w '%{http_code}' -H "accept-language: ${2:-en}" "$BASE/authorize?$1"; }
auth_post(){ curl -s -m 20 -o "$AB" -D "$AH" -w '%{http_code}' -X POST "$BASE/authorize" \
  -H 'content-type: application/x-www-form-urlencoded' --data-binary "$1"; }
registrieren(){ curl -s -m 20 -o "$AB" -D "$AH" -w '%{http_code}' -X POST "$BASE/register" \
  -H 'content-type: application/json' --data-binary "$1"; }
location(){ grep -i '^location:' "$AH" | head -1 | tr -d '\r' | sed 's/^[^:]*: *//'; }
grund(){ grep -i '^x-gk-oauth-error:' "$AH" | head -1 | tr -d '\r' | sed 's/^[^:]*: *//'; }
formulare(){ grep -c '<form' "$AB"; }
client_inserts(){ jq -r 'select(.pfad == "/rest/v1/oauth_clients" and .methode == "POST") | .pfad' "$LOG" | wc -l | tr -d ' '; }
s256(){ node -e 'process.stdout.write(require("crypto").createHash("sha256").update(process.argv[1]).digest("base64url"))' "$1"; }
# Eine Ablehnung ohne Weiterleitung, aus dem genannten Grund.
abgelehnt(){ # fall status erwartet-status erwartet-grund
  local l; l=$(location)
  if [ "$2" = "$3" ] && [ -z "$l" ] && [ "$(formulare)" = 0 ] && [ "$(grund)" = "$4" ]; then
    ok "$1: $3 ($4), keine Weiterleitung, kein Formular"
  else
    ko "$1: HTTP $2 (erwartet $3), Grund '$(grund)' (erwartet $4), Location '${l:-}', Formulare $(formulare)"
  fi
}

CH_OK=$(s256 "$VERIFIER_OK"); CH_P1=$(s256 "$VERIFIER_P1")
[ ${#CH_OK} -eq 43 ] && ok "S256-Challenge berechnet (43 Zeichen base64url)" || ko "S256-Challenge kaputt: '$CH_OK'"
GUELTIG=$(qs response_type code client_id "$CLIENT_OK" redirect_uri "$REDIR_OK" state st-1 code_challenge "$CH_OK" code_challenge_method S256)

# ═════════════════════════════════════════════════════════════════════════════
sec "F · GET /authorize — nur registrierte Clients und exakte redirect_uri"

# Die Discovery sagt, was /authorize annimmt: nur noch S256.
M=$(curl -s -m 20 "$BASE/.well-known/oauth-authorization-server" | jq -c '.code_challenge_methods_supported')
[ "$M" = '["S256"]' ] && ok "M1 AS-Metadata: code_challenge_methods_supported = [\"S256\"]" || ko "M1 AS-Metadata: $M"

C=$(auth_get "$(qs response_type code client_id "$CLIENT_UNBEKANNT" redirect_uri "$REDIR_OK" code_challenge "$CH_OK" code_challenge_method S256)")
abgelehnt "A1 unbekannte client_id" "$C" 400 invalid_client

C=$(auth_get "$(qs response_type code client_id "$CLIENT_OK" redirect_uri "https://anders.invalid/cb" code_challenge "$CH_OK" code_challenge_method S256)")
abgelehnt "A2 redirect_uri nicht registriert" "$C" 400 invalid_redirect_uri

# Der registrierte Wert steht als TEIL dieser URI darin (Pfad beginnt mit einem
# bekannten Hostnamen). Exakter Vergleich heisst: das zaehlt nicht.
C=$(auth_get "$(qs response_type code client_id "$CLIENT_OK" redirect_uri "https://fremd.invalid/claude.ai/cb" code_challenge "$CH_OK" code_challenge_method S256)")
abgelehnt "A3 redirect_uri enthaelt nur einen bekannten Namen im Pfad" "$C" 400 invalid_redirect_uri

# Parameter-NAMEN werden nicht in die Seite uebernommen, Werte escaped.
C=$(auth_get "$GUELTIG&$(qs '"><script>gk_marker</script>' 1)")
{ [ "$C" = 200 ] && ! grep -q '<script>gk_marker' "$AB"; } \
  && ok "A4 fremder Parametername: Seite rendert (200), der Name erscheint nicht als Markup" \
  || ko "A4 fremder Parametername: HTTP $C, Markup im Body: $(grep -c '<script>gk_marker' "$AB")"
# ⚠️ ZWEI SCHICHTEN, ZWEI FAELLE. A4 bleibt auch dann gruen, wenn ALLE
# Parameter wieder Hidden-Fields werden — solange ihre Namen escaped sind. Ob
# nur die erlaubten Parameter uebernommen werden, prueft erst ein harmloser,
# unbekannter Parameter: er darf gar nicht erst erscheinen (§18a d).
C=$(auth_get "$GUELTIG&$(qs fremd_param wert-x)")
{ [ "$C" = 200 ] && ! grep -q 'fremd_param' "$AB"; } \
  && ok "A4c unbekannter Parameter wird nicht als Hidden-Field uebernommen" \
  || ko "A4c unbekannter Parameter: HTTP $C, im Body $(grep -c 'fremd_param' "$AB")"
C=$(auth_get "$(qs response_type code client_id "$CLIENT_OK" redirect_uri "$REDIR_OK" state '"><b>st</b>' code_challenge "$CH_OK" code_challenge_method S256)")
{ [ "$C" = 200 ] && ! grep -q '<b>st</b>' "$AB" && grep -q '&lt;b&gt;st' "$AB"; } \
  && ok "A4b Parameterwert (state) kommt escaped in die Seite" \
  || ko "A4b state-Wert: HTTP $C, roh $(grep -c '<b>st</b>' "$AB"), escaped $(grep -c '&lt;b&gt;st' "$AB")"

C=$(auth_get "$(qs response_type code client_id "$CLIENT_OK" redirect_uri "$REDIR_OK")")
abgelehnt "A5 ohne code_challenge" "$C" 400 invalid_request
C=$(auth_get "$(qs response_type code client_id "$CLIENT_OK" redirect_uri "$REDIR_OK" code_challenge "$VERIFIER_OK" code_challenge_method plain)")
abgelehnt "A5b code_challenge_method=plain" "$C" 400 invalid_request
C=$(auth_get "$(qs response_type token client_id "$CLIENT_OK" redirect_uri "$REDIR_OK" code_challenge "$CH_OK" code_challenge_method S256)")
abgelehnt "A5c response_type=token" "$C" 400 invalid_request

# Die Consent-Seite nennt, wohin weitergeleitet wird — sprachabhaengig wie der
# Rest der Seite. client_name ist frei waehlbar: er erscheint escaped und nur
# als Selbstauskunft, nicht in der Ueberschrift.
# ⚠️ HOST DIREKT HINTER DER WENDUNG, nicht irgendwo im Body. Der Host steht
# ohnehin im Hidden-Feld redirect_uri — eine getrennte Suche nach ihm waere
# auch ohne die neue Zeile gruen (§18a d). Zwischen Wendung und Host sind nur
# Doppelpunkt, Leerraum und Tags erlaubt — in BELIEBIGER Folge. Die erste
# Fassung liess Leerraum nur vor einem Tag zu; die Gegenprobe "<strong> host"
# (semantisch dasselbe) war damit rot.
nach_wendung(){ grep -qE "$1:?( |&nbsp;|<[^>]+>)*$2" "$AB"; }
C=$(auth_get "$GUELTIG" de)
{ [ "$C" = 200 ] && nach_wendung 'Weiterleitung an' 'client\.invalid'; } \
  && ok "A7 Consent (de): 'Weiterleitung an' + Host client.invalid" \
  || ko "A7 Consent (de): HTTP $C, 'Weiterleitung an' $(grep -c 'Weiterleitung an' "$AB")"
C=$(auth_get "$GUELTIG" en)
{ [ "$C" = 200 ] && nach_wendung 'Redirects to' 'client\.invalid'; } \
  && ok "A7b Consent (en): 'Redirects to' + Host" \
  || ko "A7b Consent (en): HTTP $C, 'Redirects to' $(grep -c 'Redirects to' "$AB")"
{ grep -q 'Test &lt;b&gt;Client&lt;/b&gt;' "$AB" && ! grep -q '<b>Client</b>' "$AB" && ! grep -q 'Connect Test' "$AB"; } \
  && ok "A7c client_name erscheint escaped und nicht in der Ueberschrift" \
  || ko "A7c client_name: escaped $(grep -c 'Test &lt;b&gt;Client' "$AB"), roh $(grep -c '<b>Client</b>' "$AB"), in Ueberschrift $(grep -c 'Connect Test' "$AB")"

# Das Label der Ueberschrift kommt aus dem HOSTNAMEN, nicht aus einem Teilstring
# der ganzen URI. Dieser Client ist mit genau dieser URI registriert — die Seite
# rendert also, darf ihn aber nicht als bekannten Client ausweisen.
C=$(auth_get "$(qs response_type code client_id "$CLIENT_LABEL" redirect_uri "https://x.invalid/claude.ai/cb" code_challenge "$CH_OK" code_challenge_method S256)")
{ [ "$C" = 200 ] && ! grep -q 'Connect Claude' "$AB" && nach_wendung 'Redirects to' 'x\.invalid'; } \
  && ok "A11 Label nach Hostname: x.invalid/claude.ai/... ist nicht 'Claude', Ziel x.invalid genannt" \
  || ko "A11 Label: HTTP $C, 'Connect Claude' $(grep -c 'Connect Claude' "$AB")"

# ═════════════════════════════════════════════════════════════════════════════
sec "G · POST /authorize — dieselben Pruefungen, die Formularfelder sind Eingaben"

POST_OK="$GUELTIG&$(qs user_token gk_view_faketoken)"
C=$(auth_post "$(qs response_type code client_id "$CLIENT_OK" redirect_uri "https://fremd.invalid/cb" state st-1 code_challenge "$CH_OK" code_challenge_method S256 user_token gk_view_faketoken)")
abgelehnt "A6 geaendertes Formularfeld redirect_uri" "$C" 400 invalid_redirect_uri
C=$(auth_post "$(qs response_type code client_id "$CLIENT_UNBEKANNT" redirect_uri "$REDIR_OK" code_challenge "$CH_OK" code_challenge_method S256 user_token gk_view_faketoken)")
abgelehnt "A6b unbekannte client_id im Formular" "$C" 400 invalid_client
C=$(auth_post "$(qs response_type code client_id "$CLIENT_OK" redirect_uri "$REDIR_OK" code_challenge "$VERIFIER_OK" code_challenge_method plain user_token gk_view_faketoken)")
abgelehnt "A6c code_challenge_method=plain im Formular" "$C" 400 invalid_request

# Die Token-Pruefung ist nicht erreichbar -> abbrechen, nicht weiterlaufen.
C=$(auth_post "$GUELTIG&$(qs user_token gk_view_netzfehler)")
abgelehnt "A9 Token-Pruefung nicht erreichbar" "$C" 503 temporarily_unavailable

# Der Wiederholungslink bei ungueltigem Token traegt nur erlaubte Parameter.
C=$(auth_post "$GUELTIG&$(qs user_token kein-gk-token fremd_param wert-x)")
{ [ "$C" = 400 ] && grep -q 'client_id=' "$AB" && ! grep -q 'fremd_param' "$AB"; } \
  && ok "A12 Wiederholungslink: client_id drin, fremder Parameter nicht" \
  || ko "A12 Wiederholungslink: HTTP $C, client_id $(grep -c 'client_id=' "$AB"), fremd_param $(grep -c 'fremd_param' "$AB")"

# ── P1: der volle Fluss, muss gruen sein und bleiben ─────────────────────────
Q=$(qs response_type code client_id "$CLIENT_OK" redirect_uri "$REDIR_OK" state st-p1 code_challenge "$CH_P1" code_challenge_method S256 resource "$BASE" scope "mcp:read mcp:write")
C1=$(auth_get "$Q"); F1=$(formulare)
C2=$(auth_post "$Q&$(qs user_token gk_view_faketoken)"); LOC=$(location)
P1_CODE=$(printf '%s' "$LOC" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
T=$(tok_endpunkt "$(jq -cn --arg c "$CLIENT_OK" --arg code "$P1_CODE" --arg r "$REDIR_OK" --arg v "$VERIFIER_P1" \
  '{grant_type:"authorization_code", client_id:$c, code:$code, redirect_uri:$r, code_verifier:$v}')")
{ [ "$C1" = 200 ] && [ "$F1" -gt 0 ]; } && ok "P1 GET: Consent-Seite mit Formular" || ko "P1 GET: HTTP $C1, Formulare $F1"
case "$LOC" in
  "$REDIR_OK?code="*state=st-p1*) ok "P1 POST: 302 an die registrierte redirect_uri, mit code und state" ;;
  *) ko "P1 POST: HTTP $C2, Location '$LOC'" ;;
esac
[ -n "$(echo "$T" | jq -r '.access_token // ""')" ] \
  && ok "P1 token: access_token mit S256-Verifier, exakter redirect_uri, passender client_id" \
  || ko "P1 token: $(echo "$T" | head -c 160)"
I=$(jq -c --arg c "$P1_CODE" 'select(.pfad == "/rest/v1/oauth_codes" and .methode == "POST" and .body.code == $c)' "$LOG" | tail -1)
[ "$(echo "$I" | jq -r '.body.resource // "fehlt"')" = "$BASE" ] \
  && ok "A8 der Code traegt die resource aus der Anfrage" \
  || ko "A8 resource im Code-Insert: $(echo "$I" | jq -r '.body.resource // "fehlt"')"

# ═════════════════════════════════════════════════════════════════════════════
sec "H · /token — der Code ist an client_id, redirect_uri und Verifier gebunden"

tok(){ tok_endpunkt "$(jq -cn "$@")"; }
T=$(tok --arg c "$CLIENT_OK" --arg code "$CODE_T1" --arg r "$REDIR_OK" \
  '{grant_type:"authorization_code", client_id:$c, code:$code, redirect_uri:$r}')
[ "$(echo "$T" | jq -r '.error')" = "invalid_grant" ] && ok "T1 ohne code_verifier -> invalid_grant" || ko "T1: $(echo "$T" | head -c 120)"
T=$(tok --arg c "$CLIENT_FREMD" --arg code "$CODE_T2" --arg r "$REDIR_OK" --arg v "$VERIFIER_OK" \
  '{grant_type:"authorization_code", client_id:$c, code:$code, redirect_uri:$r, code_verifier:$v}')
[ "$(echo "$T" | jq -r '.error')" = "invalid_grant" ] && ok "T2 andere client_id als beim Code -> invalid_grant" || ko "T2: $(echo "$T" | head -c 120)"
T=$(tok --arg c "$CLIENT_OK" --arg code "$CODE_T3" --arg v "$VERIFIER_OK" \
  '{grant_type:"authorization_code", client_id:$c, code:$code, code_verifier:$v}')
[ "$(echo "$T" | jq -r '.error')" = "invalid_grant" ] && ok "T3 ohne redirect_uri -> invalid_grant" || ko "T3: $(echo "$T" | head -c 120)"

T=$(tok --arg c "$CLIENT_OK" --arg code "$CODE_T4" --arg r "$REDIR_OK" \
  '{grant_type:"authorization_code", client_id:$c, code:$code, redirect_uri:$r, code_verifier:"falscher-verifier-0123456789abcdefghijklmnop"}')
# ⚠️ DIE METHODE, nicht nur der Pfad: ein GET auf denselben Pfad hinterliesse
# dieselbe Spur im Log und liesse den Code stehen (bei der Falsifikation so
# gesehen — die erste Fassung pruefte nur den Pfad und blieb gruen).
[ "$(letzte "/rest/v1/oauth_codes?id=eq.$ID_T4" | jq -r '.methode // ""')" = "DELETE" ] \
  && ok "T4a ein fehlgeschlagener Einloeseversuch loescht den Code (DELETE)" \
  || ko "T4a nach dem Fehlversuch kein DELETE auf den Code (Antwort: $(echo "$T" | head -c 80))"
T=$(tok --arg c "$CLIENT_OK" --arg code "$CODE_T4" --arg r "$REDIR_OK" --arg v "$VERIFIER_OK" \
  '{grant_type:"authorization_code", client_id:$c, code:$code, redirect_uri:$r, code_verifier:$v}')
[ "$(echo "$T" | jq -r '.error')" = "invalid_grant" ] \
  && ok "T4 derselbe Code danach mit korrekten Werten -> invalid_grant (verbraucht)" \
  || ko "T4 zweiter Versuch: $(echo "$T" | head -c 120)"

T=$(tok --arg r "$REF_OK" '{grant_type:"refresh_token", client_id:"fremder-client", refresh_token:$r}')
[ "$(echo "$T" | jq -r '.error')" = "invalid_grant" ] && ok "R1 refresh mit anderer client_id -> invalid_grant" || ko "R1: $(echo "$T" | head -c 120)"

# ═════════════════════════════════════════════════════════════════════════════
sec "I · /register — nur plausible Metadaten, ohne Insert bei Verstoss"

REG_OK=0   # erfolgreiche Registrierungen im Lauf — Grundlage fuer J
reg_abgelehnt(){ # fall json erwarteter-fehler
  local vor c; vor=$(client_inserts); c=$(registrieren "$2")
  if [ "$c" = 400 ] && [ "$(jq -r '.error' "$AB")" = "$3" ] && [ "$(client_inserts)" = "$vor" ]; then
    ok "$1: 400 $3, kein Insert"
  else
    ko "$1: HTTP $c, error '$(jq -r '.error' "$AB" 2>/dev/null)' (erwartet $3), Inserts $vor -> $(client_inserts)"
  fi
}
reg_angenommen(){ # fall json
  local vor c; vor=$(client_inserts); c=$(registrieren "$2")
  if [ "${c:0:1}" = 2 ] && [ -n "$(jq -r '.client_id // ""' "$AB")" ] && [ "$(client_inserts)" = $((vor + 1)) ]; then
    ok "$1: HTTP $c, client_id vergeben, genau ein Insert"; REG_OK=$((REG_OK + 1))
  else
    ko "$1: HTTP $c, Antwort $(head -c 100 "$AB"), Inserts $vor -> $(client_inserts)"
  fi
}

reg_abgelehnt "G1 javascript:-URI"        '{"redirect_uris":["javascript:alert(1)"]}'      invalid_redirect_uri
reg_abgelehnt "G1b data:-URI"             '{"redirect_uris":["data:text/html,x"]}'         invalid_redirect_uri
reg_abgelehnt "G1c leeres redirect_uris"  '{"redirect_uris":[]}'                           invalid_redirect_uri
reg_abgelehnt "G1d http auf fremdem Host" '{"redirect_uris":["http://fremd.invalid/cb"]}'  invalid_redirect_uri
reg_abgelehnt "G1e mit Fragment"          '{"redirect_uris":["https://a.invalid/cb#x"]}'   invalid_redirect_uri
reg_abgelehnt "G1f file:-URI"             '{"redirect_uris":["file:///tmp/x"]}'            invalid_redirect_uri
reg_abgelehnt "G1g keine URL"             '{"redirect_uris":["kein url"]}'                 invalid_redirect_uri
reg_abgelehnt "G1h elf Eintraege"         "$(jq -cn '{redirect_uris:[range(11)|"https://a.invalid/cb\(.)"]}')" invalid_redirect_uri
reg_abgelehnt "G1i Eintrag ueber 2000 Zeichen" "$(jq -cn '{redirect_uris:["https://a.invalid/" + ("x"*2000)]}')" invalid_redirect_uri
reg_abgelehnt "G1j unbekannte token_endpoint_auth_method" \
  '{"redirect_uris":["https://a.invalid/cb"],"token_endpoint_auth_method":"private_key_jwt"}' invalid_client_metadata

# GEGENPROBEN — muessen gruen sein und bleiben.
reg_angenommen "P2 https://claude.ai/api/mcp/auth_callback" '{"redirect_uris":["https://claude.ai/api/mcp/auth_callback"],"token_endpoint_auth_method":"none"}'
reg_angenommen "P3 http://localhost:6274/oauth/callback (Inspector)" '{"redirect_uris":["http://localhost:6274/oauth/callback"],"token_endpoint_auth_method":"none"}'
reg_angenommen "P4 cursor:// (Custom Scheme aus der Allowlist)" '{"redirect_uris":["cursor://anysphere.cursor-retrieval/oauth/callback"],"token_endpoint_auth_method":"none"}'

# client_name wird gekuerzt und von Steuerzeichen befreit, bevor er gespeichert wird.
LANGNAME="$(printf 'Name\tmit\001Steuer')$(printf 'x%.0s' $(seq 1 150))"
reg_angenommen "G1k client_name mit Steuerzeichen und Ueberlaenge" "$(jq -cn --arg n "$LANGNAME" '{redirect_uris:["https://name.invalid/cb"], client_name:$n}')"
N=$(jq -r 'select(.pfad == "/rest/v1/oauth_clients" and .methode == "POST") | .body.client_name' "$LOG" | tail -1)
{ [ ${#N} -le 100 ] && ! printf '%s' "$N" | grep -q '[[:cntrl:]]'; } \
  && ok "G1l gespeicherter client_name: ${#N} Zeichen, keine Steuerzeichen" \
  || ko "G1l gespeicherter client_name: ${#N} Zeichen, Steuerzeichen $(printf '%s' "$N" | grep -c '[[:cntrl:]]')"

# ═════════════════════════════════════════════════════════════════════════════
sec "J · /register — 20 Registrierungen pro Stunde und IP"

# Gezaehlt werden ANGENOMMENE Registrierungen: die abgelehnten aus I kommen vor
# dem Zaehler und schreiben nichts, auch nicht ins KV. Deshalb steht die Grenze
# nach genau 20 Annahmen im ganzen Lauf, nicht nach 20 Anfragen.
ERSTE_429=""
for i in $(seq 1 25); do
  vor=$(client_inserts)
  c=$(registrieren '{"redirect_uris":["https://limit.invalid/cb"],"token_endpoint_auth_method":"none"}')
  if [ "$c" = 429 ]; then
    ERSTE_429="$REG_OK"; [ "$(client_inserts)" = "$vor" ] || ERSTE_429="$ERSTE_429+insert"
    break
  fi
  [ "${c:0:1}" = 2 ] && REG_OK=$((REG_OK + 1))
done
[ "$ERSTE_429" = 20 ] \
  && ok "G2 die 21. Registrierung im Lauf wird mit 429 abgelehnt, ohne Insert" \
  || ko "G2 erste 429 nach '${ERSTE_429:-keiner}' angenommenen Registrierungen (erwartet 20, ohne Insert)"

# ═════════════════════════════════════════════════════════════════════════════
sec "E · Selbstpruefung der Tabelle"

FEHLT=""
for P in /rest/v1/rpc/gk_oauth_token_by_access /rest/v1/rpc/gk_oauth_token_by_refresh /rest/v1/rpc/gk_oauth_code_by_code; do
  hat_pfad "$P" || FEHLT="$FEHLT $P"
done
[ -z "$FEHLT" ] \
  && ok "alle drei RPCs kamen im Lauf vor" \
  || ko "nicht gerufen:$FEHLT — die zugehoerigen Abschnitte haben nichts gemessen (§18a a)"

# Die Abschnitte F–J brauchen vier weitere Wege im Fake. Kam einer nie vor,
# haben die Faelle daran nichts gemessen — etwa ein 400 ohne jeden Client-Lookup.
FEHLT=""
jq -e 'select(.pfad | startswith("/rest/v1/oauth_clients?")) | select(.methode == "GET")' "$LOG" >/dev/null 2>&1 || FEHLT="$FEHLT client-lookup"
jq -e 'select(.pfad == "/rest/v1/oauth_codes" and .methode == "POST")' "$LOG" >/dev/null 2>&1 || FEHLT="$FEHLT code-insert"
jq -e 'select(.body.action == "validate_token")' "$LOG" >/dev/null 2>&1 || FEHLT="$FEHLT validate_token"
jq -e 'select(.pfad == "/rest/v1/oauth_clients" and .methode == "POST")' "$LOG" >/dev/null 2>&1 || FEHLT="$FEHLT client-insert"
[ -z "$FEHLT" ] \
  && ok "Client-Lookup, Code-Insert, validate_token und Client-Insert kamen im Lauf vor" \
  || ko "nicht vorgekommen:$FEHLT (§18a a)"

SCHREIB=$(jq -r 'select(.methode == "PATCH" or .methode == "DELETE" or (.methode == "POST" and .pfad == "/rest/v1/oauth_tokens")) | .methode' "$LOG" | sort -u | tr '\n' ' ')
case "$SCHREIB" in
  *PATCH*) case "$SCHREIB" in *DELETE*) ok "beide Schreibwege kamen vor ($SCHREIB)";; *) ko "kein DELETE im Lauf ($SCHREIB)";; esac ;;
  *) ko "kein PATCH im Lauf ($SCHREIB) — die Schreib-Assertions belegen nichts" ;;
esac

ende
