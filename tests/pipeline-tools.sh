#!/usr/bin/env bash
# GrowthKit MCP Worker — Testtabelle fuer die ADAPTER-Schicht von tools/call:
# die drei Pipeline-Tools aus specs/SPEC-lead-signals.md §6 (Abschnitte A-D) und
# die Argument-Allowlist, die fuer ALLE Tools davorsteht (Abschnitt F).
#
#   bash tests/pipeline-tools.sh
#   FAKE_MODE=wrap409 bash tests/pipeline-tools.sh    # Rotlauf, siehe Abschnitt C
#
# Der Dateiname bleibt `pipeline-tools.sh`, obwohl Abschnitt F ueber die drei
# Tools hinausgeht: er steht in .github/workflows/ci.yml und in AGENTS.md, und
# eine Umbenennung waere ein eigener Vorgang mit eigener Verifikation. Der
# Gegenstand ist in beiden Faellen derselbe — was der Worker aus `arguments`
# baut, bevor ein Handler es sieht.
#
# ─────────────────────────────────────────────────────────────────────────────
# WAS HIER LAEUFT — UND WARUM NICHT GEGEN PRODUKTION.
#
# Gegenstand ist die ADAPTER-Schicht: was der Worker aus `arguments` baut, an
# welchen Endpunkt er es schickt, und was er von der Antwort an den Client
# durchreicht. Das ist genau die Schicht, die weder `probe.sh` (kennt nur
# tools/list) noch `authed-smoke.sh` (braucht Produktionsdaten und einen
# view-Token) pruefen kann.
#
# Deshalb: eine ECHTE Worker-Instanz (`wrangler dev`) gegen eine FALSCHE
# Supabase. Der Fake spricht die drei Endpunkte, die dieser Pfad braucht
# (resolve_user_token, campaign-pipeline, n8n-embed), protokolliert JEDE
# Anfrage und antwortet mit den Fixtures unten.
#
# ⚠️ Das ist kein Ersatz fuer einen Live-Lauf, und es soll keiner sein. Was hier
# NICHT geprueft wird: ob campaign-pipeline sich so verhaelt wie die Fixtures
# behaupten. Das steht in supabase#61 (7 Deno-Tests, Live-Laeufe gegen Prod) und
# gehoert dorthin — ein Adapter-Test, der das Backend mitprueft, prueft am Ende
# beides schlecht. Die Fixtures sind die NAHTSTELLE zwischen beiden Repos.
#
# ⚠️ WARUM NICHT GEGEN DIE ECHTE SUPABASE. `pipelineRun` ist admin/team; der
# einzige Token auf dieser Maschine ist `gk_view_` (.gk-ci-token, bewusst so —
# AGENTS.md). Ein Lauf gegen Prod braeuchte also einen schreibfaehigen Token
# gegen echte Workspace-Daten, und die Preview-Versionen haengen an denselben
# Bindings wie Production ("Probes duerfen nur lesen").
# ─────────────────────────────────────────────────────────────────────────────
#
# ══ FIXTURES ══════════════════════════════════════════════════════════════════
# Herkunft, damit niemand sie fuer erfunden haelt:
#
#   * Die ZAHLEN sind am 02.09.2026 gegen die Produktions-View
#     `campaign_lead_priority` gemessen (read-only SQL), mit derselben Logik, die
#     `_shared/pipeline-stages.ts` faehrt — funnel() und kandidaten() Zeile fuer
#     Zeile nachgebildet. Sie decken sich mit der Known-Result-Tabelle in
#     supabase#61 bis auf EINE Zahl, und die ist der interessante Fall:
#     #61 mass `active_signal = 4` (gate_column `active_signals`), heute sind es
#     3 — Migration #62 hat `strong_signals` gebracht, und eines der vier Signale
#     ist schwach (`type='other'` und confidence < 0.7). Das Gate ist seit #62
#     also das spezifizierte, und der Fixture-Wert bildet den NEUEN Zustand ab.
#
#   * Die IDENTITAETEN sind ersetzt. Firmennamen und Lead-UUIDs sind Kundendaten,
#     und dieses Repo ist OEFFENTLICH (AGENTS.md). Ersetzt ist nur, was niemand
#     zum Pruefen braucht: die Zahlen, die Schluessel und die Form sind echt.
#     Die Kampagnen-UUIDs stehen ohnehin in der Spec.
# ══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKE_MODE="${FAKE_MODE:-echt}"

