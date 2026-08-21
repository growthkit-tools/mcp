#!/usr/bin/env bash
# GrowthKit MCP — PreToolUse-Guard: kein Push auf main (AGENTS.md §3)
#
# Liest das Hook-Event als JSON auf stdin, gibt eine Entscheidung als JSON auf
# stdout aus (hookSpecificOutput.permissionDecision).
#
#   echo '{"tool_name":"Bash","tool_input":{"command":"git push"}}' | .claude/hooks/guard-push.sh
#
# ─────────────────────────────────────────────────────────────────────────────
# FAIL-CLOSED, und das ist der ganze Entwurf.
#
# Der Hook erlaubt NUR, was er POSITIV als "Ziel ist nicht main" verifizieren
# kann. Alles andere wird abgelehnt — auch Exotisches, das er nicht sicher
# einordnet. Die Fehlerrichtung ist damit "Chris drueckt den Push von Hand", wie
# vor dieser Aenderung. Die andere Richtung waere "Push landet auf main".
#
# Er ist NICHT die einzige Schicht: seit dem 20.08. steht enforce_admins: true
# auf der Branch Protection, ein direkter Push auf main wird also auch
# serverseitig abgewiesen — fuer Admins ebenso. Genau deshalb DARF dieser Hook
# streng sein: ein falsches Nein kostet einen manuellen Push, ein falsches Ja
# faengt der Server. Waere enforce_admins false (bis 20.08. der Fall), muesste
# dieser Parser vollstaendig sein — und das bekommt niemand dicht.
#
# KEIN `if`-FILTER IN settings.json. Die naheliegende Verdrahtung
# `"if": "Bash(git push:*)"` ist Praefix-Matching: `cd /x && git push` beginnt
# nicht mit `git push`, der Hook wuerde gar nicht erst starten, und das Kommando
# liefe durch. Der Hook laeuft deshalb auf JEDEM Bash-Aufruf und entscheidet
# selbst. Der schnelle Pfad unten haelt die Kosten dafuer klein.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

PROTECTED='main master'

allow(){ printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'; exit 0; }
deny(){
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$1" | jq -Rs .)"
  exit 0
}

command -v jq >/dev/null 2>&1 || deny "guard-push: jq fehlt — ohne jq kann der Guard nicht entscheiden, also lehnt er ab (fail-closed)."

EVENT=$(cat)
CMD=$(printf '%s' "$EVENT" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Schneller Pfad: ohne `git` im Kommando ist es kein Push. Das ist die EINZIGE
# Stelle, an der ohne Ansehen des Ziels erlaubt wird.
printf '%s' "$CMD" | grep -qE '(^|[^[:alnum:]_-])git([^[:alnum:]_-]|$)' || allow

# --- Ab hier ist git im Spiel. Alles Undurchschaubare wird abgelehnt. --------

# Indirektion. Sie muss VOR der Push-Erkennung geprueft werden, weil sie das Wort
# `push` verbergen kann (`git $(echo push) origin main`).
#
# ABER NICHT PAUSCHAL: eine erste Fassung lehnte jedes git-Kommando ab, dessen
# TEXT `$(` enthielt — und fing damit `git commit -m "... $() ..."`, also eine
# Commit-Message, die ueber Indirektion schreibt. Beim ersten Live-Lauf sofort
# passiert. Gefaehrlich ist Indirektion nur an zwei Stellen:
#   (1) in der Subkommando-Position: `git $(...)`, `git `...``, `git ${...}`
#   (2) irgendwo, wenn `push` ohnehin im Kommando steht
# Beides wird abgelehnt, der Rest laeuft weiter.
#
# RESTLUECKE, bewusst offen: ein Kommando, das weder `git` in Subkommando-Position
# noch `push` im Text hat und den Push voellig zur Laufzeit baut (etwa
# `eval "$VAR"`), passiert den Guard. Dagegen haelt die Branch Protection
# (enforce_admins: true) — der Guard ist die schnelle Schicht, nicht die letzte.
case "$CMD" in
  *'git $('*|*'git `'*|*'git ${'*)
    deny "guard-push: Indirektion in der git-Subkommando-Position (git \$(...) oder git \`...\`). Was ausgefuehrt wird, ist statisch nicht bestimmbar — Ablehnung (fail-closed). Bitte ausgeschrieben aufrufen." ;;
esac

if printf '%s' "$CMD" | grep -qE '(^|[^[:alnum:]_-])push([^[:alnum:]_-]|$)'; then
  case "$CMD" in
    *'$('*|*'`'*|*'eval '*|*'bash -c'*|*'sh -c'*|*'xargs'*)
      deny "guard-push: Push-Kommando enthaelt Indirektion (\$(), Backticks, eval, sh -c oder xargs). Das Ziel ist statisch nicht bestimmbar — Ablehnung (fail-closed). Ohne Indirektion neu formulieren." ;;
  esac
