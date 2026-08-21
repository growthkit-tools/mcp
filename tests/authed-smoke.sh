#!/usr/bin/env bash
# GrowthKit MCP — Authentifizierter Smoke-Test
#
# Der einzige Test, der einen echten Token braucht. Er deckt genau die Lücke, die
# am 20.08. dreimal nur durch manuelle Aufrufe gefunden wurde: der Slug-Bug (#4),
# der Auth-Positivfall (#9) und die Rollenfilterung.
#
#   GK_TOKEN=gk_view_… ./tests/authed-smoke.sh <base-url>   # Umgebung
#   ./tests/authed-smoke.sh <base-url>                       # aus .gk-ci-token
#
# In CI: Secret GK_CI_TOKEN -> env GK_TOKEN (die Verbindung steht in ci.yml).
# Zwei Namen mit Absicht: lokal soll man mit dem EIGENEN Token laufen können,
# ohne ihn "CI-Token" nennen zu müssen.
#
# LOKAL OHNE UMGEBUNGSVARIABLE: `.gk-ci-token` im Repo-Root, nur der Token, eine
# Zeile. Gitignored seit #18, und die Ignore-Regel wird von
# tests/source-invariants.sh bewacht. Bewusst NICHT `.dev.vars` — die lädt
# `wrangler dev` in die WORKER-Umgebung, wo der Token nichts zu suchen hat, und
# sie würde die verifizierte Aussage "der lokale Golden-Weg läuft ohne
# .dev.vars" prüfbar falsch machen.
#
# Kein `set -e`: alle Checks sollen laufen, damit ein Durchlauf das volle Bild zeigt.
#
# ─────────────────────────────────────────────────────────────────────────────
# DREI VERSCHIEDENE ROTE WEGE — beim ersten roten Lauf zuerst hier nachsehen.
#
# Die Exit-Codes trennen nach ZUSTÄNDIGKEIT, nicht nach Symptom: 2 heißt "die
# Umgebung des Aufrufers stimmt nicht", 3 heißt "das Ziel ist nicht benutzbar",
# 1 heißt "beides stand, aber eine Assertion hat gehalten was sie soll".
#
#   exit 2  Die Umgebung des Aufrufers stimmt nicht. Vier unterscheidbare
#           Ursachen, jede mit eigener Meldung — der erste Satz sagt, welche:
#             * weder `GK_TOKEN` gesetzt noch `.gk-ci-token` vorhanden
#             * Token ist leer bzw. nur Leerraum — etwas ANDERES als "nicht
#               angelegt", deshalb eigene Meldung
#             * Token beginnt nicht mit `gk_` (meist ein mitkopiertes `Bearer `)
#             * `jq`/`curl` fehlt, oder kein Argument
#           Ein fehlendes Secret expandiert in `env:` zum LEEREN STRING — es
#           erreicht die Assertions nie.
#
#   exit 3  "ZIEL NICHT BENUTZBAR" — server-card nicht erreichbar oder ohne
#           transport.endpoint. Es gibt keine Fläche zum Prüfen; über das Token
#           ist damit NICHTS gesagt. Häufigste Ursache: gegen eine Preview
#           geprobt, deren Workers Build noch läuft. Fix: warten, nicht am Token
#           suchen. Der Job hängt deshalb an `needs: probe`.
#
#   exit 1  Assertion A: "authentifizierte Liste ist keine echte Teilmenge"
#           Ein Token IST angekommen, aber der Server hat ihn nicht akzeptiert
#           oder nicht heruntergestuft. Drei Ursachen, gleiche Signatur:
#             * ungültig / abgelaufen / deaktiviert
#             * `Bearer ` steht im Secret-Wert (dann greift der gk_-Zweig nicht,
#               der Request läuft in den OAuth-Pfad — vgl. AGENTS.md §15, das für
#               n8n GENAU DAS GEGENTEIL vorschreibt)
#             * es ist ein Admin-Token statt gk_view_
#
# WARUM 3 UND NICHT NUR EINE KLARERE MELDUNG. Beim ersten Lauf (20.08.) lagen
# "Secret fehlt" und "Preview noch nicht da" beide unter exit 2. Der Job war rot,
# die Anleitung schickte zum Secret — das aber korrekt gesetzt war. Liegen zwei
# Ursachen unter einer Signatur, ist die Signatur das Problem, nicht ihr Text.
# Dasselbe Muster wie `data.path` im 401 des Workers: ein maschinenlesbarer
# Diskriminator statt Meldungen zu parsen. Die 0/1/2-Konvention der anderen
# Skripte wird hier bewusst um 3 erweitert; sie kennen den Fall nicht, weil sie
# nicht an einer erst entstehenden Fläche hängen.
# ─────────────────────────────────────────────────────────────────────────────
#
# KEIN TOKEN IM LOG. GitHub maskiert nur exakte Treffer registrierter Secrets;
# abgeleitete Formen und Teilstrings nicht. Dieses Skript gibt weder den Token
# noch Teile davon aus — auch nicht in Fehlermeldungen.
#
# Vor jedem Commit:  bash -n tests/authed-smoke.sh

