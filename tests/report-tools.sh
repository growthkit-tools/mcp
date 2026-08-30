#!/usr/bin/env bash
# GrowthKit MCP — Report-Tools-Test
#
# Prüft getSeoReport / getAeoReport gegen eine laufende Instanz.
# Deckt A5 aus der lokalen, bewusst nicht getrackten Spec mcp-report-tools.md ab.
#
#   ./tests/report-tools.sh <base-url>
#
# Braucht KEINE Secrets. Das ist Absicht: ein CI-Secret mit Zugriff auf echte
# Workspace-Daten wäre genau die Abkürzung, die man später bereut. Geprüft wird
# deshalb nur die Tool-OBERFLÄCHE (tools/list) und die Auth-Grenze — der
# authentifizierte Happy-Path bleibt ein manueller Schritt, bis es einen
# dedizierten Test-Workspace gibt.
#
# Exit 0 = alle Checks grün. Exit 1 = mindestens einer rot. Exit 2 = Setup-Fehler.
# Kein `set -e`: alle Checks sollen laufen, damit ein Durchlauf das volle Bild
# zeigt — dasselbe Prinzip wie in scripts/probe.sh.
#
# Vor jedem Commit:  bash -n tests/report-tools.sh

set -uo pipefail

BASE="${1:-}"
if [ -z "$BASE" ]; then
  echo "Usage: $0 <base-url>" >&2
  exit 2
fi
BASE="${BASE%/}"

command -v jq   >/dev/null || { echo "jq fehlt"   >&2; exit 2; }
command -v curl >/dev/null || { echo "curl fehlt" >&2; exit 2; }

REPORT_TOOLS="getSeoReport getAeoReport"
MIN_DESC_LEN=20

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

curl -s -m 20 -X POST "$BASE$EP" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' -o "$TMP/list.json"
jq -e '.result.tools | type == "array"' "$TMP/list.json" >/dev/null 2>&1 \
  || { echo "tools/list lieferte kein Tool-Array — Abbruch" >&2; exit 2; }

# =============================================================================
sec "A · Präsenz im Katalog"
# =============================================================================
for t in $REPORT_TOOLS; do
  N=$(jq -r --arg n "$t" '[.result.tools[] | select(.name==$n)] | length' "$TMP/list.json")
  # UNPROVEN[report-tools-katalog-praesenz]: noch nie absichtlich rot gefahren (§18b) — nicht unter den fuenf Injektionen aus #3.
  eq "$t ist in tools/list" "$N" "1"
done

