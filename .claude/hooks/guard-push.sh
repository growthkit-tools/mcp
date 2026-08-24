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

# deny() escapt OHNE jq. Die erste Fassung benutzte `jq -Rs .` — und damit hing
# ausgerechnet der Zweig, der ein fehlendes jq melden soll, an jq: ohne jq wurde
# die Substitution leer und die Ausgabe war
#   {"...","permissionDecisionReason":}}   <- ungueltiges JSON
# Wie der Harness ungueltige Hook-Ausgabe liest, ist unbekannt; im schlechtesten
# Fall fail-open, also genau die Richtung, gegen die dieser Guard gebaut wurde.
# §18a (c) in Reinform: eine Pruefung, die verschwindet, sobald ihr Eingang
# verschwindet. Gefunden von tests/guard-push.sh, bevor es jemand gebraucht hat.
#
# Die Begruendungen sind einzeilig und ASCII — Backslash und Anfuehrungszeichen
# zu escapen reicht, und `sed` liegt dort, wo auch `git` liegt.
deny(){
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' \
    "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  exit 0
}

# jq wird zum LESEN des Events gebraucht — ohne es gibt es kein .tool_input.command.
# Der Zweig bleibt deshalb, aber deny() kommt jetzt ohne jq aus.
command -v jq >/dev/null 2>&1 || deny "guard-push: jq fehlt — ohne jq kann der Guard das Event nicht lesen, also lehnt er ab (fail-closed)."

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

# ─────────────────────────────────────────────────────────────────────────────
# AUSFUEHRENDE Indirektion — bleibt VOR der Segmenterkennung.
#
# `eval`, `bash -c`, `sh -c` und `xargs` fuehren eine Zeichenkette AUS. Der
# Segmentierer unten sieht in diese Zeichenkette nicht hinein: fuer ihn ist
# `bash -c "git push origin main"` ein Segment, dessen erstes Wort `bash` ist —
# also kein Push. Das Kommando pusht aber sehr wohl auf main.
#
# ⚠️ Genau dieser Fall ist beim Verengen am 24.08. aufgerissen und vom
# bestehenden Testfall [indirect-push] gefangen worden. Er ist der Grund, warum
# die Abnahme BEIDE Richtungen verlangt: die Verengung sah in allen vier
# Fehlalarm-Faellen richtig aus und hatte trotzdem ein Loch.
#
# Unterschieden wird nach DATEN vs. AUSFUEHRUNG:
#   hier    — eval / bash -c / sh -c / xargs: fuehren aus, koennen den Push
#             enthalten, ohne dass er als Segment sichtbar wird.
#   spaeter — $( ) und Backticks: liefern einen WERT. In einer Commit-Message
#             sind sie Daten; erst wenn tatsaechlich ein Push stattfindet,
#             machen sie dessen Ziel unlesbar.
# ─────────────────────────────────────────────────────────────────────────────
if printf '%s' "$CMD" | grep -qE '(^|[^[:alnum:]_-])push([^[:alnum:]_-]|$)'; then
  case "$CMD" in
    *'eval '*|*'bash -c'*|*'sh -c'*|*'xargs'*)
      deny "guard-push: Kommando fuehrt eine Zeichenkette aus (eval, bash -c, sh -c oder xargs) und enthaelt das Wort 'push'. Was dabei ausgefuehrt wird, ist statisch nicht bestimmbar — Ablehnung (fail-closed). Ohne Indirektion neu formulieren." ;;
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
# Bleibt als schneller Vorfilter: die Zerlegung unten kostet mehr als ein grep.
printf '%s' "$CMD" | grep -qE '(^|[^[:alnum:]_-])push([^[:alnum:]_-]|$)' || allow