PASS=0; FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
ko(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
sec(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
ende(){ printf '\n\033[1mErgebnis: %s grün, %s rot\033[0m\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

printf '\n\033[1m%s\033[0m  (FAKE_MODE=%s)\n' "pipeline-tools — $REPO_ROOT/index.js" "$FAKE_MODE"

for w in node jq curl; do
  command -v "$w" >/dev/null 2>&1 || { ko "$w fehlt — die Suite kann nicht laufen"; ende; exit 2; }
done
[ -f "$REPO_ROOT/index.js" ] || { ko "index.js nicht gefunden"; ende; exit 2; }

FIX=$(mktemp -d)
FAKE_PID=""; DEV_PID=""
aufraeumen(){
  # ⚠️ `kill $DEV_PID` allein reicht NICHT: das ist die Subshell, `npx` startet
  # darunter drei weitere Prozesse (sh -> node wrangler -> workerd). Beim Bauen
  # dieser Suite blieben so mehrere Instanzen auf zufaelligen Ports zurueck.
  # Der Port ist je Lauf eindeutig, das Muster trifft deshalb genau die eigene
  # Instanz und keine fremde `wrangler dev`-Sitzung des Entwicklers.
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

# ── Der Fake ─────────────────────────────────────────────────────────────────
# Er ist ein HANDLER, keine Konservendose: er liest `action`, `stage`, `dry_run`
# und `confirm_credits` und entscheidet daraus, wie campaign-pipeline es tut.
# Sonst koennte die Suite nicht pruefen, dass der Worker die Parameter ueberhaupt
# schickt — sie bekaeme dieselbe Antwort auch fuer einen leeren Body.
cat > "$FIX/fake.mjs" <<'FAKE'
import { createServer } from "node:http";
import { appendFileSync } from "node:fs";

const LOG = process.env.LOG_PATH;
const MODE = process.env.FAKE_MODE ?? "echt";

// Q3-B2B-Sales-Pilot — gemessen 02.09.2026 (siehe Kopf der Suite).
const STATUS_Q3 = {
  campaign_id: "38fee505-00db-45ca-8f0a-101dcf5b12ab",
  campaign_name: "Q3-B2B-Sales-Pilot",
  gate_column: "strong_signals",
  funnel: {
    leads: 34, domain: 34, firmographics: 5, scored: 5, fit_gate: 0,
    signals_scanned: 0, active_signal: 3, email: 34, phone: 1, max_score: 55,
  },
  pending: { resolve: 29, score: 0, signals: 0, reveal: 0, rescore: 33 },
  top_10: [
    { lead_id: "00000000-0000-4000-8000-000000000001", company_name: "Lead A", priority_rank: 1, score: 55, active_signals: 1, has_email: true },
    { lead_id: "00000000-0000-4000-8000-000000000002", company_name: "Lead B", priority_rank: 2, score: 42, active_signals: 1, has_email: true },
  ],
};

// MedTech-Kern-DACH-KMU-GTM-Q3-2026, `run signals dry_run` — vier Kandidaten
// (score >= 60, nie gescannt), Scores 75/75/68/61, signals kostet nichts.
const DRY_SIGNALS_MEDTECH = {
  dry_run: true,
  stage: "signals",
  gate_column: "strong_signals",
  candidates: [
    { lead_id: "00000000-0000-4000-8000-000000000011", campaign_lead_id: "00000000-0000-4000-8000-0000000000a1", company_name: "Lead C", score: 75 },
    { lead_id: "00000000-0000-4000-8000-000000000012", campaign_lead_id: "00000000-0000-4000-8000-0000000000a2", company_name: "Lead D", score: 75 },
    { lead_id: "00000000-0000-4000-8000-000000000013", campaign_lead_id: "00000000-0000-4000-8000-0000000000a3", company_name: "Lead E", score: 68 },
    { lead_id: "00000000-0000-4000-8000-000000000014", campaign_lead_id: "00000000-0000-4000-8000-0000000000a4", company_name: "Lead F", score: 61 },
  ],
  candidate_count: 4,
  total_pending: 4,
  estimated_credits: 0,
};

// Das mechanische Credit-Gate, Wortlaut aus _shared/pipeline-stages.ts:
// pruefeCreditGate("reveal", 30, undefined, 10) — derselbe Fall, den supabase#61
// als Rotlauf protokolliert.
const GATE_409 = {
  stage: "reveal", candidates: 10, estimated_credits: 30,
  error: "confirm_credits required",
  hint: "Erneut mit confirm_credits=30 aufrufen.",
};

// Antwort von update_campaign mit Scoring-Profil: n8n-embed gibt zurueck, was
// der SCORER aus dem Block lesen wuerde — nicht, was geschickt wurde.
const UPDATE_CAMPAIGN = {
  success: true,
  campaign: { id: "38fee505-00db-45ca-8f0a-101dcf5b12ab", name: "Q3-B2B-Sales-Pilot", status: "active", updated_at: "2026-09-03T08:00:00Z" },
  scoring_profile: { industries: ["ERP"], geo: ["CH"], employees: { min: 50, max: 500, gate: false } },
};

// ⚠️ ECHTE ANTWORT, am 03.09.2026 ueber mcp.growthkit.tools mit dem view-Token
// geholt (Axept Business Software, lead_id 25a68d58…): 1 Signal, acquisition,
// observed 2026-08-27, confidence 0.8, source_label null — `cite` faellt
// deshalb aus dem Host der source_url. Firmenname und UUIDs sind ersetzt, die
// Form und `cite` sind woertlich uebernommen.
const SIGNALE = {
  success: true, count: 1, active_only: true,
  signals: [{
    id: "00000000-0000-4000-8000-0000000000f1",
    lead_id: "00000000-0000-4000-8000-000000000011",
    campaign_id: "7ed61251-14c1-4017-976b-dece91f96ea3",
    // type, Datum, TTL, confidence und `cite` sind die Werte der echten Antwort;
    // ersetzt ist nur der Satz selbst und die Quell-URL (er nennt zwei reale
    // Firmen). `source_label: null` ist ebenfalls echt — genau deshalb faellt
    // `cite` aus dem Host der URL, und das ist der Pfad, der geprueft gehoert.
    type: "acquisition", signal: "Uebernahme durch einen Netzbetreiber angekuendigt.",
    source_url: "https://www.ad-hoc-news.invalid/wirtschaft/uebernahme/70011196",
    source_label: null, observed_at: "2026-08-27", expires_at: "2027-02-23",
    confidence: 0.8, provenance: "auto:lead-signals-enrich", company_name: "Lead C",
    cite: "ad-hoc-news, 27. August 2026",
  }],
};

// Dieselbe Zeile mit lang=en. zitatDatum() setzt im Englischen KEIN Komma
// zwischen Tag und Jahr ("August 27 2026") — woertlich aus _shared/signal-cite.ts,
// nicht nachempfunden.
const SIGNALE_EN = JSON.parse(JSON.stringify(SIGNALE));
SIGNALE_EN.signals[0].cite = "ad-hoc-news, August 27 2026";

createServer((req, res) => {
  let roh = "";
  req.on("data", (c) => (roh += c));
  req.on("end", () => {
    let body = {};
    try { body = JSON.parse(roh || "{}"); } catch { /* Form ist Teil der Pruefung */ }
    appendFileSync(LOG, JSON.stringify({ pfad: req.url, body }) + "\n");
    const sende = (status, daten) => {
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(daten));
    };

    if (req.url.startsWith("/rest/v1/rpc/resolve_user_token")) {
      return sende(200, "11111111-1111-1111-1111-111111111111");
    }
    if (req.url.startsWith("/rest/v1/rpc/gk_meter")) {
      return sende(200, [{ over_limit: false, new_count: 1, effective_limit: 100000 }]);
    }
    if (req.url.startsWith("/functions/v1/campaign-pipeline")) {
      if (body.action === "status") return sende(200, STATUS_Q3);
      if (body.action === "run") {
        if (body.dry_run === true) return sende(200, DRY_SIGNALS_MEDTECH);
        if (body.stage === "reveal" && body.confirm_credits === undefined) {
          // ⚠️ HIER HAENGT ABSCHNITT C. `wrap409` liefert DENSELBEN Rumpf mit
          // Status 200 — ein Backend, das den Fehler in eine Erfolgsantwort
          // verpackt. Der Worker meldet dann isError:false, und eine Assertion,
          // die nur den Text liest, bliebe gruen.
          return sende(MODE === "wrap409" ? 200 : 409, GATE_409);
        }
        return sende(200, { stage: body.stage, processed: 0, succeeded: 0, failed: [], credits_used: 0, next_cursor: null });
      }
      return sende(400, { error: "action must be 'status' or 'run'" });
    }
    if (req.url.startsWith("/functions/v1/n8n-embed")) {
      if (body.action === "list_lead_signals") {
        // 404 statt leerer Liste — der Wortlaut stammt aus n8n-embed (#71).
        // "0 Signale" und "diese ID gibt es nicht" sind zwei Befunde, und der
        // Agent kann sie an einer leeren Liste nicht unterscheiden.
        // ⚠️ Der Fake kennt GENAU die beiden IDs seiner Fixture und antwortet
        // auf alles andere mit 404 — wie das Backend, das beide Tabellen fragt
        // und erst dann aufgibt. Ein Praefix-Muster waere hier schiefgegangen:
        // die anonymisierten Fixture-UUIDs beginnen selbst mit Nullen.
        const BEKANNT = new Set([
          "00000000-0000-4000-8000-000000000011",
          "00000000-0000-4000-8000-0000000000a1",
        ]);
        const roh = body.lead_id ?? body.campaign_lead_id;
        if (roh && !BEKANNT.has(roh)) {
          return sende(404, {
            error: `Keine Entitaet mit der UUID ${roh} gefunden — weder als leads.id noch als ` +
              `campaign_leads.id in diesem Konto.`,
          });
        }
        return sende(200, body.lang === "en" ? SIGNALE_EN : SIGNALE);
      }
      if (body.action === "update_campaign") return sende(200, UPDATE_CAMPAIGN);
      return sende(400, { error: `unerwartete action: ${body.action}` });
    }
    if (req.url.startsWith("/functions/v1/n8n-proxy")) {
      return sende(200, { found: true, echo_params: body.params ?? null });
    }
    return sende(404, { error: `unerwarteter Pfad: ${req.url}` });
  });
}).listen(Number(process.env.PORT), "127.0.0.1");
FAKE

LOG_PATH="$LOG" FAKE_MODE="$FAKE_MODE" PORT="$FAKE_PORT" node "$FIX/fake.mjs" &
FAKE_PID=$!

for _ in $(seq 1 40); do
  curl -s -m 2 -o /dev/null "http://127.0.0.1:$FAKE_PORT/rest/v1/rpc/resolve_user_token" -X POST -d '{}' && break
  sleep 0.1
done
if curl -s -m 2 -X POST "http://127.0.0.1:$FAKE_PORT/rest/v1/rpc/resolve_user_token" -d '{}' | grep -q 1111; then
  ok "Fake-Backend laeuft auf 127.0.0.1:$FAKE_PORT"
else
  ko "Fake-Backend antwortet nicht — alles darunter waere ein Test gegen nichts"; ende; exit 2
fi

# ── Die Instanz ──────────────────────────────────────────────────────────────
# --var statt .dev.vars: eine Datei anzulegen ueberschriebe die eines
# Entwicklers, und die Werte hier sind Attrappen (§18a h — die Umgebung wird
# HERGESTELLT, nicht vorausgesetzt).
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

bereit=0
for _ in $(seq 1 120); do
  if mcp "" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq -e '.result.tools | type == "array"' >/dev/null 2>&1; then
    bereit=1; break
  fi
  sleep 0.5
done
[ "$bereit" = 1 ] || { ko "wrangler dev wurde nicht bereit — Log: $(tail -3 "$FIX/wrangler.log" | tr '\n' ' ')"; ende; exit 2; }

# §18a (g): ist die laufende Instanz DIESER Checkout? Eine alte Instanz auf einem
# anderen Port waere sonst der stille Pruefling.
VER_DATEI=$(grep -m1 'const SERVER_VERSION' "$REPO_ROOT/index.js" | sed 's/.*"\(.*\)".*/\1/')
VER_LIVE=$(mcp "" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | jq -r '.result.serverInfo.version // ""')
if [ -n "$VER_DATEI" ] && [ "$VER_DATEI" = "$VER_LIVE" ]; then
  ok "Instanz serviert diesen Checkout (SERVER_VERSION $VER_LIVE)"
else
  ko "Instanz-Version '$VER_LIVE' != Datei '$VER_DATEI' — der Pruefling ist ein anderer"
fi

TOK_TEAM="gk_team_testtoken"; TOK_VIEW="gk_view_testtoken"
letzte(){ jq -c --arg p "$1" 'select(.pfad | startswith($p))' "$LOG" | tail -1; }
ruf(){ # token name args-json  -> result-JSON
  mcp "$1" "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":$3}}"
}
text(){ jq -r '.result.content[0].text // ""'; }

# Ausgangs-Zaehler fuer die Selbstpruefung in E (§18a a/d): ein Lauf, in dem
# jeder Aufruf als Fehler ODER jeder als Erfolg endet, besteht die halbe Tabelle
# aus dem falschen Grund.
N_ERR=0; N_OK=0
buche(){ case "$1" in true) N_ERR=$((N_ERR+1));; false) N_OK=$((N_OK+1));; esac; }

