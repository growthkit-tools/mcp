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

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# =============================================================================
sec "A · Erreichbarkeit"
# =============================================================================
curl -sf -m 20 "$BASE/.well-known/mcp/server-card.json" -o "$TMP/card.json" \
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

  SRC_VER=$(sed   -n 's/^const SERVER_VERSION *= *"\([^"]*\)".*/\1/p'   "$REPO_ROOT/index.js" | head -1)
  SRC_PROTO=$(sed -n 's/^const PROTOCOL_VERSION *= *"\([^"]*\)".*/\1/p' "$REPO_ROOT/index.js" | head -1)

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
printf '\n\033[1m%s\033[0m\n' "Ergebnis: $PASS grün, $FAIL rot"
[ "$FAIL" -eq 0 ] || exit 1