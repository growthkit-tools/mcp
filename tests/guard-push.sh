#!/usr/bin/env bash
# GrowthKit MCP — Selbsttest fuer .claude/hooks/guard-push.sh
#
#   ./tests/guard-push.sh
#
# Exit 0 = alle Faelle korrekt. Exit 1 = mindestens einer falsch.
# Exit 2 = Setup-Fehler (Guard fehlt, jq/git fehlt).
# Kein `set -e`: alle Faelle sollen laufen, damit ein Durchlauf das volle Bild zeigt.
#
# WARUM DIESE DATEI. Der Guard setzt §3 lokal durch und ist getrackt — aber bis
# hierher prueft ihn nichts. Das Risiko ist einseitig: faellt er KAPUTT, ist er
# fail-closed und lehnt ab, das faellt sofort auf. Wird er DURCHLAESSIGER, faellt
# es niemandem auf. Genau die Richtung war ungeschuetzt.
#
# SCHNITTSTELLE. Der Guard ist ein Filter, kein Kommando: Hook-Event als JSON auf
# stdin (gelesen wird nur .tool_input.command), Entscheidung als JSON auf stdout
# (hookSpecificOutput.permissionDecision), Exit-Code immer 0. Aufgerufen wird er
# hier als normaler Prozess mit einer Pipe — das triggert keinen Hook.
#
# WARUM DIE FAELLE IN DIESER DATEI STEHEN und nicht in der Kommandozeile: laeuft
# der Test unter Claude Code, inspiziert der LEBENDE Guard den Aufrufbefehl. Ein
# Inline-Aufruf mit eingebettetem Push-String wird von ihm abgelehnt. `bash
# tests/guard-push.sh` enthaelt keinen — deshalb gehoeren die Faelle hier hinein.
#
# WARUM TEMPORAERE REPOS. Der Guard liest den aktuellen Branch aus dem cwd, und
# der ist im CI NICHT stabil: das push-Event checkt einen Branch aus, das
# pull_request-Event einen Merge-Ref im detached HEAD (an zwei echten Laeufen
# verifiziert). Derselbe Test haette pro Trigger ein anderes Ergebnis. Deshalb
# bringt er seine Repo-Zustaende selbst mit.
#
# Vor jedem Commit:  bash -n tests/guard-push.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO_ROOT/.claude/hooks/guard-push.sh"

PASS=0; FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
ko(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
sec(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# §18a (c): ein fehlender Guard ist ein FEHLER, kein Grund zum Ueberspringen. Eine
# Pruefung, die verschwindet, sobald ihr Eingang verschwindet, ist keine Pruefung.
if [ ! -f "$GUARD" ]; then
  echo "Guard nicht gefunden: $GUARD — nichts zu pruefen, das ist ein Fehler." >&2
  exit 2
fi
if [ ! -s "$GUARD" ]; then
  echo "Guard ist leer: $GUARD — nichts zu pruefen, das ist ein Fehler." >&2
  exit 2
fi
command -v jq  >/dev/null || { echo "jq fehlt"  >&2; exit 2; }
command -v git >/dev/null || { echo "git fehlt" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- Repo-Zustaende, die der Guard lesen soll --------------------------------
mkrepo(){ # mkrepo <dir> <branch>
  mkdir -p "$1"
  git -C "$1" init -q -b "$2" 2>/dev/null || { git -C "$1" init -q; git -C "$1" checkout -q -b "$2"; }
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}
mkrepo "$TMP/feature" "feature/x"
mkrepo "$TMP/onmain"  "main"
mkrepo "$TMP/detach"  "feature/x"
git -C "$TMP/detach" checkout -q --detach HEAD
mkrepo "$TMP/alias"   "feature/x"
git -C "$TMP/alias" config alias.p push

# --- PATH ohne jq, portabel ---------------------------------------------------
# NICHT ueber PATH=/usr/bin:/bin: wo jq liegt, ist maschinenabhaengig (hier
# ~/.local/bin, auf dem Runner /usr/bin). Stattdessen ein Verzeichnis mit genau
# den Werkzeugen, die der Guard sonst braucht — und ohne jq.
#
# `bash` gehoert in die Liste: der Aufruf unten ist `env -i PATH=$NOJQ … bash …`,
# und env sucht bash in genau diesem PATH. Ohne den Symlink scheitert schon env
# mit "No such file or directory" — der Fall waere dann ROT AUS DEM FALSCHEN
# GRUND und saehe aus wie ein Guard-Fehler. Genau einmal passiert.
NOJQ="$TMP/nojq-bin"; mkdir -p "$NOJQ"
for t in bash cat git grep awk sed tr; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$NOJQ/$t"
done
[ -x "$NOJQ/bash" ] || { echo "bash nicht verlinkbar — der jq-Fall waere nicht aussagekraeftig" >&2; exit 2; }

COVERED=""
# check <label> <repo-dir> <erwartet: allow|deny> <kommando> [pathoverride]
check(){
  local label="$1" dir="$2" want="$3" cmd="$4" pathov="${5:-}"
  COVERED="$COVERED $label"

  local payload out got
  payload=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)")

  if [ -n "$pathov" ]; then
    out=$(cd "$dir" && printf '%s' "$payload" | env -i PATH="$pathov" HOME="$HOME" bash "$GUARD" 2>/dev/null)
  else
    out=$(cd "$dir" && printf '%s' "$payload" | bash "$GUARD" 2>/dev/null)
  fi

  # §18a (f): eine kaputte oder leere Ausgabe darf NICHT als "falsche Erwartung"
  # durchgehen. Sie bekommt einen eigenen roten Ausgang, sonst vergliche man
  # Leerstring gegen Erwartung und die Meldung zeigte in die falsche Richtung.
  if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    ko "[$label] Guard lieferte KEIN valides JSON — $cmd"
    return
  fi
  got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "FEHLT"')
  case "$got" in
    allow|deny) ;;
    *) ko "[$label] Entscheidung ist weder allow noch deny (bekam '$got') — $cmd"; return ;;
  esac

  if [ "$got" = "$want" ]; then
    ok "[$label] $got — $cmd"
  else
    ko "[$label] erwartet $want, bekam $got — $cmd"
  fi
}

