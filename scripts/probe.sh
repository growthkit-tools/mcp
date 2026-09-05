#!/usr/bin/env bash
# GrowthKit MCP — Probe
#
# Prüft die Invarianten aus AGENTS.md gegen eine laufende Instanz.
# Braucht KEINE Secrets: tools/list ist bewusst offen (Smithery/Glama).
#
#   ./scripts/probe.sh <base-url>
#   ./scripts/probe.sh <base-url> --update-golden
#
# Exit 0 = alle Checks grün. Exit 1 = mindestens einer rot. Exit 2 = Setup-Fehler.
# Kein `set -e`: alle Checks sollen laufen, damit ein Durchlauf das volle Bild zeigt.
#
# Vor jedem Commit:  bash -n scripts/probe.sh
# (bash parst inkrementell — ein Syntaxfehler am Dateiende fällt sonst erst zur
#  Laufzeit auf, nachdem die halbe Datei schon gelaufen ist.)

set -uo pipefail

BASE="${1:-}"
UPDATE_GOLDEN=0
[ "${2:-}" = "--update-golden" ] && UPDATE_GOLDEN=1

if [ -z "$BASE" ]; then
  echo "Usage: $0 <base-url> [--update-golden]" >&2
  exit 2
fi
BASE="${BASE%/}"