# =============================================================================
sec "B · inputSchema"
# =============================================================================
for t in $REPORT_TOOLS; do
  PROPS=$(jq -r --arg n "$t" \
    '[.result.tools[] | select(.name==$n) | .inputSchema.properties // {} | keys[]] | sort | join(",")' \
    "$TMP/list.json")
  # UNPROVEN[report-tools-schema-form]: noch nie absichtlich rot gefahren (§18b) — deckt Properties/integer/minimum/string ab; #3 injizierte nur maximum, required, user_token, _meta.
  eq "$t: Properties sind genau domain,weeks" "$PROPS" "domain,weeks"

  # required MUSS als leeres Array dastehen — beide Argumente sind optional.
  HAS_REQ=$(jq -r --arg n "$t" \
    '[.result.tools[] | select(.name==$n) | .inputSchema | select(has("required"))] | length' "$TMP/list.json")
  eq "$t: required-Feld vorhanden" "$HAS_REQ" "1"

  REQ_LEN=$(jq -r --arg n "$t" \
    '[.result.tools[] | select(.name==$n) | .inputSchema.required[]?] | length' "$TMP/list.json")
  eq "$t: required ist leer" "$REQ_LEN" "0"

  WTYPE=$(jq -r --arg n "$t" \
    '.result.tools[] | select(.name==$n) | .inputSchema.properties.weeks.type // "FEHLT"' "$TMP/list.json")
  eq "$t: weeks ist integer" "$WTYPE" "integer"

  WMIN=$(jq -r --arg n "$t" \
    '.result.tools[] | select(.name==$n) | .inputSchema.properties.weeks.minimum // "FEHLT"' "$TMP/list.json")
  eq "$t: weeks minimum=1" "$WMIN" "1"

  WMAX=$(jq -r --arg n "$t" \
    '.result.tools[] | select(.name==$n) | .inputSchema.properties.weeks.maximum // "FEHLT"' "$TMP/list.json")
  eq "$t: weeks maximum=52" "$WMAX" "52"

  DTYPE=$(jq -r --arg n "$t" \
    '.result.tools[] | select(.name==$n) | .inputSchema.properties.domain.type // "FEHLT"' "$TMP/list.json")
  eq "$t: domain ist string" "$DTYPE" "string"

  # Regression auf den Slug-Bug: die Description nannte 'growthkit.tools' (mit
  # Punkt) als Beispiel. domainSlug() im weekly-seo-report ersetzt [^a-z0-9]+
  # durch '-', der echte Wert ist 'growthkit-tools'. Ein Aufruf mit dem
  # dokumentierten Wert liefert {} — still, ohne Fehler, und nicht vom Fall
  # "Workspace hat noch keine Reports" unterscheidbar.
  #
  # Geprueft wird das maschinenlesbare `examples`, NICHT der Fliesstext: eine
  # Regex ueber die Prosa wuerde an Gegenbeispielen ("… not 'x.y'") scheitern und
  # bei jeder Umformulierung brechen. Die Description faellt im Worker aus
  # derselben Liste wie `examples`, deshalb genuegt das strukturierte Feld.
  N_EX=$(jq -r --arg n "$t" \
    '[.result.tools[] | select(.name==$n) | .inputSchema.properties.domain.examples[]?] | length' "$TMP/list.json")
  if [ "$N_EX" -ge 1 ]; then
    # UNPROVEN[report-tools-domain-beispiele]: noch nie absichtlich rot gefahren (§18b) — Anzahl, Slug-Form und Nennung in der Description.
    ok "$t: domain hat $N_EX Beispiel(e)"
  else
    ko "$t: domain hat kein examples — Regression auf den Slug-Bug nicht pruefbar"
  fi

  BAD=$(jq -r --arg n "$t" \
    '[.result.tools[] | select(.name==$n) | .inputSchema.properties.domain.examples[]?
      | select(test("^[a-z0-9]+(-[a-z0-9]+)*$") | not)] | join(", ")' "$TMP/list.json")
  if [ -z "$BAD" ]; then
    ok "$t: alle domain-Beispiele sind Slugs"
  else
    ko "$t: domain-Beispiel ist kein Slug: $BAD — liefert {} ohne Fehler"
  fi

  # Und die Prosa muss die strukturierten Werte auch nennen, sonst liest ein
  # Mensch weiter den falschen Wert, waehrend `examples` still korrekt ist.
  # `. as $e` ist hier tragend: in `$d | contains(.)` wuerde die Pipe das `.` auf
  # $d rebinden — die Pruefung waere `$d contains $d`, also immer wahr, und die
  # Assertion still leer-wahr. (Genau so gebaut, beim Falsifizieren aufgefallen.)
  MISSING=$(jq -r --arg n "$t" \
    '.result.tools[] | select(.name==$n) | .inputSchema.properties.domain
     | .description as $d | [.examples[]? | . as $e | select($d | contains($e) | not)] | join(", ")' "$TMP/list.json")
  if [ -z "$MISSING" ]; then
    ok "$t: Description nennt alle domain-Beispiele"
  else
    ko "$t: Description nennt diese Beispiele nicht: $MISSING"
  fi

  # user_token kommt aus dem MCP-Bearer und wird serverseitig in den Body gesetzt.
  # Er darf im Schema nirgends auftauchen — auch nicht verschachtelt, daher
  # tostring über das ganze Schema statt nur ein keys-Vergleich.
  UT=$(jq -r --arg n "$t" \
    '[.result.tools[] | select(.name==$n) | .inputSchema | tostring | test("user_token")] | any' "$TMP/list.json")
  eq "$t: kein user_token im Schema" "$UT" "false"
done

# =============================================================================
sec "C · Kein _meta (die beiden sind NICHT app-privat)"
# =============================================================================
# Gegenprobe zu AGENTS.md §12: place_call/save_call_outcome tragen
# _meta.ui.visibility=[app] und werden vom Host vor dem Modell verborgen. Die
# Report-Tools sind normale modell-sichtbare Reads — ein versehentliches _meta
# würde sie unsichtbar machen, ohne dass irgendetwas bricht.
for t in $REPORT_TOOLS; do
  HAS_META=$(jq -r --arg n "$t" \
    '[.result.tools[] | select(.name==$n) | select(has("_meta"))] | length' "$TMP/list.json")
  eq "$t hat kein _meta" "$HAS_META" "0"
done

# =============================================================================
sec "D · Description"
# =============================================================================
for t in $REPORT_TOOLS; do
  DLEN=$(jq -r --arg n "$t" \
    '.result.tools[] | select(.name==$n) | .description // "" | length' "$TMP/list.json")
  if [ "$DLEN" -ge "$MIN_DESC_LEN" ]; then
    # UNPROVEN[report-tools-description-laenge]: noch nie absichtlich rot gefahren (§18b) — Laengenschwelle nie unterschritten gefahren.
    ok "$t: Description >= $MIN_DESC_LEN Zeichen ($DLEN)"
  else
    ko "$t: Description zu kurz ($DLEN < $MIN_DESC_LEN) — Platzhalter?"
  fi
done

# =============================================================================
sec "E · Auth-Grenze"
# =============================================================================
# tools/call ist gated (PUBLIC_METHODS in index.js). Ein unauthentifizierter
# Aufruf muss einen Fehler liefern — NICHT 200 mit Daten.
for t in $REPORT_TOOLS; do
  RESP=$(curl -s -m 20 -X POST "$BASE$EP" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$t\",\"arguments\":{}}}")
  ERR=$(printf '%s' "$RESP" | jq -r '.error.message // "KEIN FEHLER"')
  LEAK=$(printf '%s' "$RESP" | jq -r 'tostring | test("domains")')

  case "$ERR" in
    *[Aa]uthentication*|*[Uu]nauthorized*)
      if [ "$LEAK" = "true" ]; then
        ko "$t: abgelehnt, liefert aber trotzdem domains-Daten aus"
      else
        # UNPROVEN[report-tools-auth-grenze]: noch nie absichtlich rot gefahren (§18b) — Ablehnung nie gegen einen offenen Pfad gefahren.
        ok "$t ohne Auth abgelehnt ($ERR)"
      fi
      ;;
    *) ko "$t ohne Auth NICHT abgelehnt — bekam: $ERR" ;;
  esac
done

printf '\n\033[1mErgebnis: %d grün, %d rot\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
