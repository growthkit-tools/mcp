#!/usr/bin/env bash
# GrowthKit MCP — Auth-Pfade
#
# Prüft die Auth-Grenze gegen eine laufende Instanz: welcher Auflösungsweg für
# einen Bearer betreten wurde und dass die öffentlichen Pfade offen bleiben.
#
#   ./tests/auth-paths.sh <base-url>
#
# Exit 0 = alle Checks grün. Exit 1 = mindestens einer rot. Exit 2 = Setup-Fehler.
# Kein `set -e`: alle Checks sollen laufen, damit ein Durchlauf das volle Bild zeigt.
#
# SECRET-FREI, und zwar nicht nur zufällig: geprüft werden ausschließlich
# Negativfälle und öffentliche Methoden. Der Positivfall braucht ein echtes
# gk_-Token und bleibt ein manueller Schritt (§6 der lokalen, bewusst nicht
# getrackten Spec mcp-gk-bearer-auth.md), bis es einen dedizierten
# Test-Workspace gibt.
#
# WARUM data.path. Beide Ablehnungspfade — OAuth und gk_ — antworten mit derselben
# Meldung "Invalid or expired token". Das ist Absicht: die Meldung darf nicht
# verraten, ob ein Token unbekannt oder deaktiviert ist. Damit ist die Meldung
# allein aber kein Beleg dafür, WELCHER Zweig lief; die Assertion "nicht
# Authentication required" war schon vor Einführung des gk_-Pfads grün. Deshalb
# trägt jede Ablehnung ein maschinenlesbares error.data.path — "none" | "oauth" |
# "api_token". Jeder Fall unten vergleicht diesen Wert, statt ein Feld auf
# Abwesenheit zu prüfen (AGENTS.md §18a Fall c).
#
# Die Fälle brauchen KEINE erreichbare Supabase: der Zweig wird am Token-Präfix
# gewählt, bevor irgendein Backend-Aufruf passiert. Gegen `npm run dev` ohne
# .dev.vars ist das Ergebnis dasselbe wie gegen eine Preview.
#
# Vor jedem Commit:  bash -n tests/auth-paths.sh

set -uo pipefail

BASE="${1:-}"
if [ -z "$BASE" ]; then
  echo "Usage: $0 <base-url>" >&2
  exit 2
fi
BASE="${BASE%/}"