# ═════════════════════════════════════════════════════════════════════════════
# VERENGUNG (24.08.2026) — Kommandostruktur statt Kommandotext.
#
# Bis hierher galt: das Wort `push` irgendwo im Text => es ist ein Push, und ab
# da liefen die Zielpruefungen ueber das GANZE Kommando. Zwischen dem 21. und
# 24.08. hat das vier Fehlalarme erzeugt, alle ohne einen einzigen Push:
#
#   git commit -m "feat: push notification handler"   -> Refspec-`:`-Zweig
#   git commit -m "docs: … git push …"                -> Refspec-`:`-Zweig
#   git commit -m "fix: $(date) und push"             -> Indirektions-Zweig
#   git checkout -b tmp origin/main && git push origin tmp
#                                                     -> `/main` im Text
#
# Der letzte Fall zeigt, dass "push muss Subkommando sein" allein NICHT reicht:
# dort IST push das Subkommando. Das Problem ist, dass `origin/main` in einem
# ANDEREN Segment steht — der Checkout-Basis. Es braucht deshalb zwei Schritte:
#
#   (a) SUBKOMMANDO-ERKENNUNG — `push` als erstes Nicht-Options-Wort nach `git`.
#   (b) SEGMENT-ISOLIERUNG    — die Zielpruefungen sehen nur das Push-Segment.
#
# ⚠️ DIE GRENZE BLEIBT. Der Guard bekommt einen String, keine geparste
# Kommandostruktur. Das hier ist eine textuelle Naeherung an eine Shell-
# Grammatik, keine Grammatik. Jede Unsicherheit faellt weiterhin auf DENY:
# ein Segment, dessen Subkommando nicht sicher bestimmbar ist, gilt als Push.
#
# ⚠️ NICHT SAUBER TRENNBAR: HEREDOC-KOERPER. Ein `cat > x.sh <<EOF` mit
# `git push origin main` im Rumpf enthaelt Text, der wie ein Kommando aussieht
# und keines ist. Ihn zuverlaessig auszuschliessen hiesse, Heredoc-Begrenzer zu
# parsen — und ein falsch erkannter Begrenzer wuerde einen ECHTEN Push nach dem
# Heredoc verschlucken. Das waere ein fail-OPEN-Pfad an der empfindlichsten
# Stelle, und dafuer ist der Gegenwert zu klein. Der Rumpf wird deshalb wie
# Kommandotext behandelt: nennt er einen geschuetzten Branch, wird abgelehnt.
# Im Normalzustand (Feature-Branch, kein geschuetzter Name im Rumpf) laeuft er
# durch. Bewusst offen gelassen, siehe AGENTS.md.
# ═════════════════════════════════════════════════════════════════════════════

# Segmente. Trenner: && || ; | und Zeilenumbruch. Anfuehrungszeichen werden NICHT
# ausgewertet — ein `;` in einer Zeichenkette trennt also ebenso wie ein echtes.
# Die Naeherung ist bewusst grob in Richtung MEHR Segmente: ein zu viel
# getrenntes Kommando erzeugt hoechstens ein zusaetzliches Segment, das kein
# Push ist. Zu wenige Segmente waeren die gefaehrliche Richtung.
NL='
'
SEGS=${CMD//&&/$NL}
SEGS=${SEGS//||/$NL}
SEGS=${SEGS//;/$NL}
SEGS=${SEGS//|/$NL}

# Klassifiziert EIN Segment: 0 = Push (oder nicht sicher bestimmbar), 1 = anderes
# git-Kommando bzw. gar keines.
#
# "Nicht sicher bestimmbar" faellt bewusst auf die Push-Seite: lieber ein
# Segment zu viel pruefen als eines zu wenig.
seg_is_push() {
  local s="$1"
  # Fuehrende Leerzeichen und Klammern (Subshell) weg.
  s="${s#"${s%%[![:space:]\(]*}"}"
  # Vorangestellte Umgebungszuweisungen ueberspringen: FOO=bar git push
  while :; do
    case "$s" in
      [A-Za-z_]*=*\ *) s="${s#* }"; s="${s#"${s%%[![:space:]]*}"}" ;;
      *) break ;;
    esac
  done
  # Erstes Wort muss git sein (auch /usr/bin/git).
  case "$s" in
    git|git[[:space:]]*|*/git|*/git[[:space:]]*) : ;;
    *) return 1 ;;
  esac

  # Globale git-Optionen ueberspringen, bis das Subkommando dasteht.
  local noglob_was_set=0
  case "$-" in *f*) noglob_was_set=1 ;; esac
  set -f
  # shellcheck disable=SC2086
  set -- $s
  shift                      # das `git` selbst
  while [ $# -gt 0 ]; do
    case "$1" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env)
        shift 2 || true ;;                       # Option mit getrenntem Wert
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--config-env=*)
        shift ;;
      --no-pager|-p|--paginate|--bare|--no-replace-objects|--literal-pathspecs|\
      --glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks|\
      --html-path|--man-path|--info-path|--version|--help)
        shift ;;
      -*)
        # Unbekannte Option: sie koennte einen Wert schlucken und damit das
        # Subkommando verschieben. Nicht sicher bestimmbar -> als Push behandeln.
        [ "$noglob_was_set" -eq 1 ] || set +f
        return 0 ;;
      *) break ;;
    esac
  done
  local sub="${1:-}"
  [ "$noglob_was_set" -eq 1 ] || set +f
  [ "$sub" = "push" ]
}

# Push-Segmente einsammeln.
PUSH_SEGS=""
while IFS= read -r seg; do
  [ -z "$seg" ] && continue
  if seg_is_push "$seg"; then
    PUSH_SEGS="$PUSH_SEGS$seg$NL"
  fi
done <<EOF
$SEGS
EOF

