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
  # ZWEI GRÜNDE für diese Prüfung, und sie sind verschieden. Beide gehören hierher.
  #
  # (1) Dateisystem vs. git. Dieses Repo hat core.fileMode=false, ein `chmod +x`
  #     ist für git also unsichtbar. Ein neues Testskript landet dann als 100644,
  #     und der CI-Step `./tests/x.sh` scheitert mit "Permission denied" — so
  #     geschehen bei tests/report-tools.sh (#3) und davor schon bei
  #     scripts/probe.sh, das dafür einen eigenen Commit brauchte.
  #
  # (2) Index vs. Commit (§18a j, zurückportiert aus growthkit-website 24.08.2026).
  #     `git add --chmod=+x` setzt den Modus im INDEX. Die pfadbegrenzte Form
  #     `git commit -- <pfad>` liest jedoch den ARBEITSBAUM und verwirft ihn dabei —
  #     mit core.fileMode=false ist der Arbeitsbaum-Modus bedeutungslos, also landet
  #     100644 im Commit, während der Index 100755 zeigt. Eine Prüfung, die nur
  #     `ls-files` liest, ist dabei GRÜN. Ausgeliefert wird aber der Commit.
  #     Beleg: am 21.08.2026 in growthkit-website an allen sechs Skripten passiert.
  #
  # Deshalb BEIDE Quellen, nicht eine statt der anderen — und ihr Auseinanderlaufen
  # ist selbst ein Befund, kein Nebeneffekt.
  #
  # -F'\t': `ls-files -s` trennt den Pfad mit TAB ab. Ein Split auf Leerzeichen
  # würde bei Pfaden mit Leerzeichen den falschen Namen melden. `ls-tree` ebenso.
  # ⚠️ NICHT NUR *.sh. Seit 28.08.2026 auch alles unter .githooks/.
  # .githooks/pre-commit ist ein bash-Skript OHNE ENDUNG — git verlangt genau
  # dort das Exec-Bit, sonst fuehrt es den Hook stillschweigend nicht aus. Das
  # ist die schlimmste Variante: kein Fehler, keine Meldung, nur ein
  # Sicherheitsnetz, das nicht mehr da ist. Ein Muster auf '\.sh$' haette ihn
  # nie gesehen.
  EXEC_PATHSPEC=('*.sh' '.githooks/*')
  EXEC_RE='\.sh$|(^| )\.githooks/'
  modes_index(){ g ls-files -s -- "${EXEC_PATHSPEC[@]}" | awk -F'\t' '{ split($1, m, " "); print $2 "\t" m[1] }' | sort; }
  modes_head(){  g ls-tree -r HEAD | awk -F'\t' -v re="$EXEC_RE" '$2 ~ re { split($1, m, " "); print $2 "\t" m[1] }' | sort; }

  IDX=$(modes_index); HEADM=$(modes_head)
  IDX_N=$(printf '%s\n' "$IDX"   | grep -c . || true)
  HD_N=$(printf '%s\n'  "$HEADM" | grep -c . || true)

  # Nicht-Leer-Guard auf BEIDEN Listen (§18a a).
  if [ "${IDX_N:-0}" -eq 0 ] || [ "${HD_N:-0}" -eq 0 ]; then
    ko "Keine Skripte geparst (Index=$IDX_N, HEAD=$HD_N) — die Exec-Bit-Prüfungen liefen leer-wahr durch (§18a a)"
  else
    # (A) Der COMMIT ist die maßgebliche Quelle — das ist, was CI auscheckt.
    NOEXEC_HEAD=$(printf '%s\n' "$HEADM" | awk -F'\t' '$2 != "100755" { print $1 " (" $2 ")" }' | tr '\n' ' ')
    if [ -z "$NOEXEC_HEAD" ]; then
      ok "Exec-Bit: alle $HD_N Skripte (*.sh + .githooks/*) in HEAD sind 100755"
    else
      ko "Shell-Skript ohne Exec-Bit im COMMIT: $NOEXEC_HEAD — CI ruft sie direkt auf (§18a j)"
    fi

    # (B) Der Index fängt dieselbe Regression schon vor dem Commit.
    NOEXEC_IDX=$(printf '%s\n' "$IDX" | awk -F'\t' '$2 != "100755" { print $1 " (" $2 ")" }' | tr '\n' ' ')
    if [ -z "$NOEXEC_IDX" ]; then
      ok "Exec-Bit: alle $IDX_N Skripte (*.sh + .githooks/*) im Index sind 100755"
    else
      ko "Shell-Skript ohne Exec-Bit im Index: $NOEXEC_IDX — mit 'git add --chmod=+x' nachziehen"
    fi

    # (C) Laufen die beiden auseinander, ist GENAU DAS der Befund aus §18a (j).
    if [ "$IDX" = "$HEADM" ]; then
      ok "Index und HEAD stimmen für alle $HD_N *.sh überein"
    else
      ko "Index und HEAD laufen auseinander (§18a j) — der Index sagt etwas anderes als der Commit:"
      diff <(printf '%s\n' "$IDX") <(printf '%s\n' "$HEADM") | sed 's/^/      /'
    fi
  fi

  # --- Symlink-Modus ----------------------------------------------------------
  # CLAUDE.md ist ein Symlink auf AGENTS.md (Modus 120000). §18a (j) nennt ihn
  # ausdrücklich: dieselbe Metadaten-Frage wie beim Exec-Bit, derselbe Weg führt
  # daran vorbei. Ohne 120000 im COMMIT wäre es eine Textdatei mit dem Inhalt
  # "AGENTS.md" — und die beiden Guide-Dateien driften wieder auseinander, wogegen
  # der Symlink überhaupt angelegt wurde.
  SL_HEAD=$(g ls-tree HEAD -- CLAUDE.md | awk '{print $1}')
  SL_IDX=$(g ls-files -s -- CLAUDE.md | awk '{print $1}')
  if [ -z "$SL_HEAD" ] || [ -z "$SL_IDX" ]; then
    ko "CLAUDE.md nicht in HEAD oder Index gefunden (HEAD='$SL_HEAD', Index='$SL_IDX') — Symlink-Prüfung liefe leer-wahr durch (§18a c)"
  elif [ "$SL_HEAD" = "120000" ] && [ "$SL_IDX" = "120000" ]; then
    ok "CLAUDE.md ist in HEAD und Index ein Symlink (120000)"
  else
    ko "CLAUDE.md ist kein Symlink: HEAD=$SL_HEAD, Index=$SL_IDX — erwartet 120000 in beiden"
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
  # .gk-ci-token: lokaler gk_view_-Token fuer tests/authed-smoke.sh. Steht hier,
  # BEVOR die Datei existiert — check-ignore --no-index prueft die Regel, nicht die
  # Existenz. Die Ignore-Zeile und diese Assertion gehoeren in denselben Commit:
  # ein Fenster, in dem die Regel ungeschuetzt ist, waere genau die Regression,
  # gegen die die Positivliste da ist.
  MUST_IGNORE=".wrangler/state node_modules/pkg/index.js .dev.vars .env key.pem specs/x.md scratchpad/x .gk-ci-token"
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
  # ⚠️ `.gk-ci-token` STEHT SEIT 28.08.2026 MIT IN DIESEM MUSTER, und zwar
  # nicht der Vollstaendigkeit halber. `.gitleaks.toml` nimmt diesen Pfad
  # ausdruecklich von der Allowlist-Seite aus, damit der lokale `--no-git`-Lauf
  # nicht dauerhaft rot ist. Damit ist gitleaks fuer die Datei BLIND — auch
  # dann, wenn jemand sie trackt. Vorher fing sie hier nichts: das Muster traf
  # `.pem`, `.env`, `dev.vars` und `.key`, aber nicht diesen Namen, und
  # MUST_IGNORE weiter oben prueft nur, dass die Ignore-REGEL existiert — eine
  # bereits getrackte Datei bleibt getrackt, egal was in .gitignore steht.
  # Es gab also einen Zustand, in dem beide Verfahren gruen sind und der echte
  # Token im Repo liegt.
  #
  # In supabase und growthkit-website tritt der Fall nicht auf, weil deren
  # SECRET_RE die dort ausgenommene Datei ohnehin trifft (`(^|/)\.env`). Die
  # Allowlist von dort zu uebernehmen, OHNE hier nachzumessen, haette genau
  # dieses Loch erzeugt.
  TRACKED_SECRETS=$(g ls-files | grep -E '\.pem$|(^|/)\.env|dev\.vars|\.key$|(^|/)\.gk-ci-token$' | tr '\n' ' ')
  if [ -z "$TRACKED_SECRETS" ]; then
    ok "Keine getrackte Datei sieht nach Secret aus"
  else
    ko "GETRACKTES SECRET im öffentlichen Repo: $TRACKED_SECRETS"
  fi
