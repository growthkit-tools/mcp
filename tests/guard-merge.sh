#!/usr/bin/env bash
# GrowthKit MCP — Selbsttest fuer .github/scripts/guard-merge.sh
#
#   ./tests/guard-merge.sh
#
# Exit 0 = alle Faelle korrekt. Exit 1 = mindestens einer falsch.
# Exit 2 = Setup-Fehler (Guard fehlt, jq fehlt).
# Kein `set -e`: alle Faelle sollen laufen, damit ein Durchlauf das volle Bild zeigt.
#
# WARUM DIESE DATEI. Dieselbe einseitige Risikorichtung wie bei guard-push:
# faellt der Guard KAPUTT, ist er fail-closed und macht PRs rot — das faellt
# sofort auf. Wird er DURCHLAESSIGER, faellt es niemandem auf, und dann merged
# Auto-Merge Dinge durch, die ein Mensch haette sehen sollen. Genau die
# Richtung ist ohne diese Suite ungeschuetzt.
#
# VORLAGE: supabase `tests/guard-merge.sh` (#142/#143/#145). Uebernommen ist die
# Bauart — Filter statt Kommando, JSON auf stdin, inline-Fixtures, drei
# Ausgaenge —, NICHT die Regeln. Die Regeln dieses Repos sind aus einer eigenen
# Messung entstanden (SPEC-guard-merge-auto-merge.md §6, R0 vom 22.09.2026):
#   R1' Golden unveraendert, ausser der PR-Body nennt "Golden aktualisiert" mit
#       Grund — hier gibt es keine Migrationen, aber einen Golden Master.
#   R2  Falsifikationsbeleg, wenn Code oder Suiten beruehrt sind — im Body ODER
#       in einer Commit-Message (§18b dieses Repos legt ihn in den Commit).
#   R3  entfaellt: es gibt hier keine geteilte Schicht (gemessen, s. Guard).
#   R4  keine Workflows, nicht der Guard selbst.
#
# WARUM DIE FIXTURES INLINE STEHEN: eine Dateiliste ist eine Handvoll Strings.
# Als Datei waere sie eine zweite Stelle, an der derselbe Fall steht.
#
# Vor jedem Commit:  bash -n tests/guard-merge.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_ROOT/.github/scripts/guard-merge.sh"