# =============================================================================
sec "A · Freigaben"
# =============================================================================
check no-git        "$TMP/feature" allow "ls -la"
check no-push       "$TMP/feature" allow "git status --short"
check no-push       "$TMP/feature" allow "cd /somewhere/else && git status"
check no-push       "$TMP/feature" allow 'git commit -m "Text ueber $() und Backticks"'
check feature-push  "$TMP/feature" allow "git push"
check feature-push  "$TMP/feature" allow "git push origin feature/x"
check feature-push  "$TMP/feature" allow "git push -u origin feature/x"

# =============================================================================
sec "B · Ablehnungen — Ziel explizit genannt"
# =============================================================================
check protected-named "$TMP/feature" deny "git push origin main"
check protected-named "$TMP/feature" deny "git push -u origin main"
check protected-named "$TMP/feature" deny "git push --force origin main"
check protected-named "$TMP/feature" deny "git push origin HEAD:master"
check refspec         "$TMP/feature" deny "git push origin HEAD:release"

# =============================================================================
sec "C · Ablehnungen — Ziel verdeckt"
# =============================================================================
check all-mirror      "$TMP/feature" deny "git push --all"
check all-mirror      "$TMP/feature" deny "git push --mirror"
check cd-in-push      "$TMP/feature" deny "cd /tmp/other && git push"
check cd-in-push      "$TMP/feature" deny "git -C /tmp/x push"
check indirect-push   "$TMP/feature" deny 'bash -c "git push origin main"'
check indirect-push   "$TMP/feature" deny 'git push origin $(echo main)'
check indirect-subcmd "$TMP/feature" deny 'git $(echo push) origin main'
check alias-push      "$TMP/alias"   deny "git p origin whatever"

# =============================================================================
sec "D · Ablehnungen — aus dem Repo-Zustand"
# =============================================================================
check branch-protected "$TMP/onmain" deny "git push"
check branch-unknown   "$TMP/detach" deny "git push"

# =============================================================================
sec "E · Fehlendes jq"
# =============================================================================
# Der Guard prueft auf jq und lehnt ab, wenn es fehlt. Diese Ablehnung muss
# VALIDES JSON sein — sonst ist unklar, wie der Harness sie liest, und der
# fail-closed-Zweig ist im schlechtesten Fall fail-open.
check jq-missing "$TMP/feature" deny "git push origin main" "$NOJQ"

# =============================================================================
sec "F · Selbstpruefung des Tests"
# =============================================================================
# §18a (a): eine leere Fallliste bestuende jede Pruefung.
N_CASES=$((PASS + FAIL))
if [ "$N_CASES" -gt 0 ]; then
  ok "Fallliste nicht leer ($N_CASES Faelle)"
else
  ko "Fallliste ist leer — dieser Test prueft nichts"
fi

# Vollstaendigkeit statt Menge: der Guard hat 13 Entscheidungspunkte, und jeder
# muss mindestens einmal getroffen werden. Ohne das faellt beim Loeschen von
# Faellen die Abdeckung, ohne dass etwas rot wird.
EXPECTED_LABELS="no-git no-push feature-push protected-named refspec all-mirror cd-in-push indirect-push indirect-subcmd alias-push branch-protected branch-unknown jq-missing"
MISSING=""
for l in $EXPECTED_LABELS; do
  case " $COVERED " in *" $l "*) ;; *) MISSING="$MISSING $l" ;; esac
done
if [ -z "$MISSING" ]; then
  ok "Alle 13 Entscheidungszweige abgedeckt"
else
  ko "Nicht abgedeckte Zweige:$MISSING"
fi

# Ein Guard, der IMMER dasselbe sagt, bestuende eine getrimmte Liste. Beide
# Ausgaenge muessen im selben Lauf vorgekommen sein.
SAW_ALLOW=0; SAW_DENY=0
case " $COVERED " in *" feature-push "*) SAW_ALLOW=1 ;; esac
case " $COVERED " in *" protected-named "*) SAW_DENY=1 ;; esac
if [ "$SAW_ALLOW" -eq 1 ] && [ "$SAW_DENY" -eq 1 ]; then
  ok "Beide Ausgaenge im selben Lauf beobachtet"
else
  ko "Nur ein Ausgang beobachtet — ein Guard, der immer dasselbe sagt, waere ununterscheidbar"
fi

printf '\n\033[1mErgebnis: %d grün, %d rot\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