fi

# --- Migrationsmarker · MCP-Revision 2026-07-28 ------------------------------
# WAS DAS IST. Ein SCHULDSCHEIN-artiger Befund über den heutigen Code, festgehalten
# am 29.08.2026 aus einer Erhebung zur MCP-Revision 2026-07-28. Er ersetzt eine
# Spec-Datei: was hier steht, ist mechanisch nachprüfbar und wird rot, sobald es
# nicht mehr stimmt — eine Spec verrottet still.
#
# ⚠️ WARUM NICHT NUR EINE LISTE DER FEHLENDEN METHODEN. Die Vorbilder in
# `supabase` (Marker) und `growthkit-website` (Werkzeug-Schuldschein) tragen,
# weil sie ZWEI im Repo abgeleitete Mengen gegeneinander halten und in BEIDE
# Richtungen rot werden. Eine reine Fehlt-Liste hat diese zweite Richtung nicht:
# „gebaut, aber noch gelistet" ist prüfbar, „von der Revision gefordert und nie
# gelistet" ist es nicht — dafür gäbe es im Repo keine Quelle. Deshalb steht hier
# je Eintrag ein ERWARTETER ZUSTAND (absent/present); dann sind beide Richtungen
# Funktionen des Checkouts und beide werden rot.
#
# ⚠️ WAS DIESE LISTE NICHT KANN, ausdrücklich: sie prüft nicht ihre eigene
# VOLLSTÄNDIGKEIT gegen die Spec. Fordert 2026-07-28 etwas, das hier nie stand,
# bleibt sie grün und ist unvollständig (§18a k — zu kleine Grundmenge). Das ist
# die Grenze des Verfahrens, nicht ein Mangel dieser Fassung. Der Stand, gegen
# den gemessen wurde, ist der 29.08.2026.
#
# ⚠️ DIE LISTE SOLL SCHRUMPFEN. Jeder absent-Eintrag ist eine offene Migration;
# wer ihn baut, streicht ihn hier. Ein present-Eintrag verschwindet, wenn die
# Revision das Feature streicht und der Code nachzieht. Sie darf NIE WACHSEN,
# ohne dass jemand eine neue Erhebung dazuschreibt.
#
# Zielrevision 2026-07-28 (veröffentlicht 28.07.2026, Mindestfrist für
# Abkündigungen zwölf Monate). Der Server spricht 2025-11-25 — die Konstante ist
# oben in §11 gegen den ext-apps-Wert abgesichert und in probe.sh Sektion I gegen
# die servierte initialize-Antwort. Beides bleibt grün, wenn jemand nur die
# Konstante bumpt: KEIN Test prüft, ob der Server die angesagte Revision auch
# implementiert. Genau diese Lücke ist der Grund, aus dem die Liste hier steht.
#
# Format je Zeile:  <grep-Muster>|<Zustand>|<Bedeutung für die Migration>
MIGRATION_MARKERS="
server/discover|absent|RPC ist in 2026-07-28 Pflicht; liefert supportedVersions/capabilities/serverInfo
elicitation/create|absent|Server->Client-Request; solange keiner existiert, entfaellt MRTR
sampling/createMessage|absent|dito
roots/list|absent|dito
[Mm]cp-[Ss]ession-[Ii]d|absent|kein Transport-Session-Zustand; Zustandslosigkeit kostet daher nichts
params\.protocolVersion|absent|der Server verhandelt nicht, er nennt seine Version unbedingt
method === \"ping\"|present|in 2026-07-28 gestrichen, hier noch vorhanden
payload\.session_id = args\.session_id|present|Working Memory haengt an einem Tool-Argument, nicht am Transport
"

