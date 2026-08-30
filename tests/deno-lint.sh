#!/usr/bin/env bash
# GrowthKit MCP — deno lint als Gate, mit Schuldschein
#
#   ./tests/deno-lint.sh
#
# Exit 0 = Ist-Zustand deckt sich mit dem Schuldschein. Exit 1 = mindestens eine
# Abweichung. Exit 2 = Setup-Fehler (deno fehlt, git fehlt).
# Kein `set -e`: alle Pruefungen sollen laufen, damit ein Durchlauf das volle Bild zeigt.
#
# Vor jedem Commit:  bash -n tests/deno-lint.sh
#
# ─────────────────────────────────────────────────────────────────────────────
# WARUM deno lint IN EINEM REPO, DAS KEIN DENO-REPO IST.
#
# Die Werkzeugkette hier ist Node + wrangler; AGENTS.md fuehrte Deno bis zum
# 30.08.2026 als "nicht in diesem Repo genutzt". deno lint ist trotzdem die
# guenstigste Wahl: es braucht KEINE Dependency im package.json, parst .js und
# .ts gleichermassen, und die Alternative (eslint) zoege einen Baum npm-Pakete
# in ein Repo, das bewusst drei devDependencies hat.
#
# Der Anlass ist ein Befund aus growthkit-website vom 30.08.2026: dort war
# eslint konfiguriert und wurde NIRGENDS aufgerufen — 29 Meldungen, seit jeher
# unsichtbar. Ein Linter, den niemand faehrt, ist keine Pruefung.
#
# ─────────────────────────────────────────────────────────────────────────────
# WARUM EIN EIGENER SCHULDSCHEIN UND KEIN EINGEBAUTER MECHANISMUS.
#
# Nachgesehen am 30.08.2026 in `deno lint --help` (Deno 2.8.0). deno lint kennt:
#
#   // deno-lint-ignore <regel>     eine Stelle, dauerhaft
#   // deno-lint-ignore-file        eine Datei, dauerhaft
#   deno.json  lint.rules.exclude   eine Regel, repo-weit, dauerhaft
#   --rules-exclude                 dasselbe als Flag
#
# Was es NICHT kennt, ist ein Massen-Suppressions-Mechanismus wie eslint 9.32:
# eine Baseline-Datei, die bestehende Verstoesse einmalig aufnimmt und beim
# Beheben schrumpft. Alle vier Bordmittel sagen "das ist fuer immer in Ordnung".
# Genau das ist hier falsch: die elf Verstoesse im Shim sind SCHULD, keine
# Ausnahme. Deshalb die Liste unten — Muster aus growthkit-website: LISTE STATT
# ZAHL, und sie darf nur schrumpfen.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || { echo "Repo-Root nicht erreichbar" >&2; exit 2; }