command -v jq   >/dev/null || { echo "jq fehlt"   >&2; exit 2; }
command -v curl >/dev/null || { echo "curl fehlt" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
ko(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
eq(){ # desc actual expected
  if [ "$2" = "$3" ]; then ok "$1"; else ko "$1 — erwartet '$3', bekommen '$2'"; fi
}
sec(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Endpoint aus der server-card lesen statt hier zu hardcoden: MCP_ENDPOINT ist
# laut AGENTS.md §7 Single Source of Truth in index.js und fällt in die Card.
curl -sf -m 20 "$BASE/.well-known/mcp/server-card.json" -o "$TMP/card.json" \
  || { echo "server-card.json nicht erreichbar unter $BASE — Abbruch" >&2; exit 2; }
EP=$(jq -r '.transport.endpoint' "$TMP/card.json")
[ -n "$EP" ] && [ "$EP" != "null" ] \
  || { echo "transport.endpoint fehlt in der server-card — Abbruch" >&2; exit 2; }

# $1 = JSON-Body, $2 = Wert des authorization-Headers ("" = Header weglassen).
# Schreibt die Antwort nach $TMP/resp.json und gibt den HTTP-Code aus.
post(){
  if [ -z "${2:-}" ]; then
    curl -s -m 20 -X POST "$BASE$EP" \
      -H 'content-type: application/json' \
      -d "$1" -o "$TMP/resp.json" -w '%{http_code}'
  else
    curl -s -m 20 -X POST "$BASE$EP" \
      -H 'content-type: application/json' \
      -H "authorization: $2" \
      -d "$1" -o "$TMP/resp.json" -w '%{http_code}'
  fi
}
jqr(){ jq -r "$1" "$TMP/resp.json" 2>/dev/null; }

# countMemories ist ein gated Tool (nicht in PUBLIC_METHODS) und read-only —
# es wird hier nie erreicht, weil jeder Aufruf vorher an der Auth scheitert.
CALL='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"countMemories","arguments":{}}}'
LIST='{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'

# =============================================================================
sec "A · Ablehnung mit Pfad-Diskriminator"
# =============================================================================

CODE=$(post "$CALL" "")
eq "ohne Bearer: 401"                 "$CODE"                   "401"
eq "ohne Bearer: Meldung"             "$(jqr '.error.message')" "Authentication required"
eq "ohne Bearer: path"                "$(jqr '.error.data.path')" "none"

CODE=$(post "$CALL" "Bearer gk_offensichtlich_ungueltig_kein_echtes_token")
eq "gk_-Bearer ungültig: 401"         "$CODE"                   "401"
eq "gk_-Bearer ungültig: Meldung"     "$(jqr '.error.message')" "Invalid or expired token"
# Der eigentliche Nachweis dieser Änderung: der gk_-Zweig wurde betreten und hat
# abgelehnt. Vor Einführung des Pfads fehlt das Feld, dieser Check ist dann rot.
eq "gk_-Bearer ungültig: path"        "$(jqr '.error.data.path')" "api_token"

CODE=$(post "$CALL" "Bearer nicht_gk_offensichtlich_ungueltig")
eq "Nicht-gk_-Bearer: 401"            "$CODE"                   "401"
eq "Nicht-gk_-Bearer: Meldung"        "$(jqr '.error.message')" "Invalid or expired token"
eq "Nicht-gk_-Bearer: path"           "$(jqr '.error.data.path')" "oauth"

# Grenzfall: ein authorization-Header ohne verwertbaren Wert ist KEIN Token.
# Er muss wie "gar kein Bearer" behandelt werden, nicht wie ein abgelehntes
# Token — sonst wäre Fall 1 nicht von 2 und 3 unterscheidbar.
CODE=$(post "$CALL" "Bearer")
eq "Bearer ohne Wert: 401"            "$CODE"                   "401"
eq "Bearer ohne Wert: Meldung"        "$(jqr '.error.message')" "Authentication required"
eq "Bearer ohne Wert: path"           "$(jqr '.error.data.path')" "none"

# =============================================================================
sec "B · Öffentliche Pfade bleiben offen"
# =============================================================================
# Der häufigste Kollateralschaden einer Auth-Änderung: Registry-Discovery
# (Smithery, Glama, mcp.so) ruft tools/list ohne Token. Das MUSS 200 bleiben.

CODE=$(post "$LIST" "")
eq "tools/list ohne Bearer: 200"      "$CODE" "200"
N=$(jqr '.result.tools | length')
eq "tools/list ohne Bearer: Array-Typ" "$(jqr '.result.tools | type')" "array"
# Nicht nur "ist ein Array": ein leeres Array wäre genau die stille Regression,
# die eine Zählung ohne Untergrenze durchwinkt (AGENTS.md §18a Fall a).
if [ -n "$N" ] && [ "$N" != "null" ] && [ "$N" -gt 0 ] 2>/dev/null; then
  ok "tools/list ohne Bearer: $N Tools (nicht leer)"
else
  ko "tools/list ohne Bearer: Tool-Array ist leer oder fehlt (bekommen '$N')"
fi

CODE=$(post "$INIT" "")
eq "initialize ohne Bearer: 200"      "$CODE" "200"
PV=$(jqr '.result.protocolVersion')
if [ -n "$PV" ] && [ "$PV" != "null" ]; then
  ok "initialize ohne Bearer: protocolVersion $PV"
else
  ko "initialize ohne Bearer: protocolVersion fehlt"
fi

# Ein ungültiges Token auf einer öffentlichen Methode muss unauthentifiziert
# durchfallen, nicht 401 werfen. Der gk_-Zweig läuft hier, findet nichts und
# darf trotzdem nicht blockieren — requiresAuth ist für tools/list false.
CODE=$(post "$LIST" "Bearer gk_offensichtlich_ungueltig_kein_echtes_token")
eq "tools/list mit ungültigem gk_: 200" "$CODE" "200"
N=$(jqr '.result.tools | length')
if [ -n "$N" ] && [ "$N" != "null" ] && [ "$N" -gt 0 ] 2>/dev/null; then
  ok "tools/list mit ungültigem gk_: $N Tools (nicht leer)"
else
  ko "tools/list mit ungültigem gk_: Tool-Array ist leer oder fehlt (bekommen '$N')"
fi

# =============================================================================
printf '\n\033[1m%s\033[0m\n' "Ergebnis: $PASS grün, $FAIL rot"
[ "$FAIL" -eq 0 ] || exit 1
