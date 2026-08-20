#!/usr/bin/env bash
# GrowthKit MCP — Quell-Invarianten
#
# Prüft die Invarianten, die AUSSCHLIESSLICH aus index.js folgen — ohne HTTP,
# ohne laufende Instanz, ohne Workers Build.
#
#   ./tests/source-invariants.sh            # eigenständig (unit-Job, lokal)
#   ./tests/source-invariants.sh --nested   # aus probe.sh heraus, ohne Summenzeile
#
# Exit 0 = alle Checks grün. Exit 1 = mindestens einer rot.
# Kein `set -e`: alle Checks sollen laufen, damit ein Durchlauf das volle Bild zeigt.
#
# WARUM EIGENE DATEI. Diese Assertions standen bis 20.08.26 in Sektion H von
# scripts/probe.sh und hingen damit am probe-Job. Der wird übersprungen, wenn für
# einen Commit kein Workers Build entsteht — seit die Build-Watch-Excludes gesetzt
# sind, gilt das für JEDEN Commit, der nur *.md, tests/**, scripts/**, .github/**,
# .claude/** oder specs/** anfasst. Eine kaputte quellreine Assertion wäre dort grün
# geblieben und erst beim nächsten index.js-Commit aufgefallen. Sie brauchen aber
# gar keine Fläche: sie sind reine Funktionen des Checkouts. Hier laufen sie im
# unit-Job, der nie übersprungen wird.
#
# ABGRENZUNG. Assertions, die Disk GEGEN eine servierte Fläche vergleichen
# (SERVER_VERSION == Card, server.json == Card, Golden Master), gehören NICHT
# hierher: sie brauchen beide Seiten aus demselben Commit und bleiben in probe.sh.
#
# EINE Implementierung, zwei Aufrufer — der unit-Job ruft diese Datei direkt auf,
# probe.sh delegiert in Sektion H hierher. Keine zweite Kopie der Assertions und
# keine zweite Kopie von EXP_UI_PROTOCOL.
#
# Vor jedem Commit:  bash -n tests/source-invariants.sh

set -uo pipefail

NESTED=0
[ "${1:-}" = "--nested" ] && NESTED=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/index.js"

# ext-apps LATEST_PROTOCOL_VERSION — bewusst NICHT PROTOCOL_VERSION (AGENTS.md §11).
# Einzige Kopie im Repo. probe.sh hatte sie bis 20.08.26 ebenfalls; sie ist dort
# entfernt, weil zwei Kopien einer Protokoll-Version genau die Drift erzeugen,
# gegen die §11 überhaupt geschrieben wurde.
EXP_UI_PROTOCOL="2026-01-26"

PASS=0; FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
ko(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

[ "$NESTED" -eq 1 ] || printf '\n\033[1m%s\033[0m\n' "Quell-Invarianten (AGENTS.md §11)"

# Fehlendes index.js ist hier ein Fehler, kein Grund zum Überspringen. Die frühere
# Fassung in probe.sh gab nur eine Notiz aus und blieb grün — eine Prüfung, die
# verschwindet, sobald ihr Eingang verschwindet, ist keine Prüfung.
if [ ! -f "$SRC" ]; then
  ko "index.js nicht gefunden ($SRC) — Quell-Invarianten nicht prüfbar"
  [ "$NESTED" -eq 1 ] || printf '\n\033[1m%s\033[0m\n' "Ergebnis: $PASS grün, $FAIL rot"
  exit 1
fi

# --- §11 · PROTOCOL_VERSION ist nicht der ext-apps-Wert -----------------------
SRC_PROTO=$(sed -n 's/^const PROTOCOL_VERSION *= *"\([^"]*\)".*/\1/p' "$SRC" | head -1)

# Leerer Treffer heißt NICHT "in Ordnung": ein umbenanntes oder verschobenes Const
# liefert "" und wäre gegen jeden Vergleich mit dem ext-apps-Wert grün. Der Fall
# braucht einen eigenen roten Ausgang.
if [ -z "$SRC_PROTO" ]; then
  ko "PROTOCOL_VERSION in index.js nicht gefunden — umbenannt oder kein Module-Level-Const? (§7)"
elif [ "$SRC_PROTO" = "$EXP_UI_PROTOCOL" ]; then
  ko "PROTOCOL_VERSION wurde auf den ext-apps-Wert angeglichen — genau der Fehler aus §11"
else
  ok "PROTOCOL_VERSION trägt nicht den ext-apps-Wert"
fi

# --- §11 · ui/initialize trägt den ext-apps-Literal ---------------------------
# Nur den ui/initialize-Aufrufblock betrachten. PROTOCOL_VERSION wird anderswo
# (initialize-Response, server-card) völlig korrekt referenziert — ein dateiweiter
# Grep erzeugt dort False Positives.
UI_BLOCK=$(awk 'index($0,"sendRequest(\"ui/initialize\"")>0{f=1} f{print; n++} n>8{exit}' "$SRC")

if [ -z "$UI_BLOCK" ]; then
  ko "ui/initialize-Aufruf in index.js nicht gefunden — verschoben oder umbenannt?"
else
  case "$UI_BLOCK" in
    *"protocolVersion: \"$EXP_UI_PROTOCOL\""*)
      ok "ui/initialize protocolVersion = $EXP_UI_PROTOCOL als Literal (§11)" ;;
    *protocolVersion*PROTOCOL_VERSION*)
      ko "ui/initialize referenziert PROTOCOL_VERSION statt des ext-apps-Literals (§11)" ;;
    *)
      ko "ui/initialize protocolVersion fehlt oder != $EXP_UI_PROTOCOL — MCP Apps failen STILL" ;;
  esac
fi

[ "$NESTED" -eq 1 ] || printf '\n\033[1m%s\033[0m\n' "Ergebnis: $PASS grün, $FAIL rot"
[ "$FAIL" -eq 0 ] || exit 1