# ═════════════════════════════════════════════════════════════════════════════
sec "A · Nutzlast — was der Worker an die Edge Function schickt (Spec §6)"

ruf "$TOK_TEAM" pipelineStatus '{"campaign_id":"38fee505-00db-45ca-8f0a-101dcf5b12ab"}' >/dev/null
P=$(letzte "/functions/v1/campaign-pipeline")
if [ -z "$P" ]; then
  ko "campaign-pipeline wurde gar nicht gerufen — die Assertions darunter liefen gegen eine leere Menge (§18a a)"
else
  [ "$(echo "$P" | jq -r '.body.action')" = "status" ] \
    && ok "pipelineStatus -> action=status" || ko "pipelineStatus schickt action=$(echo "$P" | jq -r '.body.action')"
  [ "$(echo "$P" | jq -r '.body.campaign_id')" = "38fee505-00db-45ca-8f0a-101dcf5b12ab" ] \
    && ok "campaign_id kommt an" || ko "campaign_id fehlt oder ist falsch"
  [ "$(echo "$P" | jq -r '.body.user_token')" = "$TOK_TEAM" ] \
    && ok "user_token ist der aufgeloeste Bearer, nicht aus arguments" || ko "user_token falsch: $(echo "$P" | jq -r '.body.user_token')"