command -v jq   >/dev/null || { echo "jq fehlt"   >&2; exit 2; }
command -v curl >/dev/null || { echo "curl fehlt" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN="$REPO_ROOT/tests/golden/tools.json"

# --- Erwartungswerte (Production-kanonisch, NICHT der Request-Host) ------------
# Die server-card meldet auch auf Preview-Versionen die Produktions-URL. Das ist
# korrekt — die Card ist kanonisch. Deshalb feste Erwartung statt $BASE.
EXP_CANONICAL="https://mcp.growthkit.tools"
EXP_SERVER_NAME="tools.growthkit/revenue-intelligence"
EXP_CARD_TOOLS="dynamic"
APP_PRIVATE_TOOLS="place_call save_call_outcome"
MIN_DESC_LEN=20

PASS=0; FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
ko(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq(){ # desc actual expected
  if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 — erwartet '$3', bekommen '$2'"; fi
}
norm(){ printf '%s' "${1%/}"; }   # Trailing Slash weg: Card hat ihn, server.json nicht
sec(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# Liest eine Modul-Level-Konstante aus index.js. EINE Implementierung, zwei
# Aufrufer (Sektion H und I) — sonst stuenden zwei sed-Muster fuer dieselbe
# Quelle da und koennten auseinanderlaufen. Der WERT hat weiterhin genau eine
# Quelle: die Konstante selbst (§7).
src_const(){ sed -n "s/^const $1 *= *\"\\([^\"]*\\)\".*/\\1/p" "$REPO_ROOT/index.js" | head -1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# =============================================================================
sec "A · Erreichbarkeit"
# =============================================================================
# ⚠️ MIT WIEDERHOLUNG, und der Grund steht in einem Lauf: am 05.09.2026 hat
# probe.sh die Card um 07:45:26 geholt (gruen) und auth-paths.sh sie 1,8 s
# spaeter NICHT mehr bekommen — derselbe Commit, dieselbe Preview-URL, Abbruch
# mit exit 2. Eine frisch deployte Preview-Version flackert; ein einziger
# Versuch macht daraus einen roten Lauf, der nichts ueber den Code sagt.
# --retry-all-errors wiederholt auch bei 4xx/5xx, nicht nur bei Netzfehlern.
curl -sf -m 20 --retry 3 --retry-delay 2 --retry-all-errors \
  "$BASE/.well-known/mcp/server-card.json" -o "$TMP/card.json" \
  && ok "server-card.json erreichbar" \
  || { ko "server-card.json NICHT erreichbar — Abbruch"; exit 1; }

jq -e . "$TMP/card.json" >/dev/null 2>&1 \
  && ok "server-card.json ist valides JSON" \
  || { ko "server-card.json ist kein valides JSON — Abbruch"; exit 1; }

curl -sf -m 20 "$BASE/.well-known/oauth-protected-resource"   -o "$TMP/opr.json" \
  && ok "oauth-protected-resource erreichbar" || ko "oauth-protected-resource fehlt"
curl -sf -m 20 "$BASE/.well-known/oauth-authorization-server" -o "$TMP/oas.json" \
  && ok "oauth-authorization-server erreichbar" || ko "oauth-authorization-server fehlt"

# =============================================================================
sec "B · Discovery-Sync (AGENTS.md §7–§9)"
# =============================================================================
CARD_NAME=$(jq  -r '.name'               "$TMP/card.json")
CARD_VER=$(jq   -r '.version'            "$TMP/card.json")
CARD_PROTO=$(jq -r '.protocolVersion'    "$TMP/card.json")
CARD_TOOLS=$(jq -r '.tools'              "$TMP/card.json")
CARD_URL=$(jq   -r '.serverUrl'          "$TMP/card.json")
CARD_EP=$(jq    -r '.transport.endpoint' "$TMP/card.json")

# UNPROVEN[probe-b-card-felder]: noch nie absichtlich rot gefahren (§18b) — name/serverUrl/tools/version der Card; #2 falsifizierte Golden- und Version-Drift, nicht diese.
eq "Card name"          "$CARD_NAME"          "$EXP_SERVER_NAME"
eq "Card serverUrl"     "$(norm "$CARD_URL")" "$EXP_CANONICAL"
eq "Card tools=dynamic" "$CARD_TOOLS"         "$EXP_CARD_TOOLS"

if [ -n "$CARD_VER" ] && [ "$CARD_VER" != "null" ]; then
  ok "Card version gesetzt ($CARD_VER)"
else
  ko "Card version fehlt"
fi

if [ -f "$REPO_ROOT/server.json" ]; then
  SJ_NAME=$(jq -r '.name'           "$REPO_ROOT/server.json")
  SJ_VER=$(jq  -r '.version'        "$REPO_ROOT/server.json")
  SJ_DESC=$(jq -r '.description'    "$REPO_ROOT/server.json")
  SJ_URL=$(jq  -r '.remotes[0].url' "$REPO_ROOT/server.json")
  CARD_DESC=$(jq -r '.description'  "$TMP/card.json")

  # UNPROVEN[probe-b-serverjson-sync]: noch nie absichtlich rot gefahren (§18b) — die vier server.json-gegen-Card-Vergleiche.
  eq "server.json name  == Card"       "$SJ_NAME" "$CARD_NAME"
  eq "server.json version == Card"     "$SJ_VER"  "$CARD_VER"
  eq "server.json description == Card" "$SJ_DESC" "$CARD_DESC"
  eq "server.json remote URL"          "$(norm "$SJ_URL")" "$EXP_CANONICAL"
else
  ko "server.json nicht gefunden (läuft der Probe im Repo-Root?)"
fi

# =============================================================================
sec "C · OAuth-Triplet (AGENTS.md §10)"
# =============================================================================
if [ -f "$TMP/opr.json" ] && [ -f "$TMP/oas.json" ]; then
  OPR_RES=$(jq -r '.resource'                 "$TMP/opr.json")
  OPR_AS=$(jq  -r '.authorization_servers[0]' "$TMP/opr.json")
  OAS_ISS=$(jq -r '.issuer'                   "$TMP/oas.json")
  CARD_RM=$(jq -r '.authentication.resourceMetadata' "$TMP/card.json")

  # UNPROVEN[probe-c-oauth-triplet]: noch nie absichtlich rot gefahren (§18b) — alle vier Triplet-Vergleiche (§10).
  eq "protected-resource.resource"    "$(norm "$OPR_RES")" "$EXP_CANONICAL"
  eq "protected-resource.auth_server" "$(norm "$OPR_AS")"  "$EXP_CANONICAL"
  eq "authorization-server.issuer"    "$(norm "$OAS_ISS")" "$EXP_CANONICAL"
  eq "Card.resourceMetadata zeigt auf OPR" \
     "$(norm "$CARD_RM")" "$EXP_CANONICAL/.well-known/oauth-protected-resource"
fi

# =============================================================================
sec "D · Auth-Grenze"
# =============================================================================
# tools/list MUSS offen bleiben — Smithery/Glama lesen den Katalog unauthentifiziert.
# Ein versehentliches Zumachen senkt die Registry-Scores, ohne dass etwas bricht.
curl -s -m 20 -X POST "$BASE$CARD_EP" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' -o "$TMP/list.json"

if jq -e '.result.tools | type == "array"' "$TMP/list.json" >/dev/null 2>&1; then
  # UNPROVEN[probe-d-toolslist-offen]: noch nie absichtlich rot gefahren (§18b) — Registry-Discovery-Waechter, nie zugemacht gefahren.
  ok "tools/list ohne Auth erreichbar (Registry-Discovery)"
else
  ko "tools/list ohne Auth NICHT erreichbar — Registry-Scores in Gefahr"
fi

CALL_ERR=$(curl -s -m 20 -X POST "$BASE$CARD_EP" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"countMemories","arguments":{}}}' \
  | jq -r '.error.message // "KEIN FEHLER"')

case "$CALL_ERR" in
  *[Aa]uthentication*|*[Uu]nauthorized*) ok "tools/call ohne Auth abgelehnt ($CALL_ERR)" ;;
  *) ko "tools/call ohne Auth NICHT abgelehnt — bekam: $CALL_ERR" ;;
esac

# =============================================================================
sec "E · Compliance-Metadaten (AGENTS.md §12–§13, UWG §7)"
# =============================================================================
for t in $APP_PRIVATE_TOOLS; do
  VIS=$(jq -r --arg n "$t" \
    '[.result.tools[] | select(.name==$n) | ._meta.ui.visibility[]?] | join(",")' "$TMP/list.json")
  PRESENT=$(jq -r --arg n "$t" '[.result.tools[] | select(.name==$n)] | length' "$TMP/list.json")

  if [ "$PRESENT" != "1" ]; then
    ko "$t fehlt in tools/list — weggelassene Tools lehnt der Host als 'unknown' ab (§13)"
  elif [ "$VIS" = "app" ]; then
    # UNPROVEN[probe-e-app-private]: noch nie absichtlich rot gefahren (§18b) — app-private und modell-sichtbar (§12/§13), compliance-tragend und ungeprueft.
    ok "$t ist app-private (_meta.ui.visibility=[app])"
  else
    ko "$t NICHT app-private — visibility='$VIS'. Das Modell könnte es aufrufen (UWG §7)"
  fi
done

# show_callable_leads muss modell-sichtbar BLEIBEN — es rendert die Karte.
SCL_VIS=$(jq -r '[.result.tools[] | select(.name=="show_callable_leads") | ._meta.ui.visibility[]?] | length' "$TMP/list.json")
eq "show_callable_leads bleibt modell-sichtbar" "$SCL_VIS" "0"

SCL_URI=$(jq -r '.result.tools[] | select(.name=="show_callable_leads") | ._meta.ui.resourceUri // "FEHLT"' "$TMP/list.json")
eq "show_callable_leads hat resourceUri" "$SCL_URI" "ui://growthkit/lead-call-card"

# =============================================================================
sec "F · Tool-Katalog"
# =============================================================================
N=$(jq '.result.tools | length' "$TMP/list.json")
if [ "$N" -gt 0 ]; then ok "$N Tools gelistet"; else ko "Keine Tools gelistet"; fi

NOSCHEMA=$(jq -r '[.result.tools[] | select(.inputSchema == null) | .name] | join(", ")' "$TMP/list.json")
if [ -z "$NOSCHEMA" ]; then
  # UNPROVEN[probe-f-tool-katalog]: noch nie absichtlich rot gefahren (§18b) — inputSchema-Vollstaendigkeit und Description-Mindestlaenge.
  ok "Alle Tools haben ein inputSchema"
else
  ko "Tools ohne inputSchema: $NOSCHEMA"
fi

# Descriptions: nur Existenz + Mindestlänge. Bewusst NICHT im Golden — sonst wird
# jede Formulierungsverbesserung ein roter Build.
SHORTDESC=$(jq -r --argjson m "$MIN_DESC_LEN" \
  '[.result.tools[] | select((.description // "" | length) < $m) | .name] | join(", ")' "$TMP/list.json")
if [ -z "$SHORTDESC" ]; then
  ok "Alle Descriptions >= $MIN_DESC_LEN Zeichen"
else
  ko "Description fehlt/zu kurz: $SHORTDESC"
fi

DUPES=$(jq -r '[.result.tools[].name] | group_by(.) | map(select(length>1) | .[0]) | join(", ")' "$TMP/list.json")
if [ -z "$DUPES" ]; then ok "Keine doppelten Tool-Namen"; else ko "Doppelte Tool-Namen: $DUPES"; fi

# =============================================================================
sec "G · Golden Master"
# =============================================================================
# Erfasst die strukturelle Oberfläche, nicht den Prosatext.
jq -S '.result.tools
       | sort_by(.name)
       | map({
           name,
           required: (.inputSchema.required // [] | sort),
           props:    (.inputSchema.properties // {} | keys | sort),
           meta:     (._meta // null)
         })' "$TMP/list.json" > "$TMP/surface.json"

if [ "$UPDATE_GOLDEN" = "1" ]; then
  mkdir -p "$(dirname "$GOLDEN")"
  cp "$TMP/surface.json" "$GOLDEN"
  ok "Golden aktualisiert: $GOLDEN"
  echo
  echo "  ACHTUNG: Golden-Update gehört in DENSELBEN Commit wie die Schema-Änderung."
  echo "  Wenn du nicht genau weißt, WELCHE Änderung du gemacht hast, ist die"
  echo "  Änderung der Bug — nicht das Golden-File. (AGENTS.md §19)"
elif [ ! -f "$GOLDEN" ]; then
  ko "Golden fehlt. Einmalig erzeugen: $0 $BASE --update-golden"
elif diff -q "$GOLDEN" "$TMP/surface.json" >/dev/null; then
  ok "Tool-Oberfläche identisch zum Golden Master"
else
  ko "Tool-Oberfläche weicht vom Golden Master ab:"
  diff -u "$GOLDEN" "$TMP/surface.json" | head -60 | sed 's/^/      /'
fi

# =============================================================================
sec "H · Source-Invarianten (nur lokal/CI, kein HTTP)"
# =============================================================================
# Hier stehen nur noch die GEMISCHTEN Assertions: sie vergleichen den Checkout
# gegen die servierte Fläche und brauchen beide Seiten aus demselben Commit.
# Läuft der Probe gegen eine Fläche, die aus einem anderen Commit stammt, sind sie
# bedeutungslos — nicht bloß ungenau.
if [ -f "$REPO_ROOT/index.js" ]; then

  SRC_VER=$(src_const SERVER_VERSION)
  SRC_PROTO=$(src_const PROTOCOL_VERSION)

  eq "SERVER_VERSION (Source) == Card"   "$SRC_VER"   "$CARD_VER"
  eq "PROTOCOL_VERSION (Source) == Card" "$SRC_PROTO" "$CARD_PROTO"

else
  ko "index.js nicht gefunden — Source-Invarianten nicht prüfbar (läuft der Probe im Repo-Root?)"
fi

# Die QUELLREINEN Assertions (§11) liegen in tests/source-invariants.sh: eine
# Implementierung, zwei Aufrufer. Sie laufen zusätzlich im unit-Job, der nie
# übersprungen wird — hier bleiben sie Teil des Gesamtbilds, damit ein manueller
# Probe-Lauf vor einem PR weiterhin alles zeigt. Sie zählen als EIN Eintrag in der
# Summe unten; ihre Detailzeilen druckt das Skript selbst.
if bash "$REPO_ROOT/tests/source-invariants.sh" --nested; then
  ok "Quell-Invarianten (tests/source-invariants.sh)"
else
  ko "Quell-Invarianten (tests/source-invariants.sh) — Details in den Zeilen darüber"
fi

# =============================================================================
sec "I · Handshake (AGENTS.md §7 · §11)"
# =============================================================================
# WARUM ES DIESE SEKTION GIBT. §7 nennt vier Werte mit EINER Quelle und sagt,
# dass ZWEI Flaechen sie lesen: die server-card UND die initialize-Response.
# Geprueft wurde bis zum 29.08.2026 nur die Card (Sektion B/H). Die
# initialize-Antwort war ungeprueft: tests/auth-paths.sh stellt fest, dass
# protocolVersion vorhanden und nicht null ist, und DRUCKT den Wert — verglichen
# hat ihn nichts. Fuer capabilities, serverInfo und ping gab es in keiner der
# vier Suiten eine Assertion.
#
# WARUM HIER UND NICHT IN auth-paths.sh. Diese Assertions vergleichen den
# CHECKOUT gegen die servierte Flaeche und gelten nur, wenn beide Seiten aus
# demselben Commit stammen — dieselbe Bauart wie B, G und H. auth-paths.sh liest
# den Checkout ueberhaupt nicht: es bekommt nur eine base-url, und sein
# Gegenstand ist die Auth-Grenze (welcher Aufloesungsweg, bleiben die
# oeffentlichen Pfade offen). Der Handshake gehoert nicht dorthin.
# tests/source-invariants.sh scheidet aus dem umgekehrten Grund aus: es macht
# per Konstruktion kein HTTP.
#
# ANGEHAENGT statt eingeschoben: die Sektionsbuchstaben sind an sechs Stellen in
# AGENTS.md und tests/source-invariants.sh in Prosa referenziert, eine davon
# historisch ("standen bis 20.08.26 in Sektion H"). Umnummerieren haette fuenf
# Verweise nachziehen muessen und einen davon mehrdeutig gemacht.

if [ ! -f "$REPO_ROOT/index.js" ]; then
  # §18a (c): fehlende Quelle ist ein FEHLER, kein Grund zum Ueberspringen —
  # sonst laeuft jeder Vergleich unten leer-wahr durch.
  ko "index.js nicht gefunden — Handshake nicht gegen die Konstanten pruefbar"
else
  I_NAME=$(src_const SERVER_NAME)
  I_VER=$(src_const SERVER_VERSION)
  I_PROTO=$(src_const PROTOCOL_VERSION)

  # ⚠️ EXISTENZ JEDER QUELLE EIGENSTAENDIG PRUEFEN (§18a c). Ein umbenanntes
  # `const PROTOCOL_VERSION` liefert "" — und "" gegen "" ist gruen. Genau dieser
  # Fall ist in AGENTS.md als Beleg fuer (c) festgehalten.
  MISSING=""
  [ -n "$I_NAME" ]  || MISSING="$MISSING SERVER_NAME"
  [ -n "$I_VER" ]   || MISSING="$MISSING SERVER_VERSION"
  [ -n "$I_PROTO" ] || MISSING="$MISSING PROTOCOL_VERSION"
  if [ -n "$MISSING" ]; then
    ko "Konstante(n) nicht aus index.js gelesen:$MISSING — Vergleiche waeren leer gegen leer (§18a c)"
  else
    ok "Konstanten aus index.js gelesen (SERVER_NAME, SERVER_VERSION, PROTOCOL_VERSION)"

    # Die Anfrage nennt BEWUSST eine andere protocolVersion als der Server fuehrt.
    # Der Server liest params.protocolVersion heute nirgends und antwortet
    # unbedingt mit seiner eigenen — am 29.08.2026 am Code gemessen (drei
    # Vorkommen von protocolVersion: server-card, initialize, ext-apps-Literal;
    # params.protocolVersion kommt nicht vor).
    #
    # ⚠️ DIESE ASSERTION NAGELT DEN HEUTIGEN VERTRAG FEST, nicht den kuenftigen.
    # Wer Versionsverhandlung einbaut (MCP-Revision 2026-07-28), macht sie ROT —
    # und das ist der Zweck: dieselbe Logik wie beim Golden Master (§19). Rot
    # heisst dann "der Handshake-Vertrag hat sich geaendert, aendere die Assertion
    # ABSICHTLICH mit", nicht "repariere das Skript".
    HS_CODE=$(curl -s -m 20 -o "$TMP/init.json" -w '%{http_code}' \
      -X POST "$BASE$CARD_EP" -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01","clientInfo":{"name":"probe","version":"0"},"capabilities":{}}}')
    eq "initialize: HTTP 200" "$HS_CODE" "200"

    # --- protocolVersion gegen die KONSTANTE, nicht gegen ein Literal ----------
    # Ein Literal hier waere die zweite Stelle fuer dieselbe Groesse (§7) und
    # muesste bei jedem Bump mitgezogen werden.
    eq "initialize protocolVersion == PROTOCOL_VERSION (Source)" \
       "$(jq -r '.result.protocolVersion // ""' "$TMP/init.json")" "$I_PROTO"

    # §11: die zweite 2026er-Version (ext-apps LATEST_PROTOCOL_VERSION) wird hier
    # NICHT noch einmal geprueft. tests/source-invariants.sh haelt fest, dass die
    # Konstante nicht der ext-apps-Wert ist; zusammen mit der Zeile darueber folgt
    # die servierte Seite daraus. Eine dritte Assertion waere dieselbe Aussage an
    # einer dritten Stelle.

    # --- serverInfo ------------------------------------------------------------
    eq "initialize serverInfo.name == SERVER_NAME (Source)" \
       "$(jq -r '.result.serverInfo.name // ""' "$TMP/init.json")" "$I_NAME"
    eq "initialize serverInfo.version == SERVER_VERSION (Source)" \
       "$(jq -r '.result.serverInfo.version // ""' "$TMP/init.json")" "$I_VER"

    # title ist ein Literal in index.js und KEINE Modul-Konstante. Ein
    # Erwartungswert hier waere eine zweite Stelle fuer eine Zeichenkette, die
    # nirgends sonst steht — geprueft wird deshalb nur, DASS er da ist.
    HS_TITLE=$(jq -r '.result.serverInfo.title // ""' "$TMP/init.json")
    if [ -n "$HS_TITLE" ]; then
      ok "initialize serverInfo.title gesetzt ($HS_TITLE)"
    else
      ko "initialize serverInfo.title fehlt oder ist leer"
    fi

    # --- capabilities ----------------------------------------------------------
    # Geprueft wird die STRUKTUR, nicht der Inhalt: welche Faehigkeiten der Server
    # ankuendigt, und dass jede ein boolesches listChanged traegt. Ein Client, der
    # prompts/resources/tools erwartet, bricht still, wenn eines wegfaellt.
    eq "initialize capabilities: Schluessel" \
       "$(jq -r '(.result.capabilities // {}) | keys | join(",")' "$TMP/init.json")" \
       "prompts,resources,tools"
    eq "initialize capabilities: listChanged ueberall boolean" \
       "$(jq -r '[(.result.capabilities // {}) | to_entries[] | select((.value.listChanged|type) == "boolean")] | length' "$TMP/init.json")" \
       "3"

    # --- ping ------------------------------------------------------------------
    # ping ist oeffentlich (PUBLIC_METHODS) und antwortet mit einem leeren
    # result-Objekt. Bisher pruefte das nichts.
    PING_CODE=$(curl -s -m 20 -o "$TMP/ping.json" -w '%{http_code}' \
      -X POST "$BASE$CARD_EP" -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","id":2,"method":"ping"}')
    eq "ping: HTTP 200"            "$PING_CODE" "200"
    eq "ping: leeres result-Objekt" "$(jq -c '.result // "FEHLT"' "$TMP/ping.json")" "{}"
  fi
fi

# =============================================================================
printf '\n\033[1m%s\033[0m\n' "Ergebnis: $PASS grün, $FAIL rot"
[ "$FAIL" -eq 0 ] || exit 1