# ⚠️ GEGENSTAND IST AUSSCHLIESSLICH index.js ($SRC), NICHT das Repo. Diese Datei
# enthaelt jedes Muster oben im Klartext; ein repo-weiter grep zaehlte seinen
# EIGENEN Text mit und meldete jeden absent-Eintrag als "vorhanden". Die
# Einschraenkung auf eine Datei ist deshalb tragend, nicht kosmetisch — sie ist
# eigens falsifiziert worden.
MM_LINES=$(printf '%s\n' "$MIGRATION_MARKERS" | grep -c '|' || true)
MM_ABS=$(printf '%s\n' "$MIGRATION_MARKERS" | grep -c '|absent|' || true)
MM_PRS=$(printf '%s\n' "$MIGRATION_MARKERS" | grep -c '|present|' || true)

# Nicht-Leer-Guard auf der Liste UND auf beiden Richtungen (§18a a). Eine leere
# Liste bestuende jede Pruefung; eine Richtung ohne Eintrag waere ein unbemerkt
# toter Zweig — dieselbe Einsicht wie beim Werkzeug-Schuldschein in
# growthkit-website ("ein Eintrag ist nicht null").
if [ "${MM_LINES:-0}" -eq 0 ]; then
  ko "MIGRATION_MARKERS ist leer — die Schleife liefe null Mal und waere trivial gruen (§18a a)"