set -uo pipefail

BASE="${1:-}"
if [ -z "$BASE" ]; then
  echo "Usage: GK_TOKEN=gk_view_… $0 <base-url>" >&2
  exit 2
fi
BASE="${BASE%/}"

# --- Token beschaffen ---------------------------------------------------------
# Setup-Guard, KEIN Selbst-Skip. Die Entscheidung "läuft nicht" gehört der CI,
# nicht diesem Skript — ein still übersprungener Test ist §18a Fall (a).
#
# Zwei Quellen, in dieser Reihenfolge: Umgebung (so laeuft CI), sonst die lokale
# Datei .gk-ci-token im Repo-Root (so laeuft es hier, ohne pushen und warten).
#
# DIE GRENZE, DIE DIESEN FALLBACK TRAEGT: geprueft wird nur die FORM, nie die
# GUELTIGKEIT. Ein Token, das `gk_` heisst und trotzdem falsch ist — abgelaufen,
# deaktiviert, fremder Workspace, Admin statt gk_view_ — passiert hier
# unveraendert und landet in Assertion A, wo 68 statt 30 Tools zurueckkommen.
# Wuerde die Gueltigkeit hier geprueft, wanderte die Aussage von der Kollision in
# die Dateipruefung, und dort waere sie schwaecher.
#   exit 2 = "ich habe gar keinen Token bekommen"  (Herkunft egal)
#   exit 1 = "ich hatte einen, der Server hat ihn nicht akzeptiert"
TOKEN_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.gk-ci-token"

# Trailing/leading Whitespace weg — fuer BEIDE Quellen. Ein `echo` statt `printf`
# beim Anlegen der Datei haengt ein \n an; ein GitHub-Secret kann eines
# mitbringen. Ungetrimmt liefe so ein Token in die 68-Kollision und saehe aus wie
# ein FALSCHES Token statt wie ein Formatproblem — eine fuenfte Ursache unter
# einer bestehenden Signatur, und genau die trennen wir hier.
trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

TOKEN_SRC=""
TOKEN_RAW=""
if [ -n "$(trim "${GK_TOKEN:-}")" ]; then
  TOKEN_RAW="${GK_TOKEN}"; TOKEN_SRC="Umgebung (GK_TOKEN)"
elif [ -f "$TOKEN_FILE" ]; then
  TOKEN_RAW="$(cat "$TOKEN_FILE")"; TOKEN_SRC=".gk-ci-token"
else
  echo "Kein Token: weder GK_TOKEN gesetzt noch $TOKEN_FILE vorhanden." >&2
  echo "  lokal: Datei anlegen — printf '%s' 'gk_view_…' > .gk-ci-token" >&2
  echo "  in CI: Repository-Secret GK_CI_TOKEN anlegen." >&2
  exit 2