command -v deno >/dev/null || { echo "deno fehlt — Version steht in AGENTS.md (Werkzeuge)" >&2; exit 2; }
command -v git  >/dev/null || { echo "git fehlt" >&2; exit 2; }
command -v jq   >/dev/null || { echo "jq fehlt" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
ko(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

printf '\n\033[1m%s\033[0m\n' "deno lint (Schuldschein)"

# ─────────────────────────────────────────────────────────────────────────────
# SCHULDSCHEIN. Verstoesse, die am 30.08.2026 bestanden und noch nicht behoben
# sind. Format:  <pfad>|<regel>|<anzahl>
#
# ⚠️ DAS IST EINE SCHULD, KEIN KONFIGURATIONSPUNKT: sie soll SCHRUMPFEN und darf
# NIE WACHSEN. Wer einen Verstoss behebt, zieht die Zahl hier nach oder streicht
# die Zeile — der Waechter unten erzwingt das, er wird auch beim VERSCHWINDEN rot.
#
# Der Ausgangsstand, weil er die Regel traegt: 18 Meldungen ueber 6 Dateien.
# SIEBEN davon lagen in index.js (sechs `catch (e)` ohne Nutzung von `e`, einer
# davon zugleich ein leerer Block) und sind im selben Vorgang BEHOBEN worden —
# verhaltensneutral, `catch (e)` -> `catch`, der leere Block hat einen Kommentar
# bekommen, der die Absicht benennt. Was hier steht, ist der Rest.
#
# Warum der Rest NICHT mitbehoben wurde: `no-explicit-any` im Shim sauber
# aufzuloesen heisst, die Typen des proxied MCP-Protokolls zu modellieren, und
# `require-await` haengt an den Handler-Signaturen des MCP-SDK. Beides ist eine
# eigene Aenderung an einem eigenen Deployable (AGENTS.md: der Shim ist das
# Deployable von growthkit-mcp-demo, nicht index.js) — und keine, die nebenbei
# in einem Lint-Commit passiert.
#
# ⚠️ WAS DIESE LISTE NICHT SIEHT: einen ZWEITEN Verstoss derselben Regel in einer
# schon gelisteten Datei faengt sie nur ueber die ANZAHL. Deshalb steht sie dabei.
# Eine Liste ohne Zahl waere gegen Wachstum innerhalb eines Eintrags blind
# (§18a k — zu kleine Grundmenge in anderer Gestalt).
# ─────────────────────────────────────────────────────────────────────────────
LINT_DEBT="
mcp-directory-shim/src/core.ts|no-explicit-any|4
mcp-directory-shim/src/http.ts|no-explicit-any|1
mcp-directory-shim/src/proxy.ts|require-await|2
mcp-directory-shim/src/upstream.ts|no-explicit-any|2
mcp-directory-shim/src/worker.ts|no-explicit-any|2
"

# --- Ist-Zustand -------------------------------------------------------------
# Gegenstand sind die GETRACKTEN JS/TS-Dateien, aus git abgeleitet. Damit wandert
# eine neue Datei automatisch in den Scan; eine gepflegte Dateiliste waere eine
# zweite Stelle, die veraltet. node_modules ist per Konstruktion draussen, weil
# es nicht getrackt ist — und diese Datei selbst auch, sie ist .sh und faellt
# nicht unter das Muster. Ein Selbsttreffer wie bei einer repo-weiten Suche ist
# hier also ausgeschlossen.
FILES=$(git ls-files | grep -E '\.(js|ts|mjs|cjs|jsx|tsx)$' || true)
FILE_N=$(printf '%s\n' "$FILES" | grep -c . || true)

# Nicht-Leer-Guard (§18a a): ohne Dateien liefe deno lint ueber nichts und
# meldete null Verstoesse — die Pruefung waere trivial gruen.
if [ "${FILE_N:-0}" -eq 0 ]; then
  ko "Keine getrackte JS/TS-Datei gefunden — deno lint liefe ueber nichts (§18a a)"
  printf '\n\033[1m%s\033[0m\n' "Ergebnis: $PASS grün, $FAIL rot"
  exit 1
fi

RAW=$(printf '%s\n' "$FILES" | xargs deno lint --json 2>/dev/null)

# §18a (c): kaputte oder leere Ausgabe ist ein FEHLER, kein Grund zum
# Weiterlaufen. Ohne diesen Zweig laeuft der Vergleich unten gegen eine leere
# Ist-Menge und meldet jeden Schuldschein-Eintrag als "behoben" — ein falsches
# Erfolgserlebnis, das die Liste leerraeumt.
if ! printf '%s' "$RAW" | jq -e '.diagnostics | type == "array"' >/dev/null 2>&1; then
  ko "deno lint lieferte kein verwertbares JSON — Ausgabeformat geaendert? Ohne Ist-Menge waere jeder Eintrag scheinbar behoben (§18a c)"
  printf '\n\033[1m%s\033[0m\n' "Ergebnis: $PASS grün, $FAIL rot"
  exit 1
fi

ERR_N=$(printf '%s' "$RAW" | jq '.errors | length')
if [ "${ERR_N:-0}" -gt 0 ]; then
  ko "deno lint meldet $ERR_N Datei(en), die es nicht parsen konnte — sie sind ungeprueft"
else
  ok "Alle $FILE_N getrackten JS/TS-Dateien geparst"
fi

# Ist-Menge als "pfad|regel|anzahl", pfadrelativ zum Repo-Root.
IST=$(printf '%s' "$RAW" | jq -r --arg root "$REPO_ROOT/" \
  '.diagnostics[] | ((.filename | sub("^file://";"") | sub("^"+$root;"")) + "|" + .code)' \
  | sort | uniq -c | awk '{print $2 "|" $1}' | sort)

SOLL=$(printf '%s\n' "$LINT_DEBT" | grep '|' | sort)
IST_N=$(printf '%s\n' "$IST"  | grep -c . || true)
SOLL_N=$(printf '%s\n' "$SOLL" | grep -c . || true)

# --- Der Schuldschein muss schrumpfen ---------------------------------------
if [ "${SOLL_N:-0}" -eq 0 ] && [ "${IST_N:-0}" -eq 0 ]; then
  # Zielzustand. Ausdruecklich benannt, damit der Zweig nicht unbemerkt tot ist.
  ok "Schuldschein getilgt: deno lint meldet nichts — dieser Abschnitt darf entfallen"
elif [ "${SOLL_N:-0}" -eq 0 ]; then
  ko "Schuldschein ist leer, deno lint meldet aber $IST_N Eintrag/Eintraege — die Liste darf NICHT wachsen"
else
  NUR_IST=$(comm -23 <(printf '%s\n' "$IST" | cut -d'|' -f1,2 | sort) \
                     <(printf '%s\n' "$SOLL" | cut -d'|' -f1,2 | sort) | tr '\n' ' ')
  NUR_SOLL=$(comm -13 <(printf '%s\n' "$IST" | cut -d'|' -f1,2 | sort) \
                      <(printf '%s\n' "$SOLL" | cut -d'|' -f1,2 | sort) | tr '\n' ' ')

  # Richtung 1: ein Verstoss, den niemand eingetragen hat. Neue Schuld.
  if [ -z "$NUR_IST" ]; then
    ok "Kein Verstoss ausserhalb des Schuldscheins ($IST_N Eintrag/Eintraege)"
  else
    ko "Verstoss ohne Eintrag in LINT_DEBT:$NUR_IST — beheben, oder mit Begruendung eintragen. Die Liste darf NICHT wachsen."
  fi

  # Richtung 2: ein Eintrag, dessen Verstoss weg ist. Der GUTE Fall — jemand hat
  # behoben. Er muss trotzdem rot sein, sonst verrottet die Liste still.
  if [ -z "$NUR_SOLL" ]; then
    ok "Schuldschein aktuell: alle $SOLL_N Eintraege bestehen noch"
  else
    ko "LINT_DEBT nennt Eintraege ohne Verstoss:$NUR_SOLL — behoben? Dann hier streichen (die Liste schrumpft, das ist der Zweck)"
  fi

  # Richtung 3: die Anzahl je Eintrag. Faengt Wachstum INNERHALB einer schon
  # gelisteten Datei/Regel-Kombination, das die beiden Mengenvergleiche oben
  # per Konstruktion nicht sehen.
  ABW=""
  while IFS='|' read -r F R N; do
    [ -z "$F" ] && continue
    IST_C=$(printf '%s\n' "$IST" | awk -F'|' -v f="$F" -v r="$R" '$1==f && $2==r {print $3}')
    IST_C=${IST_C:-0}
    [ "$IST_C" = "$N" ] || ABW="$ABW $F/$R(erwartet=$N,ist=$IST_C)"
  done <<EOF
$(printf '%s\n' "$SOLL")
EOF
  if [ -z "$ABW" ]; then
    ok "Anzahl je Eintrag unveraendert"
  else
    ko "Anzahl weicht ab:$ABW — gewachsen ist verboten, geschrumpft gehoert nachgezogen"
  fi
fi

printf '\n\033[1m%s\033[0m\n' "Ergebnis: $PASS grün, $FAIL rot"
[ "$FAIL" -eq 0 ] || exit 1