elif [ "${MM_ABS:-0}" -eq 0 ] || [ "${MM_PRS:-0}" -eq 0 ]; then
  ko "MIGRATION_MARKERS hat keine Eintraege fuer eine der beiden Richtungen (absent=$MM_ABS, present=$MM_PRS) — ein Zweig waere unbemerkt tot (§18a a)"
else
  MM_BAD=""
  MM_MALFORMED=0
  MM_CHECKED=0
  while IFS='|' read -r PAT WANT WHY; do
    [ -z "$PAT" ] && continue
    case "$WANT" in
      absent|present) ;;
      *) MM_MALFORMED=$((MM_MALFORMED+1)); continue ;;
    esac
    MM_CHECKED=$((MM_CHECKED+1))
    if grep -qE -- "$PAT" "$SRC"; then IST="present"; else IST="absent"; fi
    [ "$IST" = "$WANT" ] || MM_BAD="$MM_BAD $PAT(erwartet=$WANT,ist=$IST)"
  done <<EOF
$(printf '%s\n' "$MIGRATION_MARKERS" | grep '|')
EOF

  if [ "$MM_MALFORMED" -gt 0 ]; then
    ko "MIGRATION_MARKERS: $MM_MALFORMED Zeile(n) ohne gueltigen Zustand — stillschweigend uebersprungen waeren sie ungeprueft (§18a c)"
  elif [ "$MM_CHECKED" -ne "$MM_LINES" ]; then
    ko "MIGRATION_MARKERS: $MM_CHECKED von $MM_LINES Zeilen geprueft — die Schleife hat Eintraege verloren (§18a k)"
  elif [ -z "$MM_BAD" ]; then
    ok "Migrationsmarker 2026-07-28: alle $MM_CHECKED Eintraege stimmen ($MM_ABS fehlen noch, $MM_PRS vorhanden)"
  else
    ko "Migrationsmarker 2026-07-28 veraltet:$MM_BAD — gebaut oder entfernt? Dann den Eintrag hier streichen (die Liste schrumpft, das ist der Zweck)"
  fi
fi

# --- Ungedeckte Assertions · Schuldschein ------------------------------------
# WAS DAS IST. Eine Assertion ohne roten Lauf gilt als nicht verifiziert (§18a).
# Nicht jede Assertion in diesem Repo hat einen — die Erhebung vom 30.08.2026 hat
# sechzehn Gruppen gefunden, deren Rot-Beleg sich in keinem Commit-Body nachweisen
# laesst. Jede traegt am Ort einen Marker; die Liste unten deklariert sie.
#
# ⚠️ LISTE STATT ZAHL, und zwar aus einem Grund. Eine Zahl sagt, WIE VIELE offen
# sind; eine Liste sagt, WELCHE. Nur die Liste faengt beide Fehlerrichtungen: einen
# neuen, nicht deklarierten Marker UND einen deklarierten Eintrag, dessen Marker
# verschwunden ist. Bei einer Obergrenze waere das Zweite unsichtbar — man
# falsifiziert, entfernt den Marker, zieht die Grenze nicht nach, und die Grenze
# bedeutet ab da nichts mehr. Sie waechst nicht, sie VERROTTET, und das ist
# schlechter, weil es nicht auffaellt.
#
# Die Liste darf SCHRUMPFEN und nie wachsen. Wer eine NEUE Assertion schreibt,
# falsifiziert sie und traegt sie hier gar nicht erst ein.
#
# ⚠️ KEINE ZWEITE KATEGORIE "LOKAL NICHT FALSIFIZIERBAR", und das ist gemessen,
# nicht weggelassen. Der Verdacht lag nahe, dass die auth-paths-Eintraege auf eine
# deployte Flaeche warten statt auf Arbeit — ein Zustand, der sich anders verhaelt,
# weil niemand nachlaessig war. Am 30.08.2026 nachgepruft: `tests/auth-paths.sh`
# laeuft gegen `wrangler dev` mit 19 gruen / 0 rot. Es ist secret-frei, genau wie
# sein Kopf es sagt. Was eine deployte Flaeche braucht, ist `authed-smoke.sh` —
# und dessen Assertions SIND falsifiziert, nur gegen Production. Die zweite
# Kategorie haette also null Mitglieder und waere ein unbemerkt toter Zweig
# (§18a a). Sie kommt, wenn es den ersten Fall gibt, und nicht vorher.
UNPROVEN_DECLARED="auth-paths-a-401-codes auth-paths-a-fehlermeldungen auth-paths-b-toolslist-offen auth-paths-b-initialize-offen auth-paths-b-toolslist-ungueltiger-token report-tools-katalog-praesenz report-tools-schema-form report-tools-domain-beispiele report-tools-description-laenge report-tools-auth-grenze probe-b-card-felder probe-b-serverjson-sync probe-c-oauth-triplet probe-d-toolslist-offen probe-e-app-private probe-f-tool-katalog"