fi

# git-Aliase koennen einen Push verstecken (`git p`). Wenn irgendein Alias in
# diesem Repo auf push zeigt, ist eine Praefix-Erkennung nicht mehr verlaesslich.
ALIAS_PUSH=$(git config --get-regexp '^alias\.' 2>/dev/null | grep -i 'push' | awk '{print $1}' | sed 's/^alias\.//' | tr '\n' ' ')
if [ -n "$ALIAS_PUSH" ]; then
  for a in $ALIAS_PUSH; do
    case "$CMD" in
      *"git $a"*) deny "guard-push: Kommando benutzt den git-Alias '$a', der auf push zeigt. Aliase werden nicht aufgeloest — Ablehnung (fail-closed). Bitte ausgeschrieben pushen." ;;
    esac
  done
fi

# Kein `push` im Kommando -> es ist ein anderer git-Befehl.
printf '%s' "$CMD" | grep -qE '(^|[^[:alnum:]_-])push([^[:alnum:]_-]|$)' || allow

# --- Es ist ein Push. Jetzt positiv verifizieren. ----------------------------
#
# REIHENFOLGE IST TRAGEND: die folgenden Pruefungen stehen bewusst NACH der
# Push-Erkennung. Standen sie davor, lehnte der Guard auch harmlose Kommandos ab
# — `cd /repo && git status` ist kein Push, wurde aber vom cd-Zweig gefangen.
# Beim ersten Live-Lauf sofort aufgefallen. Was VOR der Push-Erkennung bleiben
# muss: Indirektion und Aliase, denn beide koennen das Wort `push` verbergen.

# Verzeichniswechsel: der aktuelle Branch waere ein anderer als der hier
# ermittelte.
case "$CMD" in
  *'cd '*|*' -C '*)
    deny "guard-push: Push-Kommando wechselt das Verzeichnis (cd oder git -C). Der Guard bestimmt den Branch im aktuellen Repo und kann fuer ein anderes nicht entscheiden — Ablehnung (fail-closed)." ;;
esac

# Formen, die main mitnehmen koennen, ohne main zu nennen.
case "$CMD" in
  *--all*|*--mirror*)
    deny "guard-push: 'git push --all' bzw. '--mirror' pusht ALLE Branches, main eingeschlossen, ohne dass main im Kommando steht. Ablehnung (AGENTS.md §3)." ;;
esac

# Explizit genanntes geschuetztes Ziel — auch als Refspec-Zielseite (HEAD:main,
# feature:main, refs/heads/x:refs/heads/main).
for b in $PROTECTED; do
  case "$CMD" in
    *":$b"*|*":refs/heads/$b"*|*" $b"*|*"/$b"*)
      deny "guard-push: Das Kommando nennt den geschuetzten Branch '$b'. Push auf $b ist nicht erlaubt (AGENTS.md §3) — er geht ueber einen PR. Branch Protection wuerde ihn ohnehin abweisen (enforce_admins: true)." ;;
  esac
done

# Refspec mit Doppelpunkt, dessen Zielseite nicht eindeutig gelesen werden kann.
case "$CMD" in
  *:*)
    # Nur Refspecs betrachten, keine URLs (git@host:pfad, https://).
    case "$CMD" in
      *"://"*|*"@"*) : ;;
      *) deny "guard-push: Refspec mit ':' — die Zielseite wird nicht interpretiert, weil ein Fehlgriff auf main landen koennte. Ablehnung (fail-closed). Ohne Refspec pushen." ;;
    esac ;;
esac

# Aktuellen Branch bestimmen. Schlaegt das fehl, ist keine Aussage moeglich.
CUR=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
if [ -z "$CUR" ]; then
  deny "guard-push: Aktueller Branch nicht bestimmbar (detached HEAD oder kein Repo). Ohne Branch keine Aussage ueber das Ziel — Ablehnung (fail-closed)."
fi

for b in $PROTECTED; do
  if [ "$CUR" = "$b" ]; then
    deny "guard-push: Aktueller Branch ist '$CUR'. Ein Push ohne ausdrueckliches Ziel ginge dorthin. Ablehnung (AGENTS.md §3) — auf einen Feature-Branch wechseln und einen PR oeffnen."
  fi
done

# Positiv verifiziert: git push, kein --all/--mirror, kein geschuetztes Ziel
# genannt, keine Refspec, kein cd, keine Indirektion, aktueller Branch ist ein
# Feature-Branch. Das Ziel kann damit nur dieser Feature-Branch sein.
allow