fi

GK_TOKEN="$(trim "$TOKEN_RAW")"

# Datei da, aber leer: das ist etwas ANDERES als "nicht angelegt" und bekommt
# deshalb eine eigene Meldung. Sonst sucht man an der falschen Stelle.
if [ -z "$GK_TOKEN" ]; then
  echo "Token aus $TOKEN_SRC ist leer (bzw. nur Leerraum) — das ist etwas anderes als 'nicht angelegt'." >&2
  exit 2
fi

# Formpruefung, und NUR die: das Praefix. Der haeufigste reale Fehlgriff ist ein
# mitkopiertes 'Bearer ' aus einem curl-Aufruf — der Request liefe dann in den
# OAuth-Zweig und lieferte 401, und die Diagnose zeigte auf den Server statt auf
# die Datei. Vgl. AGENTS.md §15, das fuer n8n GENAU DAS GEGENTEIL vorschreibt.
case "$GK_TOKEN" in
  gk_*) ;;
  *) echo "Token aus $TOKEN_SRC beginnt nicht mit 'gk_'. Steht dort ein 'Bearer '-Prefix?" >&2
     exit 2 ;;
esac

# Herkunft melden — bei einem roten Lauf ist "welche Quelle hat gegriffen" die
# erste Frage. Der Token selbst wird nie ausgegeben, auch nicht teilweise.
#
# Ob getrimmt wurde, wird bei der DATEI ueber die Bytezahl bestimmt, nicht ueber
# den Stringvergleich: `$(cat …)` strippt abschliessende Zeilenumbrueche bereits
# selbst, TOKEN_RAW und der getrimmte Wert waeren also identisch — und genau der
# haeufigste Fall (jemand nimmt `echo` statt `printf`) bliebe stumm. Erst
# aufgefallen, als der Fall getestet wurde.
TRIMMED=0
TOKLEN=$(printf '%s' "$GK_TOKEN" | wc -c | tr -d ' ')
if [ "$TOKEN_SRC" = ".gk-ci-token" ]; then
  FILELEN=$(wc -c < "$TOKEN_FILE" | tr -d ' ')
  [ "$FILELEN" != "$TOKLEN" ] && TRIMMED=1
else
  [ "$TOKEN_RAW" != "$GK_TOKEN" ] && TRIMMED=1
fi

if [ "$TRIMMED" -eq 1 ]; then
  printf 'Token aus: %s (Leerraum entfernt — beim Anlegen printf statt echo benutzen)\n' "$TOKEN_SRC"
else
  printf 'Token aus: %s\n' "$TOKEN_SRC"
fi

command -v jq   >/dev/null || { echo "jq fehlt"   >&2; exit 2; }
command -v curl >/dev/null || { echo "curl fehlt" >&2; exit 2; }