# ⚠️ DIE SUCHE DARF NICHT AUF DEN EIGENEN TEXT HEREINFALLEN. Die Marker liegen in
# Shell-Dateien — also auch in DIESER. Ein literales Muster im Code traefe sich
# selbst und meldete einen Marker, den es als Assertion nicht gibt. Deshalb wird
# der Token zur LAUFZEIT zusammengesetzt und steht nirgends am Stueck in einer
# gescannten Codezeile.
#
# Weil das eine Behauptung ueber das eigene Werkzeug ist, wird sie GEPRUEFT statt
# geglaubt: Richtung 1 unten verlangt, dass JEDER gefundene Marker eine deklarierte
# ID traegt. Ein Selbsttreffer aus diesem Kommentar haette keine und machte die
# Sektion sofort rot.
UP_TOK="UNPROV""EN"

UP_FILES=$(g ls-files 'tests/*.sh' 'scripts/*.sh' '.githooks/*' '.claude/hooks/*.sh' | tr '\n' ' ')
if [ -z "$(printf '%s' "$UP_FILES" | tr -d ' ')" ]; then
  ko "Keine Dateien fuer den Marker-Scan gefunden — die Sektion liefe leer-wahr durch (§18a a)"
else
  # shellcheck disable=SC2086
  FOUND=$(cd "$REPO_ROOT" && grep -hoE "#[[:space:]]*${UP_TOK}\[[a-z0-9-]+\]" $UP_FILES 2>/dev/null \
          | sed -E "s/.*\[([a-z0-9-]+)\].*/\1/" | sort -u)
  DECL=$(printf '%s\n' $UNPROVEN_DECLARED | grep -v '^$' | sort -u)
  FOUND_N=$(printf '%s\n' "$FOUND" | grep -c . || true)
  DECL_N=$(printf '%s\n' "$DECL"  | grep -c . || true)

  if [ "${DECL_N:-0}" -eq 0 ] && [ "${FOUND_N:-0}" -eq 0 ]; then
    ok "Schuldschein getilgt: keine Assertion mehr ohne Rot-Beleg — dieser Abschnitt darf entfallen"
  elif [ "${FOUND_N:-0}" -eq 0 ]; then
    # Der gefaehrlichste Fall: ein kaputtes Suchmuster findet nichts, und ohne
    # diesen Zweig meldete die Sektion dann "alles erledigt".
    ko "Kein einziger Marker gefunden, aber $DECL_N deklariert — Suchmuster kaputt oder Marker-Format geaendert (§18a a/c)"
  else
    NUR_GEFUNDEN=$(comm -23 <(printf '%s\n' "$FOUND") <(printf '%s\n' "$DECL") | tr '\n' ' ')
    NUR_DEKLARIERT=$(comm -13 <(printf '%s\n' "$FOUND") <(printf '%s\n' "$DECL") | tr '\n' ' ')

    # Richtung 1: ein Marker, den niemand deklariert hat. Hier landet auch ein
    # Selbsttreffer aus dem Kommentartext oben — mit einer ID, die es nicht gibt.
    if [ -z "$NUR_GEFUNDEN" ]; then
      ok "Schuldschein: alle $FOUND_N gefundenen Marker sind deklariert"
    else
      ko "Marker ohne Eintrag in UNPROVEN_DECLARED:$NUR_GEFUNDEN — eintragen, oder die Assertion falsifizieren und den Marker entfernen. Die Liste darf NICHT wachsen."
    fi

    # Richtung 2: ein Eintrag, dessen Marker weg ist. Das ist der GUTE Fall —
    # jemand hat falsifiziert. Er muss trotzdem rot sein, sonst verrottet die Liste.
    if [ -z "$NUR_DEKLARIERT" ]; then
      ok "Schuldschein aktuell: alle $DECL_N Eintraege tragen noch ihren Marker"
    else
      ko "UNPROVEN_DECLARED nennt IDs ohne Marker:$NUR_DEKLARIERT — falsifiziert? Dann hier streichen (die Liste schrumpft, das ist der Zweck)"
    fi
  fi
fi

[ "$NESTED" -eq 1 ] || printf '\n\033[1m%s\033[0m\n' "Ergebnis: $PASS grün, $FAIL rot"
[ "$FAIL" -eq 0 ] || exit 1
