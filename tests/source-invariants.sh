#!/usr/bin/env bash
# GrowthKit MCP — Quell-Invarianten
#
# Prüft die Invarianten, die AUSSCHLIESSLICH aus dem Checkout folgen — ohne HTTP,
# ohne laufende Instanz, ohne Workers Build. Drei Gruppen: §11 (Protokoll-Versionen
# in index.js), die Rollen-Maps, und die Repo-Hygiene (Exec-Bit, Ignore-Regeln,
# getrackte Secrets). Der frühere Titel sagte „aus index.js" und war seit den
# letzten beiden zu eng.
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

# --- Rollen-Maps · toolRoleMap ≡ toolPermissions ------------------------------
# Zwei von Hand gepflegte Kopien derselben Rollenzuordnung: toolRoleMap filtert
# tools/list, toolPermissions bewacht tools/call. Driften sie auseinander, taucht
# ein Tool im Katalog auf, das der Guard nicht kennt — und ein fehlender
# toolPermissions-Eintrag faellt durch (`toolPermissions[name] && …` ist dann
# falsch, es wird gar nicht geprueft). Bis heute bewachte das nichts.
#
# BEWUSST OHNE absolute Zahlen: "68 Tools" muesste bei jedem neuen Tool
# nachgezogen werden. Geprueft werden Beziehungen, die nicht driften.
#
# ZWEI PARSE-FALLEN, beide empirisch gefunden, beide erzeugen stille Falschaussagen:
#   (1) toolPermissions hat MEHRERE Eintraege pro Zeile. Ein am Zeilenanfang
#       verankertes Muster zaehlt 61 statt 68 -> falscher Drift-Alarm.
#   (2) Beide Bloecke enthalten eine Kommentarzeile mit _meta.ui.visibility:["app"].
#       Ohne Kommentar-Strippen entsteht ein Phantom-Schluessel `visibility`.
# Deshalb: Kommentarzeilen raus, danach unverankert scannen.
#
# Flags in FESTER Reihenfolge statt sortiert — asort() gibt es nur in gawk, und
# auf dem Runner ist awk nicht zwingend gawk.
ROLEMAP_AWK='
BEGIN { f=0 }
$0 ~ ("const " NAME " = \\{") { f=1; next }
f && /^        \};/ { exit }
f {
  line = $0
  if (line ~ /^[[:space:]]*\/\//) next
  while (match(line, /[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*\[[^]]*\]/)) {
    ent  = substr(line, RSTART, RLENGTH)
    line = substr(line, RSTART + RLENGTH)
    k = ent; sub(/:.*/, "", k); gsub(/[[:space:]]/, "", k)
    r = ent; sub(/^[^[]*\[/, "", r); sub(/\]$/, "", r)
    n = gsub(/"/, "\"", r) / 2
    flags = ""
    if (r ~ /"admin"/) flags = flags "a"
    if (r ~ /"team"/)  flags = flags "t"
    if (r ~ /"view"/)  flags = flags "v"
    printf "%s\t%s\t%d\n", k, flags, n
  }
}'
rolemap(){ awk -v NAME="$1" "$ROLEMAP_AWK" "$SRC" | sort; }

RM_N=$(rolemap toolRoleMap     | wc -l | tr -d ' ')
TP_N=$(rolemap toolPermissions | wc -l | tr -d ' ')

# Der §18a-Guard: ohne ihn laufen alle folgenden Pruefungen ueber leeren Listen
# LEER-WAHR durch. Ein umbenannter Block wuerde still gruen bleiben.
if [ "$RM_N" -eq 0 ] || [ "$TP_N" -eq 0 ]; then
  ko "Rollen-Map nicht geparst (toolRoleMap=$RM_N, toolPermissions=$TP_N) — umbenannt oder umformatiert?"
else
  ok "Rollen-Maps geparst (je $RM_N Einträge)"

  if diff <(rolemap toolRoleMap) <(rolemap toolPermissions) >/dev/null 2>&1; then
    ok "toolRoleMap ≡ toolPermissions (Schlüssel und Rollen)"
  else
    ko "toolRoleMap und toolPermissions weichen ab — tools/list und tools/call widersprechen sich:"
    diff <(rolemap toolRoleMap) <(rolemap toolPermissions) | head -20 | sed 's/^/      /'
  fi

  # Unbekannte Rolle: die Flags kennen nur admin/team/view. Taucht eine vierte
  # auf, ist length(flags) kleiner als die Zahl der gequoteten Werte — sonst
  # wuerde sie stillschweigend ignoriert.
  UNKNOWN=$(rolemap toolRoleMap | awk -F'\t' 'length($2) != $3 { print $1 }' | tr '\n' ' ')
  if [ -z "$UNKNOWN" ]; then
    ok "Keine unbekannten Rollen (nur admin/team/view)"
  else
    ko "Unbekannte Rolle in: $UNKNOWN"
  fi

  # view ⊆ team ⊆ admin. Eine Rolle, die etwas darf, was die naechsthoehere nicht
  # darf, ist fast immer ein Tippfehler in einer der beiden Listen.
  VIOL=$(rolemap toolRoleMap | awk -F'\t' '
    $2 ~ /v/ && $2 !~ /t/ { print $1 " (view ohne team)" }
    $2 ~ /t/ && $2 !~ /a/ { print $1 " (team ohne admin)" }' | tr '\n' ' ')
  if [ -z "$VIOL" ]; then
    ok "Rollen-Hierarchie: view ⊆ team ⊆ admin"
  else
    ko "Rollen-Hierarchie verletzt: $VIOL"
  fi
fi

# --- Repo-Hygiene · Exec-Bit, Ignore-Regeln, keine getrackten Secrets ---------
# Zwei Fehlerklassen, die bisher nur auffielen, weil Chris beim Push-Stopp auf den
# Commit-Stack gesehen hat: ein Testskript ohne Exec-Bit (#3) und ein ungeignortes
# .wrangler/ (#4). Beide sind mechanisch prüfbar und gehören deshalb hierher und
# nicht in einen Text, den jemand liest.
#
# WARUM NICHT "keine untracked Build-Artefakte". Das wäre in CI nicht prüfbar:
# nach actions/checkout ist der Arbeitsbaum immer sauber, `git status --porcelain`
# dort also immer leer und die Prüfung immer grün — §18a Fall (a) in genau der
# Datei, die diese Fehlerklasse dokumentiert. Prüfbar ist nur, was eine Funktion
# des COMMITS ist; der Arbeitsbaum-Zustand ist es nicht. Die Invariante, die es
# ist: die Pfade, die ignoriert sein MÜSSEN, sind es auch. `git check-ignore`
# wertet dafür die Regeln aus, auch für Pfade, die gar nicht existieren.
#
# Neue Abhängigkeit: git UND ein Repository. Fehlt eines davon, ist das ein
# FEHLER und kein Grund zum Überspringen — dieselbe Regel wie beim fehlenden
# index.js oben (§18a c).
if ! command -v git >/dev/null 2>&1; then
  ko "git nicht gefunden — Repo-Invarianten nicht prüfbar"
elif ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  ko "kein git-Repository unter $REPO_ROOT — Repo-Invarianten nicht prüfbar"
else
  g(){ git -C "$REPO_ROOT" "$@"; }

  # --- Exec-Bit -------------------------------------------------------------
  # Modes aus dem INDEX, nicht vom Dateisystem: dieses Repo hat
  # core.fileMode=false, ein `chmod +x` ist für git also unsichtbar. Ein neues
  # Testskript landet dann als 100644, und der CI-Step `./tests/x.sh` scheitert
  # mit "Permission denied" — so geschehen bei tests/report-tools.sh (#3) und
  # davor schon bei scripts/probe.sh, das dafür einen eigenen Commit brauchte.
  SH_N=$(g ls-files -s -- '*.sh' | wc -l | tr -d ' ')
  if [ "$SH_N" -eq 0 ]; then
    ko "Kein *.sh im Index gefunden — die Exec-Bit-Prüfung liefe leer-wahr durch"
  else
    # -F'\t': `ls-files -s` trennt den Pfad mit TAB ab. Ein Split auf Leerzeichen
    # würde bei Pfaden mit Leerzeichen den falschen Namen melden.
    NOEXEC=$(g ls-files -s -- '*.sh' \
      | awk -F'\t' '{ split($1, m, " "); if (m[1] != "100755") print $2 " (" m[1] ")" }' \
      | tr '\n' ' ')
    if [ -z "$NOEXEC" ]; then
      ok "Exec-Bit: alle $SH_N *.sh im Index sind 100755"
    else
      ko "Shell-Skript ohne Exec-Bit im Index: $NOEXEC — CI ruft sie direkt auf"
    fi
  fi

  # --- Ignore-Regeln, BEIDE Richtungen --------------------------------------
  # Die Negativkontrolle ist tragend, nicht Zierde: stünde ein `*` in
  # .gitignore, wären alle Positivprüfungen grün und die Assertion prüfte nur
  # noch, DASS etwas ignoriert wird — nicht, dass das Richtige ignoriert wird.
  # (Invertiert-leer-wahr; verwandt mit §18a a, aber eine eigene Variante.)
  #
  # --no-index IST TRAGEND, nicht kosmetisch. Ohne das Flag wertet check-ignore
  # den INDEX mit aus und meldet jede GETRACKTE Datei als "nicht ignoriert",
  # unabhängig von den Regeln. Die Negativkontrolle wäre damit blind für genau
  # den Fall, für den sie da ist: mit `*` in .gitignore blieb sie grün, weil
  # index.js & Co. getrackt sind. Erst --no-index prüft die REGELN. (Beim
  # Falsifizieren aufgefallen; durch Lesen nicht zu sehen.)
  # Der Index-Fall ist damit nicht ungeprüft — er ist die Secret-Prüfung unten.
  MUST_IGNORE=".wrangler/state node_modules/pkg/index.js .dev.vars .env key.pem specs/x.md scratchpad/x"
  MUST_TRACK="index.js AGENTS.md wrangler.toml tests/source-invariants.sh"

  NOT_IGNORED=""
  for p in $MUST_IGNORE; do
    g check-ignore -q --no-index "$p" || NOT_IGNORED="$NOT_IGNORED $p"
  done
  if [ -z "$NOT_IGNORED" ]; then
    ok "Ignore-Regeln greifen für Build-Artefakte, Secrets und Specs"
  else
    ko "MUSS ignoriert sein, ist es aber nicht:$NOT_IGNORED — Repo ist öffentlich"
  fi

  WRONGLY_IGNORED=""
  for p in $MUST_TRACK; do
    g check-ignore -q --no-index "$p" && WRONGLY_IGNORED="$WRONGLY_IGNORED $p"
  done
  if [ -z "$WRONGLY_IGNORED" ]; then
    ok "Negativkontrolle: Kerndateien sind nicht ignoriert"
  else
    ko "Zu breite Ignore-Regel — diese Dateien wären ausgeschlossen:$WRONGLY_IGNORED"
  fi

  # --- Keine getrackten Secrets ---------------------------------------------
  # Die Ignore-Regeln oben sehen diesen Fall NICHT: `git add -f` geht an ihnen
  # vorbei, und einmal getrackt bleibt eine Datei getrackt. Das ist der einzige
  # Weg, auf dem ein Secret in dieses öffentliche Repo käme.
  TRACKED_SECRETS=$(g ls-files | grep -E '\.pem$|(^|/)\.env|dev\.vars|\.key$' | tr '\n' ' ')
  if [ -z "$TRACKED_SECRETS" ]; then
    ok "Keine getrackte Datei sieht nach Secret aus"
  else
    ko "GETRACKTES SECRET im öffentlichen Repo: $TRACKED_SECRETS"
  fi
fi

[ "$NESTED" -eq 1 ] || printf '\n\033[1m%s\033[0m\n' "Ergebnis: $PASS grün, $FAIL rot"
[ "$FAIL" -eq 0 ] || exit 1