PASS=0; FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
ko(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
sec(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Endpoint aus der server-card lesen statt hardcoden: MCP_ENDPOINT ist laut
# AGENTS.md §7 Single Source of Truth in index.js und fällt in die Card.
# exit 3, NICHT 2: hier ist nicht die Umgebung des Aufrufers kaputt, sondern das
# Ziel nicht benutzbar. Der erste Satz muss den Unterschied nennen — wer im
# GitHub-UI nur "rot" sieht, soll nicht am Secret suchen.
curl -sf -m 20 "$BASE/.well-known/mcp/server-card.json" -o "$TMP/card.json" \
  || { echo "ZIEL NICHT BENUTZBAR (nicht das Token): server-card.json nicht erreichbar unter $BASE." >&2
       echo "Meist läuft der Workers Build für diesen Commit noch. Über den Token ist damit nichts gesagt." >&2
       exit 3; }
EP=$(jq -r '.transport.endpoint' "$TMP/card.json")
[ -n "$EP" ] && [ "$EP" != "null" ] \
  || { echo "ZIEL NICHT BENUTZBAR (nicht das Token): transport.endpoint fehlt in der server-card unter $BASE." >&2
       exit 3; }

# $1 = JSON-Body, $2 = Zieldatei, $3 = "auth" für authentifiziert (sonst ohne).
post(){
  if [ "${3:-}" = "auth" ]; then
    curl -s -m 30 -X POST "$BASE$EP" \
      -H 'content-type: application/json' \
      -H "authorization: Bearer $GK_TOKEN" \
      -d "$1" -o "$2"
  else
    curl -s -m 30 -X POST "$BASE$EP" \
      -H 'content-type: application/json' \
      -d "$1" -o "$2"
  fi
}

# =============================================================================
sec "A · Rollenfilterung greift (Kollisions-Assertion)"
# =============================================================================
# DER TRAGENDE TEST. tools/list ist eine PUBLIC-Methode: ohne gültigen Bearer
# fällt der Request auf den VOLLEN Katalog durch, statt 401 zu liefern. Genau das
# macht die Assertion hier belastbar — ein fehlendes oder nicht akzeptiertes
# Token erzeugt keinen LEEREN Wert, sondern einen FALSCHEN (die volle Liste), und
# die Teilmengen-Prüfung schlägt fehl. Es gibt hier keine leere Menge, über der
# "keine Verstöße" trivial wahr wäre (§18a Fall a).
#
# NICHT WEGKÜRZEN: diese eine Prüfung fängt drei Fehler auf einmal — ungültiges
# Token, abgelaufenes Token UND ein versehentlich hinterlegtes Admin-Token. Der
# dritte Fall macht die Betriebsregel "das CI-Token muss gk_view_ sein"
# maschinell erzwungen statt bloß dokumentiert.
#
# Bewusst Oberfläche gegen Oberfläche, KEINE Kopplung an den Checkout: keine
# erwartete Tool-Anzahl, die bei jedem neuen Tool nachgezogen werden müsste.
LIST='{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
post "$LIST" "$TMP/anon.json"
post "$LIST" "$TMP/auth.json" auth

N_ANON=$(jq -r '[.result.tools[]?.name] | length' "$TMP/anon.json" 2>/dev/null || echo 0)
N_AUTH=$(jq -r '[.result.tools[]?.name] | length' "$TMP/auth.json" 2>/dev/null || echo 0)

if [ "$N_ANON" -gt 0 ] && [ "$N_AUTH" -gt 0 ]; then
  ok "beide Kataloge nicht leer (anon $N_ANON, auth $N_AUTH)"

  if [ "$N_AUTH" -lt "$N_ANON" ]; then
    ok "authentifizierter Katalog ist kleiner ($N_AUTH < $N_ANON) — Token wurde angewendet"
  else
    ko "authentifizierter Katalog NICHT kleiner ($N_AUTH >= $N_ANON) — Token nicht angekommen oder nicht heruntergestuft; siehe Kopf dieser Datei"
  fi

  # Echte Teilmenge: jeder authentifizierte Name muss auch anonym vorkommen.
  EXTRA=$(jq -rn \
    --slurpfile a "$TMP/anon.json" --slurpfile b "$TMP/auth.json" \
    '($a[0].result.tools // [] | map(.name)) as $A
     | ($b[0].result.tools // [] | map(.name))
     | map(select(. as $x | $A | index($x) | not)) | join(", ")')
  if [ -z "$EXTRA" ]; then
    ok "authentifizierte Namen sind Teilmenge der anonymen"
  else
    ko "authentifiziert sichtbar, anonym nicht: $EXTRA"
  fi
else
  ko "Katalog leer (anon $N_ANON, auth $N_AUTH) — tools/list nicht auswertbar"
fi

# Punktproben statt Zahlen: ein admin-only Tool MUSS fehlen, ein view-Tool MUSS da
# sein. Fängt den Fall, dass zwar gefiltert wurde, aber auf der falschen Rolle.
has(){ jq -e --arg n "$1" '[.result.tools[]? | select(.name==$n)] | length == 1' "$2" >/dev/null 2>&1; }

if has clearMemories "$TMP/auth.json"; then
  ko "clearMemories ist sichtbar — das ist admin-only, der Token ist zu mächtig"
else
  ok "clearMemories (admin-only) ist nicht sichtbar"
fi

if has getSeoReport "$TMP/auth.json"; then
  ok "getSeoReport (view-sichtbar) ist vorhanden"
else
  ko "getSeoReport fehlt — Rolle niedriger als erwartet oder Tool entfernt"
fi

# =============================================================================
sec "B · Auth-Positivfall (gk_-Pfad akzeptiert den Token)"
# =============================================================================
# Bis #9 war das unmöglich: ein rohes gk_-Token als Bearer wurde abgelehnt.
# Geprüft wird die Abwesenheit eines Fehlers und die Existenz des Feldes —
# NICHT count > 0. Ein leerer Workspace ist ein gültiges Ergebnis.
post '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"countMemories","arguments":{}}}' \
     "$TMP/count.json" auth

ERR=$(jq -r '.error.message // ""' "$TMP/count.json")
if [ -n "$ERR" ]; then
  ko "countMemories authentifiziert abgelehnt: $ERR"
else
  CNT=$(jq -r '.result.content[0].text // "" | fromjson? | .count // "FEHLT"' "$TMP/count.json")
  case "$CNT" in
    ''|*[!0-9]*) ko "countMemories lieferte kein numerisches count (bekommen: '$CNT')" ;;
    *)           ok "countMemories authentifiziert: count ist numerisch" ;;
  esac
fi

# =============================================================================
sec "C · Dokumentierter Beispielwert funktioniert (Regression #4)"
# =============================================================================
# Der Slug-Bug: die domain-Description nannte 'growthkit.tools' (mit Punkt), der
# echte Slug trägt Bindestriche. Ein Aufruf mit dem dokumentierten Wert lieferte
# {} — still, ohne Fehler.
#
# report-tools.sh prüft das FORMAT der Beispiele. Hier wird geprüft, ob sie
# FUNKTIONIEREN: der Wert wird aus der Live-Antwort gelesen und als Eingabe
# benutzt. Ein falsches Beispiel wird damit rot, ohne dass der erwartete Wert
# irgendwo im Test steht.
#
# Bewusst WEICH: >= 1 Domain, nicht "genau diese zwei". Sonst hängt die CI an der
# Datenlage des Workspace, und das Löschen einer Report-Domain würde einen roten
# Build erzeugen, ohne dass sich Code geändert hat.
EX=$(jq -r '.result.tools[]? | select(.name=="getSeoReport")
            | .inputSchema.properties.domain.examples[0] // ""' "$TMP/auth.json")

if [ -z "$EX" ]; then
  ko "getSeoReport hat kein domain.examples[0] — Regression nicht prüfbar"
else
  post "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"getSeoReport\",\"arguments\":{\"domain\":\"$EX\",\"weeks\":1}}}" \
       "$TMP/seo.json" auth

  SEO_ERR=$(jq -r '.error.message // ""' "$TMP/seo.json")
  if [ -n "$SEO_ERR" ]; then
    ko "getSeoReport('$EX') abgelehnt: $SEO_ERR"
  else
    NDOM=$(jq -r '.result.content[0].text // "" | fromjson? | .domains // {} | keys | length' "$TMP/seo.json")
    case "$NDOM" in
      ''|*[!0-9]*) ko "getSeoReport('$EX') lieferte keine auswertbaren domains" ;;
      0)           ko "getSeoReport('$EX') lieferte {} — der dokumentierte Beispielwert trifft nichts (genau der Bug aus #4)" ;;
      *)           ok "getSeoReport('$EX') liefert $NDOM Domain(s) — Beispielwert funktioniert" ;;
    esac
  fi
fi

printf '\n\033[1mErgebnis: %d grün, %d rot\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
