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

# ── Der Fake ─────────────────────────────────────────────────────────────────
# Er spricht die drei RPCs aus supabase#124 und die Schreibpfade dahinter. Die
# ALTEN Wege (`?access_token=eq.` usw.) beantwortet er mit 500: liefe der Worker
# noch dort hin, faende die Assertion unten den Wert in der URL — und der
# Aufruf ginge zusaetzlich sichtbar schief.
cat > "$FIX/fake.mjs" <<'FAKE'
import { createServer } from "node:http";
import { appendFileSync } from "node:fs";

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
const codeZeile = {
  id: E.ID_CODE, client_id: "test-client", redirect_uri: "https://client.invalid/cb",
  expires_at: jetzt + 600_000, resource: null,
  code_challenge: null, code_challenge_method: null,
  scope: "mcp:read", user_token: "gk_view_faketoken",
  is_demo: false, mcp_client: "claude", lang: "de",
};

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
      return sende(200, body.p_code === E.CODE_OK ? [codeZeile] : []);
    }
    if (req.url.startsWith("/rest/v1/rpc/resolve_user_token")) return sende(200, "11111111-1111-1111-1111-111111111111");
    if (req.url.startsWith("/rest/v1/rpc/gk_meter")) return sende(200, [{ over_limit: false, new_count: 1, effective_limit: 100000 }]);

    // Schreibpfade — erlaubt ist nur der Filter auf die id.
    if (req.url.startsWith("/rest/v1/oauth_tokens?id=eq.") && req.method === "PATCH") return sende(204, {});
    if (req.url === "/rest/v1/oauth_tokens" && req.method === "POST") return sende(201, {});
    if (req.url.startsWith("/rest/v1/oauth_codes?id=eq.") && req.method === "DELETE") return sende(204, {});

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
( cd "$REPO_ROOT" && npx --no-install wrangler dev \
    --port "$DEV_PORT" --ip 127.0.0.1 --show-interactive-dev-session false \
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

T=$(tok_endpunkt "{\"grant_type\":\"authorization_code\",\"client_id\":\"test-client\",\"code\":\"$CODE_OK\"}")
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
sec "E · Selbstpruefung der Tabelle"

FEHLT=""
for P in /rest/v1/rpc/gk_oauth_token_by_access /rest/v1/rpc/gk_oauth_token_by_refresh /rest/v1/rpc/gk_oauth_code_by_code; do
  hat_pfad "$P" || FEHLT="$FEHLT $P"
done
[ -z "$FEHLT" ] \
  && ok "alle drei RPCs kamen im Lauf vor" \
  || ko "nicht gerufen:$FEHLT — die zugehoerigen Abschnitte haben nichts gemessen (§18a a)"

SCHREIB=$(jq -r 'select(.methode == "PATCH" or .methode == "DELETE" or (.methode == "POST" and .pfad == "/rest/v1/oauth_tokens")) | .methode' "$LOG" | sort -u | tr '\n' ' ')
case "$SCHREIB" in
  *PATCH*) case "$SCHREIB" in *DELETE*) ok "beide Schreibwege kamen vor ($SCHREIB)";; *) ko "kein DELETE im Lauf ($SCHREIB)";; esac ;;
  *) ko "kein PATCH im Lauf ($SCHREIB) — die Schreib-Assertions belegen nichts" ;;
esac

ende