fi

# Alle acht Parameter aus Spec §6, mit Werten, die sich von den Defaults
# unterscheiden — ein Adapter, der Defaults selbst setzt statt durchzureichen,
# faellt sonst nicht auf.
ruf "$TOK_TEAM" pipelineRun '{"campaign_id":"7ed61251-14c1-4017-976b-dece91f96ea3","stage":"signals","limit":25,"min_score":70,"require_signal":false,"with_phone":true,"dry_run":true}' >/dev/null
P=$(letzte "/functions/v1/campaign-pipeline")
FEHLT=""
for kv in 'action=run' 'stage=signals' 'limit=25' 'min_score=70' 'require_signal=false' 'with_phone=true' 'dry_run=true' 'campaign_id=7ed61251-14c1-4017-976b-dece91f96ea3'; do
  k=${kv%%=*}; v=${kv#*=}
  [ "$(echo "$P" | jq -r --arg k "$k" '.body[$k] | tostring')" = "$v" ] || FEHLT="$FEHLT $k"
done
[ -z "$FEHLT" ] \
  && ok "pipelineRun reicht alle acht Parameter der Spec-Tabelle durch" \
  || ko "pipelineRun verliert oder verfaelscht:$FEHLT"

ruf "$TOK_TEAM" listLeadSignals '{"lead_id":"00000000-0000-4000-8000-000000000011","active_only":false,"limit":7}' >/dev/null
E=$(letzte "/functions/v1/n8n-embed")
if [ -z "$E" ]; then
  ko "n8n-embed wurde nicht gerufen — listLeadSignals nimmt einen anderen Weg als die Spec sagt"
else
  [ "$(echo "$E" | jq -r '.body.action')" = "list_lead_signals" ] \
    && ok "listLeadSignals -> n8n-embed action=list_lead_signals" || ko "falsche action: $(echo "$E" | jq -r '.body.action')"
  [ "$(echo "$E" | jq -r '.body.lead_id')" = "00000000-0000-4000-8000-000000000011" ] \
    && ok "lead_id kommt an" || ko "lead_id fehlt"
  [ "$(echo "$E" | jq -r '.body.active_only | tostring')" = "false" ] \
    && ok "active_only=false wird durchgereicht (nicht vom Default verschluckt)" || ko "active_only wurde verschluckt"
  [ "$(echo "$E" | jq -r '.body.limit | tostring')" = "7" ] \
    && ok "limit kommt an" || ko "limit fehlt"
fi

# ═════════════════════════════════════════════════════════════════════════════
sec "B · Known Result — die gemessenen Zahlen kommen unveraendert beim Client an"

R=$(ruf "$TOK_TEAM" pipelineStatus '{"campaign_id":"38fee505-00db-45ca-8f0a-101dcf5b12ab"}')
S=$(echo "$R" | text)
if ! echo "$S" | jq -e . >/dev/null 2>&1; then
  ko "die status-Antwort kommt nicht als JSON beim Client an: ${S:0:120}"
else
  ABW=""
  for kv in 'leads=34' 'domain=34' 'firmographics=5' 'scored=5' 'fit_gate=0' 'signals_scanned=0' 'active_signal=3' 'email=34' 'phone=1' 'max_score=55'; do
    k=${kv%%=*}; v=${kv#*=}
    [ "$(echo "$S" | jq -r --arg k "$k" '.funnel[$k] | tostring')" = "$v" ] || ABW="$ABW $k"
  done
  [ -z "$ABW" ] \
    && ok "alle zehn Funnel-Zahlen der Q3-Kampagne unveraendert (34/34/5/5/0/0/3/34/1/55)" \
    || ko "Funnel-Zahlen weichen ab:$ABW"
  [ "$(echo "$S" | jq -r '.pending.rescore')" = "33" ] \
    && ok "pending.rescore = 33 — der updated_at-Merge aus supabase#61 ist sichtbar" \
    || ko "pending.rescore != 33"
  [ "$(echo "$S" | jq -r '.gate_column')" = "strong_signals" ] \
    && ok "gate_column = strong_signals (seit Migration #62 das spezifizierte Gate)" \
    || ko "gate_column ist nicht strong_signals"
fi

R=$(ruf "$TOK_TEAM" pipelineRun '{"campaign_id":"7ed61251-14c1-4017-976b-dece91f96ea3","stage":"signals","dry_run":true}')
S=$(echo "$R" | text)
[ "$(echo "$S" | jq -r '.candidate_count')" = "4" ] && [ "$(echo "$S" | jq -r '.total_pending')" = "4" ] \
  && ok "dry_run signals auf MedTech: 4 Kandidaten, 4 pending" \
  || ko "dry_run-Zahlen weichen ab: candidate_count=$(echo "$S" | jq -r '.candidate_count') total_pending=$(echo "$S" | jq -r '.total_pending')"
[ "$(echo "$S" | jq -r '.estimated_credits')" = "0" ] \
  && ok "signals kostet 0 Credits — die Stufe laeuft ohne Bestaetigung" \
  || ko "estimated_credits fuer signals ist nicht 0"
buche "$(echo "$R" | jq -r '.result.isError')"
[ "$(echo "$R" | jq -r '.result.isError')" = "false" ] \
  && ok "der dry_run ist kein Fehler (isError=false)" || ko "dry_run kam als isError durch"

# ═════════════════════════════════════════════════════════════════════════════
sec "C · Das mechanische Credit-Gate — 409 unveraendert durchgereicht"

# ⚠️ DIE ZWEITE HAELFTE IST DIE EIGENTLICHE. Dass der TEXT des 409 ankommt,
# belegt nichts ueber den Status: `callEdge` liest den Rumpf so oder so. Erst
# `isError` traegt die Unterscheidung zum Client. Deshalb pruefen beide Haelften
# hier nebeneinander, und `FAKE_MODE=wrap409` faehrt genau die Luecke dazwischen
# vor (Rotlauf im Commit-Body).
R=$(ruf "$TOK_TEAM" pipelineRun '{"campaign_id":"7ed61251-14c1-4017-976b-dece91f96ea3","stage":"reveal","dry_run":false}')
S=$(echo "$R" | text)
[ "$(echo "$S" | jq -r '.error')" = "confirm_credits required" ] \
  && ok "der Fehlertext des Backends kommt woertlich an" || ko "Fehlertext fehlt oder lautet anders: $(echo "$S" | jq -r '.error // "<nichts>"')"
[ "$(echo "$S" | jq -r '.estimated_credits')" = "30" ] && [ "$(echo "$S" | jq -r '.candidates')" = "10" ] \
  && ok "die frische Schaetzung (30 Credits, 10 Kandidaten) kommt mit — ohne sie kann der Agent nichts zeigen" \
  || ko "estimated_credits/candidates fehlen im durchgereichten 409"
[ -n "$(echo "$S" | jq -r '.hint // ""')" ] \
  && ok "der Hinweistext des Backends ueberlebt die Weitergabe" || ko "hint verschwunden"
buche "$(echo "$R" | jq -r '.result.isError')"
[ "$(echo "$R" | jq -r '.result.isError')" = "true" ] \
  && ok "isError=true — der 409 kommt als FEHLER an, nicht als Erfolg" \
  || ko "isError=$(echo "$R" | jq -r '.result.isError') — ein 409 wird dem Client als Erfolg gemeldet"

# GEGENRICHTUNG: mit passendem confirm_credits darf nichts davon zuschlagen.
# Ohne diesen Fall waere ein Adapter, der IMMER isError meldet, oben gruen.
R=$(ruf "$TOK_TEAM" pipelineRun '{"campaign_id":"7ed61251-14c1-4017-976b-dece91f96ea3","stage":"reveal","dry_run":false,"confirm_credits":30}')
buche "$(echo "$R" | jq -r '.result.isError')"
[ "$(echo "$R" | jq -r '.result.isError')" = "false" ] \
  && ok "GEGENRICHTUNG: mit confirm_credits laeuft der Aufruf als Erfolg durch" \
  || ko "auch der bestaetigte Lauf kommt als Fehler an — die vier Pruefungen darueber belegen dann nichts"

# ═════════════════════════════════════════════════════════════════════════════
sec "D · Rollengrenze — und die Umgehung ueber arguments"

L=$(mcp "$TOK_VIEW" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq -r '.result.tools[].name' | sort)
echo "$L" | grep -qx pipelineStatus  && ok "view sieht pipelineStatus"  || ko "view sieht pipelineStatus nicht"
echo "$L" | grep -qx listLeadSignals && ok "view sieht listLeadSignals" || ko "view sieht listLeadSignals nicht"
echo "$L" | grep -qx pipelineRun     && ko "view sieht pipelineRun — die Rollen-Map greift nicht" || ok "view sieht pipelineRun NICHT"

LT=$(mcp "$TOK_TEAM" '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | jq -r '.result.tools[].name' | sort)
echo "$LT" | grep -qx pipelineRun \
  && ok "GEGENRICHTUNG: team sieht pipelineRun — die Liste ist nicht generell leer" \
  || ko "auch team sieht pipelineRun nicht; der Fall darueber belegt dann nichts"

R=$(ruf "$TOK_VIEW" pipelineRun '{"campaign_id":"7ed61251-14c1-4017-976b-dece91f96ea3","stage":"reveal"}')
echo "$R" | text | grep -q "Permission denied" \
  && ok "view: tools/call auf pipelineRun wird abgelehnt" || ko "view darf pipelineRun aufrufen: $(echo "$R" | text | head -c 80)"

# ⚠️ DER FALL, DER DIESE SUITE RECHTFERTIGT. `arguments` wird nirgends gegen
# inputSchema validiert. Stuende `action` VOR dem Spread, koennte ein
# view-Token ueber pipelineStatus eine bezahlte Stage fahren — an der
# Rollen-Map vorbei und ungemetert.
ruf "$TOK_VIEW" pipelineStatus '{"campaign_id":"38fee505-00db-45ca-8f0a-101dcf5b12ab","action":"run","stage":"reveal","dry_run":false}' >/dev/null
P=$(letzte "/functions/v1/campaign-pipeline")
if [ -z "$P" ]; then
  ko "kein Aufruf protokolliert — der Umgehungsfall hat gar nichts gemessen (§18a a)"
else
  [ "$(echo "$P" | jq -r '.body.action')" = "status" ] \
    && ok "action aus arguments wird UEBERSCHRIEBEN: das Backend sieht status" \
    || ko "ESKALATION: ein view-Token hat ueber pipelineStatus action=$(echo "$P" | jq -r '.body.action') gefahren"
fi
ruf "$TOK_VIEW" pipelineStatus '{"campaign_id":"38fee505-00db-45ca-8f0a-101dcf5b12ab","user_token":"gk_fremder_token"}' >/dev/null
P=$(letzte "/functions/v1/campaign-pipeline")
[ "$(echo "$P" | jq -r '.body.user_token')" = "$TOK_VIEW" ] \
  && ok "user_token aus arguments wird ebenso ueberschrieben" \
  || ko "ein mitgeschickter user_token gewinnt gegen den Bearer: $(echo "$P" | jq -r '.body.user_token')"

# ═════════════════════════════════════════════════════════════════════════════
sec "E · listLeadSignals — beide UUID-Formen, cite, Sprache, 404"

# Die Entitaets-Aufloesung sitzt im Backend (#71); hier wird geprueft, dass der
# Adapter beide Parameter ueberhaupt weiterreicht. Vor diesem Commit kam
# `campaign_lead_id` nirgends an — live gegen Produktion nachgestellt:
# n8n-embed antwortete "lead_id or campaign_id is required", weil der Worker den
# Parameter gar nicht kannte.
ruf "$TOK_TEAM" listLeadSignals '{"campaign_lead_id":"00000000-0000-4000-8000-0000000000a1"}' >/dev/null
E=$(letzte "/functions/v1/n8n-embed")
[ "$(echo "$E" | jq -r '.body.campaign_lead_id')" = "00000000-0000-4000-8000-0000000000a1" ] \
  && ok "campaign_lead_id kommt beim Backend an" \
  || ko "campaign_lead_id fehlt im Payload — der Aufruf laeuft ins 'lead_id or campaign_id is required'"

R=$(ruf "$TOK_TEAM" listLeadSignals '{"lead_id":"00000000-0000-4000-8000-000000000011"}')
S=$(echo "$R" | text)
[ "$(echo "$S" | jq -r '.signals[0].cite')" = "ad-hoc-news, 27. August 2026" ] \
  && ok "cite kommt woertlich beim Client an (Quelle + Datum, fertig formatiert)" \
  || ko "cite fehlt oder ist veraendert: $(echo "$S" | jq -r '.signals[0].cite // "<nichts>"')"
[ "$(echo "$S" | jq -r '.signals[0].type')" = "acquisition" ] && [ "$(echo "$S" | jq -r '.count')" = "1" ] \
  && ok "Known Result Axept: 1 Signal, acquisition, 27.08." \
  || ko "Known Result weicht ab: count=$(echo "$S" | jq -r '.count') type=$(echo "$S" | jq -r '.signals[0].type')"

R=$(ruf "$TOK_TEAM" listLeadSignals '{"lead_id":"00000000-0000-4000-8000-000000000011","lang":"en"}')
E=$(letzte "/functions/v1/n8n-embed")
[ "$(echo "$E" | jq -r '.body.lang')" = "en" ] \
  && ok "lang wird durchgereicht" || ko "lang kommt beim Backend nicht an"
[ "$(echo "$R" | text | jq -r '.signals[0].cite')" = "ad-hoc-news, August 27 2026" ] \
  && ok "GEGENRICHTUNG: mit lang=en kommt die englische Zitatform an" \
  || ko "die Sprachvariante aendert nichts — dann belegt der Fall darueber nichts"

# ⚠️ 404 DURCHREICHEN, NICHT IN 200 VERPACKEN. Derselbe Mechanismus wie beim 409
# in Abschnitt C: der Rumpf allein traegt die Unterscheidung nicht, `isError` schon.
R=$(ruf "$TOK_TEAM" listLeadSignals '{"lead_id":"00000000-0000-4000-8000-000000000000"}')
[ "$(echo "$R" | jq -r '.result.isError')" = "true" ] \
  && ok "Phantasie-UUID: 404 kommt als FEHLER an, nicht als leere Trefferliste" \
  || ko "isError=$(echo "$R" | jq -r '.result.isError') — ein 404 wird als Erfolg gemeldet"
buche "$(echo "$R" | jq -r '.result.isError')"
echo "$R" | text | grep -q "Keine Entitaet mit der UUID" \
  && ok "der Klartext des Backends ueberlebt die Weitergabe" || ko "die 404-Begruendung geht verloren"

# ═════════════════════════════════════════════════════════════════════════════
sec "F · Allowlist gegen inputSchema — fuer ALLE Tools, im Dispatcher"

# ⚠️ DER FALL AUS PR #37. Dort wurde er pro Tool geflickt (action/user_token nach
# dem Spread); hier traegt ihn die Allowlist fuer alle 71 Tools. Deshalb prueft
# dieser Abschnitt NICHT `action` — das faengt beides —, sondern `stage`: ein
# Schluessel, den nur die Allowlist stoppen kann, weil kein Handler ihn kennt.
ruf "$TOK_VIEW" pipelineStatus '{"campaign_id":"38fee505-00db-45ca-8f0a-101dcf5b12ab","action":"run","stage":"reveal","dry_run":false}' >/dev/null
P=$(letzte "/functions/v1/campaign-pipeline")
if [ -z "$P" ]; then
  ko "kein Aufruf protokolliert — der Allowlist-Fall hat nichts gemessen (§18a a)"
else
  [ "$(echo "$P" | jq -r 'has("body") and (.body|has("stage"))')" = "false" ] \
    && ok "geschmuggeltes 'stage' erreicht das Backend NICHT (nicht in pipelineStatus.properties)" \
    || ko "ESKALATION: 'stage' ist durchgekommen — die Allowlist greift nicht"
  [ "$(echo "$P" | jq -r '.body | has("dry_run")')" = "false" ] \
    && ok "geschmuggeltes 'dry_run' erreicht das Backend NICHT" \
    || ko "'dry_run' ist durchgekommen"
  [ "$(echo "$P" | jq -r '.body.action')" = "status" ] \
    && ok "und die action bleibt status (Allowlist UND Payload-Reihenfolge, beide)" \
    || ko "action=$(echo "$P" | jq -r '.body.action')"
fi

# Zweiter Zeuge, ohne Tool-eigene Absicherung: der Enrichment-Dispatch reicht
# `params: { ...args }` unveraendert weiter. Hier ist die Allowlist die EINZIGE
# Instanz zwischen Client und Provider.
ruf "$TOK_TEAM" enrichCompany '{"name":"Axept Business Software","company_name":"alt","x_injected":1}' >/dev/null
X=$(letzte "/functions/v1/n8n-proxy")
if [ -z "$X" ]; then
  ko "n8n-proxy wurde nicht gerufen — der zweite Allowlist-Zeuge misst nichts"
else
  [ "$(echo "$X" | jq -r '.body.params.name')" = "Axept Business Software" ] \
    && ok "enrichCompany schickt 'name' — der Schluessel, den beide Provider lesen" \
    || ko "enrichCompany schickt kein 'name': $(echo "$X" | jq -c '.body.params')"
  [ "$(echo "$X" | jq -r '.body.params | has("company_name")')" = "false" ] \
    && ok "das alte 'company_name' ist weg und wuerde als undeklarierter Key ohnehin verworfen" \
    || ko "'company_name' geht weiter an den Provider, der es nicht liest"
  [ "$(echo "$X" | jq -r '.body.params | has("x_injected")')" = "false" ] \
    && ok "ein frei erfundener Schluessel erreicht n8n-proxy nicht" \
    || ko "ein undeklarierter Schluessel ist bis zum Provider durchgelaufen"
fi

# GEGENPROBE: vollstaendige, korrekte Argumente muessen BYTE-IDENTISCH ankommen.
# Ohne sie waere eine Allowlist, die zu viel wegwirft, in allen Faellen darueber
# gruen — sie prueft ja nur Abwesenheit (§18a d).
VOLL='{"campaign_id":"7ed61251-14c1-4017-976b-dece91f96ea3","stage":"signals","limit":25,"min_score":70,"require_signal":false,"with_phone":true,"dry_run":true,"confirm_credits":0}'
ruf "$TOK_TEAM" pipelineRun "$VOLL" >/dev/null
P=$(letzte "/functions/v1/campaign-pipeline")
ANGEKOMMEN=$(echo "$P" | jq -cS '.body | del(.user_token, .action)')
GESENDET=$(echo "$VOLL" | jq -cS '.')
if [ "$ANGEKOMMEN" = "$GESENDET" ]; then
  ok "acht deklarierte Argumente kommen byte-identisch an (nur user_token/action ergaenzt)"
else
  ko "die Allowlist veraendert korrekte Argumente:"
  printf '        gesendet:   %s\n' "$GESENDET"
  printf '        angekommen: %s\n' "$ANGEKOMMEN"
fi

# ═════════════════════════════════════════════════════════════════════════════
sec "G · Selbstpruefung der Tabelle"

ANZ=$(wc -l < "$LOG" | tr -d ' ')
[ "${ANZ:-0}" -gt 0 ] \
  && ok "der Fake wurde erreicht ($ANZ Anfragen protokolliert)" \
  || ko "keine einzige Anfrage protokolliert — die Nutzlast-Assertions liefen ueber einer leeren Menge (§18a a)"

# Beide Endpunkte muessen vorgekommen sein. Ein Lauf, in dem n8n-embed nie
# gerufen wurde, besteht Abschnitt A trotzdem, wenn dort nur `-z` geprueft wird.
BEIDE=1
grep -q '"pfad":"/functions/v1/campaign-pipeline' "$LOG" || BEIDE=0
grep -q '"pfad":"/functions/v1/n8n-embed'         "$LOG" || BEIDE=0
[ "$BEIDE" = 1 ] \
  && ok "beide Endpunkte der Spec-Tabelle wurden angesprochen (campaign-pipeline UND n8n-embed)" \
  || ko "einer der beiden Endpunkte kam im ganzen Lauf nicht vor"

[ "$N_ERR" -gt 0 ] && [ "$N_OK" -gt 0 ] \
  && ok "beide Ausgaenge kamen vor: $N_ERR isError, $N_OK Erfolg" \
  || ko "nur EIN Ausgang im ganzen Lauf ($N_ERR isError / $N_OK Erfolg) — die Tabelle prueft nur eine Richtung (§18a a/d)"

ende