# Das Wort `push` kommt vor, aber in keinem Segment als Subkommando: es ist
# Fliesstext — eine Commit-Message, ein Kommentar, ein Dateiname. Kein Push.
[ -n "$PUSH_SEGS" ] || allow

# ─────────────────────────────────────────────────────────────────────────────
# Indirektion irgendwo im Kommando — jetzt, wo feststeht, dass ueberhaupt ein
# Push stattfindet.
#
# BEWUSST KOMMANDOWEIT und nicht je Segment: `eval "$X" && git push` hat ein
# harmloses Push-Segment, aber das eval davor kann den Branch gewechselt haben.
# Der Guard prueft HEAD zur Hook-Zeit, also VOR der Ausfuehrung — er saehe den
# alten Branch und erlaubte einen Push auf den neuen. Segmentweise geprueft
# waere das ein fail-OPEN-Pfad.
#
# Die Verschiebung hinter die Segmenterkennung behebt trotzdem den Fehlalarm,
# um den es geht: `git commit -m "fix: $(date) und push"` hat gar kein
# Push-Segment und ist hier nie angekommen.
#
# Preis, bewusst: `git commit -m "$(date)" && git push origin tmp` wird weiter
# abgelehnt. Ein echter Push mit Indirektion irgendwo — konservativ und selten.
# ─────────────────────────────────────────────────────────────────────────────
case "$CMD" in
  *'$('*|*'`'*)
    deny "guard-push: Push-Kommando enthaelt eine Substitution (\$() oder Backticks). Das Ziel ist statisch nicht bestimmbar — Ablehnung (fail-closed). Ohne Indirektion neu formulieren." ;;
esac

# --- Es ist ein Push. Jetzt positiv verifizieren. ----------------------------
#
# REIHENFOLGE IST TRAGEND: die folgenden Pruefungen stehen bewusst NACH der
# Push-Erkennung. Standen sie davor, lehnte der Guard auch harmlose Kommandos ab
# — `cd /repo && git status` ist kein Push, wurde aber vom cd-Zweig gefangen.
# Beim ersten Live-Lauf sofort aufgefallen. Was VOR der Push-Erkennung bleiben
# muss: Indirektion und Aliase, denn beide koennen das Wort `push` verbergen.

# Verzeichniswechsel: KOMMANDOWEIT, nicht je Segment. Ein `cd` in einem frueheren
# Segment aendert das Arbeitsverzeichnis des Push-Segments tatsaechlich — die
# Isolierung von oben gilt hier also ausdruecklich NICHT.
case "$CMD" in
  *'cd '*|*' -C '*)
    deny "guard-push: Push-Kommando wechselt das Verzeichnis (cd oder git -C). Der Guard bestimmt den Branch im aktuellen Repo und kann fuer ein anderes nicht entscheiden — Ablehnung (fail-closed). Ein CC-Lauf arbeitet in genau einem Repo (AGENTS.md §3)." ;;
esac

# Ab hier: nur noch das PUSH-SEGMENT. Was in einer Commit-Message, einer
# Checkout-Basis oder einem Dateinamen steht, geht diese Pruefungen nichts an.
while IFS= read -r pseg; do
  [ -z "$pseg" ] && continue

  # Formen, die main mitnehmen koennen, ohne main zu nennen.
  case "$pseg" in
    *--all*|*--mirror*)
      deny "guard-push: 'git push --all' bzw. '--mirror' pusht ALLE Branches, main eingeschlossen, ohne dass main im Kommando steht. Ablehnung (AGENTS.md §3)." ;;
  esac

  # Explizit genanntes geschuetztes Ziel — auch als Refspec-Zielseite (HEAD:main,
  # feature:main, refs/heads/x:refs/heads/main).
  for b in $PROTECTED; do
    case "$pseg" in
      *":$b"*|*":refs/heads/$b"*|*" $b"*|*"/$b"*)
        deny "guard-push: Das Push-Kommando nennt den geschuetzten Branch '$b'. Push auf $b ist nicht erlaubt (AGENTS.md §3) — er geht ueber einen PR. Branch Protection wuerde ihn ohnehin abweisen (enforce_admins: true)." ;;
    esac
  done

  # Refspec mit Doppelpunkt, dessen Zielseite nicht eindeutig gelesen werden kann.
  case "$pseg" in
    *:*)
      # Nur Refspecs betrachten, keine URLs (git@host:pfad, https://).
      case "$pseg" in
        *"://"*|*"@"*) : ;;
        *) deny "guard-push: Refspec mit ':' im Push-Kommando — die Zielseite wird nicht interpretiert, weil ein Fehlgriff auf main landen koennte. Ablehnung (fail-closed). Ohne Refspec pushen." ;;
      esac ;;
  esac
done <<EOF
$PUSH_SEGS
EOF

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