PASS=0; FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
ko(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
sec(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

printf '\n\033[1m%s\033[0m\n' "guard-merge — $GUARD"

# §18a (c): ein fehlender Guard ist ein FEHLER, kein Grund zum Ueberspringen.
if [ ! -f "$GUARD" ]; then
  echo "Guard nicht gefunden: $GUARD — nichts zu pruefen, das ist ein Fehler." >&2
  exit 2
fi
if [ ! -s "$GUARD" ]; then
  echo "Guard ist leer: $GUARD — nichts zu pruefen, das ist ein Fehler." >&2
  exit 2
fi
command -v jq >/dev/null || { echo "jq fehlt" >&2; exit 2; }

# Ein Body mit Beleg, und einer ohne. Die Schreibweisen unten in C sind
# Absicht: gemessen wird der Wortstamm, nicht eine Ueberschrift.
FALSI='## Belege — FALSIFIZIERT, eine Injektion, ein roter Lauf.'
OHNE='Kleine Aenderung, siehe Diff.'

# ev <files-json-array> <body> [commits-json-array]
#   Baut die Eingabe des Guards. `commits` ist Pflicht beim Guard (fail-closed);
#   die Fixtures geben es deshalb immer mit, als leeres Array wenn unwichtig.
ev(){
  local files="$1" body="$2" commits="${3:-[]}"
  jq -nc --argjson f "$files" --arg b "$body" --argjson c "$commits" \
    '{files: $f, body: $b, commits: $c}'
}

COVERED=""
# check <label> <erwarteter-exit> <erwartetes-muster|-> <json>
#   Das Muster prueft die MELDUNG, nicht nur den Code. Ohne das bestuende ein
#   Guard, der bei jeder Verletzung dieselbe Zeile ausgibt — und dann saehe
#   "R1' rot" genauso aus wie "R4 rot" (§18a d: es muss das RICHTIGE gelten).
check(){
  local label="$1" want="$2" muster="$3" json="$4"
  COVERED="$COVERED $label"
  local out rc
  out=$(printf '%s' "$json" | bash "$GUARD" 2>&1); rc=$?

  if [ "$rc" != "$want" ]; then
    ko "[$label] erwartet Exit $want, bekam $rc — $(printf '%s' "$out" | head -1)"
    return
  fi
  # ⚠️ `grep -c` statt `grep -q`: unter `set -o pipefail` schickt ein frueh
  # aussteigendes grep dem printf SIGPIPE, und die Bedingung kippt TROTZ
  # Treffer — intermittierend (drueben gemessen: 18 von 40 Laeufen). Eine
  # Suite, die sporadisch rot wird, wird entschaerft statt gelesen.
  local treffer=1
  [ "$muster" = "-" ] || treffer=$(printf '%s' "$out" | grep -cE "$muster" || true)
  if [ "${treffer:-0}" -eq 0 ]; then
    ko "[$label] Exit $rc stimmt, aber die Meldung nennt '$muster' nicht: $(printf '%s' "$out" | head -1)"
    return
  fi
  ok "[$label] Exit $rc — $(printf '%s' "$out" | head -1)"
}

# =============================================================================
sec "A · Gruen — Auto-Merge darf greifen"
# =============================================================================
check gruen 0 '^guard-merge: keine Regel verletzt' \
  "$(ev '["index.js"]' "$FALSI")"

# Ein PR ohne Dateien verletzt nichts. Der fehlgeschlagene Abruf sieht von hier
# aus genauso aus und wird deshalb im Workflow gefangen, wo der Exit-Code noch
# sichtbar ist (§18a l: ein Objekt, zwei Ereignisse).
check gruen 0 '^guard-merge: keine Regel verletzt' "$(ev '[]' '')"

# =============================================================================
sec "B · Rot — je Regel ein Fixture, das rot sein MUSS"
# =============================================================================
# Ein Guard, der bei allem gruen ist, misst nichts (Spec §5).

# R1': der Golden Master — beide Dateien, die es gibt (R0: probe.sh schreibt
# tools.json, demo-surface.sh demo-tools.json).
check R1 1 "^R1': .*tests/golden/tools\.json" \
  "$(ev '["index.js","tests/golden/tools.json"]' "$FALSI")"
check R1 1 "^R1': .*tests/golden/demo-tools\.json" \
  "$(ev '["tests/golden/demo-tools.json"]' "$FALSI")"

# Die Phrase OHNE Grund reicht nicht — "mit Grund" ist Teil der Regel. Sonst
# waere sie eine Zauberformel, die man ohne Nachdenken dazuschreibt.
check R1-ohne-grund 1 "^R1': " \
  "$(ev '["tests/golden/tools.json"]' "$FALSI"$'\n'"Golden aktualisiert.")"
check R1-ohne-grund 1 "^R1': " \
  "$(ev '["tests/golden/tools.json"]' "$FALSI"$'\n'"**Golden aktualisiert**")"

# R2 ueber index.js — die Hauptquelle dieses Repos. R0: es gibt hier kein src/,
# ein wortgetreues `src/**` haette den Worker selbst NIE erfasst.
check R2 1 '^R2: ' "$(ev '["index.js"]' "$OHNE")"
check R2 1 '^R2: ' "$(ev '["tests/pipeline-tools.sh"]' "$OHNE")"
check R2 1 '^R2: ' "$(ev '["mcp-directory-shim/src/core.ts"]' "$OHNE")"
check R2 1 '^R2: ' "$(ev '["scripts/probe.sh"]' "$OHNE")"
# Commit-Messages zaehlen — aber nur, wenn sie den Beleg AUCH tragen.
check R2 1 '^R2: ' "$(ev '["index.js"]' "$OHNE" '["fix: kleiner Fix","test: Abschnitt L"]')"

check R4 1 '^R4: .*workflows/ci\.yml' "$(ev '[".github/workflows/ci.yml"]' "$FALSI")"
# Der Guard darf seine eigene Aenderung nicht durchwinken — sonst koennte ein
# PR ihn in einem Lauf abschalten.
check R4 1 '^R4: .*guard-merge' "$(ev '[".github/scripts/guard-merge.sh"]' "$FALSI")"
check R4 1 '^R4: .*guard-merge' "$(ev '["tests/guard-merge.sh"]' "$FALSI")"

# Mehrere Regeln gleichzeitig: jede bekommt ihre eigene Zeile.
check mehrfach 1 "^R1': " "$(ev '["index.js","tests/golden/tools.json"]' "$OHNE")"
check mehrfach 1 '^R2: '  "$(ev '["index.js","tests/golden/tools.json"]' "$OHNE")"

# =============================================================================
sec "C · Gegenproben — muessen GRUEN bleiben"
# =============================================================================
# Ohne diese Gruppe waere ein Guard, der ALLES rot macht, von einem richtigen
# nicht zu unterscheiden.

# R1' mit Phrase UND Grund — der gewollte Weg, eine Golden-Aenderung zu tragen.
check gegen-R1 0 '-' \
  "$(ev '["index.js","tests/golden/tools.json"]' "$FALSI"$'\n'"Golden aktualisiert: neue Property campaign_lead_id an vier Tools.")"
check gegen-R1 0 '-' \
  "$(ev '["tests/golden/tools.json"]' "$FALSI"$'\n'"**Golden aktualisiert** — updateCampaign traegt fit_gate_min_score.")"
# Gross-/Kleinschreibung spielt keine Rolle.
check gegen-R1 0 '-' \
  "$(ev '["tests/golden/tools.json"]' "$FALSI"$'\n'"golden aktualisiert (Schema: zwei neue Tools)")"

# R2 — der Beleg darf in einer Commit-Message stehen. Das ist die Messung aus
# R0: auf dem Body allein waeren 19 von 21 Code-PRs rot gewesen, weil §18b den
# Beleg in den Commit legt.
check gegen-R2-commit 0 '-' \
  "$(ev '["index.js"]' "$OHNE" '["test: Abschnitt L","fix: x\n\nFALSIFIZIERT, drei Injektionen"]')"
# Schreibweisen: Wortstamm, case-insensitiv (drueben kalibriert).
check gegen-R2-schreibweise 0 '-' "$(ev '["index.js"]' '## Falsifikation')"
check gegen-R2-schreibweise 0 '-' "$(ev '["index.js"]' 'falsifiziert am 22.09.')"

# Ein Docs-PR hat nichts zu falsifizieren.
check gegen-R2-docs 0 '-' "$(ev '["README.md","AGENTS.md"]' "$OHNE")"
# Fixtures und Golden-Dokumentation sind KEIN Code im Sinne von R2 — aber
# tests/ ist es, also bleibt eine Fixture-Aenderung beleg-pflichtig. Die
# Gegenprobe hier ist eine Datei AUSSERHALB der R2-Pfade.
check gegen-R2-docs 0 '-' "$(ev '["server.json","glama.json"]' "$OHNE")"

# =============================================================================
sec "D · Fail-closed — Eingabe kaputt heisst NICHT gruen"
# =============================================================================
# Die gefaehrlichste Stelle: eine fehlende Liste bestuende jede Regel lautlos
# (§18a a). Sie MUSS einen eigenen Ausgang haben.
check failclosed 2 "Feld 'files' fehlt"   '{"body":"x","commits":[]}'
check failclosed 2 "'files' ist kein Array" '{"files":"a.js","body":"x","commits":[]}'
# `commits` ist Pflicht: ohne es wuerde R2 nur den Body lesen, und ein
# fehlgeschlagener Abruf saehe aus wie "kein Commit traegt einen Beleg" — oder
# schlimmer, bei einem kuenftigen Umbau wie "Beleg vorhanden".
check failclosed 2 "Feld 'commits' fehlt" '{"files":["index.js"],"body":"x"}'
check failclosed 2 "'commits' ist kein Array" '{"files":["index.js"],"body":"x","commits":"y"}'
check failclosed 2 'kein valides JSON'      'kaputt'
check failclosed 2 'kein valides JSON'      ''

# =============================================================================
sec "E · Selbstpruefung des Tests"
# =============================================================================
# §18a (a): eine leere Fallliste bestuende jede Pruefung.
N_CASES=$((PASS + FAIL))
if [ "$N_CASES" -gt 0 ]; then
  ok "Fallliste nicht leer ($N_CASES Faelle)"
else
  ko "Fallliste ist leer — dieser Test prueft nichts"
fi

# Jede Regel und jede Gegenprobe muss mindestens einmal ausgeloest worden sein.
# Ohne das faellt beim Loeschen von Faellen die Abdeckung, ohne dass etwas rot
# wird.
EXPECTED_LABELS="gruen R1 R1-ohne-grund R2 R4 mehrfach failclosed gegen-R1 gegen-R2-commit gegen-R2-schreibweise gegen-R2-docs"
MISSING=""
for l in $EXPECTED_LABELS; do
  case " $COVERED " in *" $l "*) ;; *) MISSING="$MISSING $l" ;; esac
done
if [ -z "$MISSING" ]; then
  ok "Alle Regeln und Gegenproben abgedeckt"
else
  ko "Nicht abgedeckte Faelle:$MISSING"
fi

# Ein Guard, der IMMER dasselbe sagt, bestuende eine getrimmte Liste. Alle drei
# Ausgaenge muessen im selben Lauf vorgekommen sein.
SAW_GRUEN=0; SAW_ROT=0; SAW_FC=0
case " $COVERED " in *" gruen "*) SAW_GRUEN=1 ;; esac
case " $COVERED " in *" R1 "*) SAW_ROT=1 ;; esac
case " $COVERED " in *" failclosed "*) SAW_FC=1 ;; esac
if [ "$SAW_GRUEN" -eq 1 ] && [ "$SAW_ROT" -eq 1 ] && [ "$SAW_FC" -eq 1 ]; then
  ok "Alle drei Ausgaenge (gruen, rot, fail-closed) im selben Lauf beobachtet"
else
  ko "Nicht alle Ausgaenge beobachtet — ein Guard, der immer dasselbe sagt, waere ununterscheidbar"
fi

printf '\n\033[1mErgebnis: %d grün, %d rot\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
