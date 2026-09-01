#!/usr/bin/env bash
# GrowthKit MCP Worker — Testtabelle fuer .githooks/pre-commit (Branch-Haelfte)
#
#   bash tests/pre-commit.sh
#
# Bringt seine Fixtures selbst mit: Wegwerf-Repos unter mktemp, in denen der
# Hook als echter core.hooksPath-Hook haengt und mit echten `git commit`-Aufrufen
# ausgeloest wird. Das echte Repo wird nicht angefasst.
#
# ─────────────────────────────────────────────────────────────────────────────
# WARUM END-TO-END UND NICHT DAS SKRIPT DIREKT.
#
# Der Hook wird von git aufgerufen, und WANN git ihn aufruft, ist genau die
# Frage, an der der Entwurf haengt: fuer einen sauber durchlaufenden
# `git merge --no-ff` ruft git ihn NICHT, fuer die Aufloesung eines Konflikts
# und fuer `--amend` schon. Ein Test, der `.githooks/pre-commit` von Hand
# startet, misst diese Unterscheidung gar nicht — er wuerde jede Meldung
# bestaetigen, auch die aus einem Fall, den git in Wirklichkeit nie erreicht
# (§18a l: Messung am falschen Objekt).
#
# ⚠️ DER PRUEFLING WIRD ABSOLUT ADRESSIERT, und das ist ein Beleg, kein Vorsatz.
# Beim Bauen des Vorgaengers dieser Suite kopierte das Fixture den Hook ueber
# einen RELATIVEN Pfad und wechselte vorher das Verzeichnis. `cp` scheiterte
# still, das Fixture-Repo lief OHNE Hook, und alle Faelle meldeten "durch" —
# es sah aus wie ein Guard, der nichts tut (§18a g). Deshalb steht unten eine
# Assertion, die den Pruefling im Fixture gegen das Original haelt.
#
# ⚠️ BEIDE RICHTUNGEN SIND PFLICHT, und die allow-Tabelle ist die laengere.
# Ein Guard, der nur ablehnt, waere trivial zu bauen und unbrauchbar: er
# blockierte die Konfliktaufloesung auf main, jedes Rebase und jedes Nachsehen
# in einem alten Stand. Nach dem dritten Fehlalarm schaltet ihn jemand ab, und
# dann ist er schlechter als die Regel in AGENTS.md allein.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/.githooks/pre-commit"
GUARD_PUSH="$REPO_ROOT/.claude/hooks/guard-push.sh"
AGENTS="$REPO_ROOT/AGENTS.md"
GITLEAKS_CFG="$REPO_ROOT/.gitleaks.toml"

PASS=0; FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
ko(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
sec(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
ende(){ printf '\n\033[1mErgebnis: %s grün, %s rot\033[0m\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

printf '\n\033[1m%s\033[0m\n' "pre-commit — $HOOK"

[ -f "$HOOK" ]        || { ko "Hook nicht gefunden";                                          ende; exit 1; }
[ -f "$GUARD_PUSH" ]  || { ko "guard-push.sh nicht gefunden — Abschnitt D kann nicht vergleichen"; ende; exit 1; }
[ -f "$GITLEAKS_CFG" ]|| { ko ".gitleaks.toml nicht gefunden — die Fixtures liefen in den Konfig-Abbruch"; ende; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

# ── gitleaks-Stub ────────────────────────────────────────────────────────────
# Das echte gitleaks kostet hier 739-1151 ms je Aufruf (01.09.2026 gemessen)
# und machte diese Suite um ein Vielfaches langsamer. Es wird hier NICHT
# geprueft — Gegenstand ist die BRANCH-Haelfte des Hooks, der Secret-Scan
# haengt am Unit-Job in CI.
#
# ⚠️ Der Stub liegt im PATH und heisst `gitleaks`, statt gitleaks aus dem PATH
# zu NEHMEN. Der Unterschied ist tragend: ohne gitleaks faellt der Hook in
# seinen fail-open-Zweig und ueberspringt den Scan mit einer Warnung — ein
# ANDERER Codepfad als in Produktion (§18a h: eine vorausgesetzte
# Umgebungseigenschaft, die auf einer anderen Maschine etwas anderes bedeutet).
# Mit dem Stub laeuft `command -v gitleaks` erfolgreich und `gitleaks protect`
# wird tatsaechlich aufgerufen — dieselbe Verzweigung, nur schnell.
#
# Und er ist mehr als eine Beschleunigung: er PROTOKOLLIERT jeden Aufruf. Damit
# laesst sich pruefen, dass ein abgelehnter Commit den Scan gar nicht erreicht —
# genau die Reihenfolge, auf der die Laufzeitaussage im Hook-Kopf beruht.
mkdir -p "$FIX/bin"
SCANLOG="$FIX/gitleaks.log"; : > "$SCANLOG"
cat > "$FIX/bin/gitleaks" <<STUB
#!/usr/bin/env bash
echo aufgerufen >> "$SCANLOG"
exit 0
STUB
chmod +x "$FIX/bin/gitleaks"
export PATH="$FIX/bin:$PATH"
command -v gitleaks | grep -q "^$FIX/bin/" \
  && ok "gitleaks-Stub liegt im PATH — der Hook nimmt seinen normalen Zweig, nicht den fail-open" \
  || ko "gitleaks-Stub greift nicht; die Laufzeit- und Reihenfolgeaussagen unten waeren dann falsch"

scans(){ wc -l < "$SCANLOG" | tr -d ' '; }

# Zaehler fuer die Ausgangs-Kontrolle in Abschnitt C. Ein Lauf, in dem NUR
# abgelehnt oder NUR durchgelassen wurde, ist verdaechtig, egal wie viele
# Haken dastehen (§18a a/d).
N_DENY=0; N_ALLOW=0

# ── Fixture: Repo mit Basis-Commit, Hook scharf ───────────────────────────────
# ⚠️ .gitleaks.toml wird mitkopiert. Ohne sie bricht der Hook in seinem
# fail-closed Konfig-Zweig ab (dieses Repo hat einen, das Nachbar-Repo nicht),
# und JEDER allow-Fall waere rot — aus einem Grund, der mit dem Branch-Check
# nichts zu tun hat (§18a g). Abschnitt C fuehrt diesen Zweig absichtlich
# herbei, und nur dort.
mkrepo(){
  local d="$FIX/$1"; mkdir -p "$d"; cd "$d" || return 1
  git init -q -b main .
  git config user.email t@t; git config user.name T
  mkdir -p .githooks
  cp "$HOOK" .githooks/pre-commit
  cp "$GITLEAKS_CFG" .
  git config core.hooksPath .githooks
  echo basis > f.txt
  git add f.txt .gitleaks.toml
  git commit -qm basis --no-verify
}

# Ein Commit, der ABGELEHNT werden muss.
deny(){ # name  beschreibung
  local vorher; vorher=$(git rev-list --count HEAD 2>/dev/null || echo 0)
  if git commit -qm "$1" >/dev/null 2>&1; then
    ko "$2 — Commit lief DURCH"
  else
    local nachher; nachher=$(git rev-list --count HEAD 2>/dev/null || echo 0)
    # ⚠️ Der Rueckgabewert allein genuegt nicht. Geprueft gehoert, dass der
    # Commit auch WIRKLICH nicht geschrieben wurde — ein Hook, der meckert und
    # den Commit trotzdem anlegt, gibt dieselbe 1 zurueck.
    if [ "$vorher" = "$nachher" ]; then
      ok "$2"; N_DENY=$((N_DENY+1))
    else
      ko "$2 — abgelehnt gemeldet, aber der Commit steht trotzdem da"
    fi
  fi
}

# Ein Commit, der DURCHGEHEN muss.
allow(){ # name  beschreibung
  if git commit -qm "$1" >/dev/null 2>&1; then
    ok "$2"; N_ALLOW=$((N_ALLOW+1))
  else
    ko "$2 — Commit wurde ABGELEHNT"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
sec "A · Geschuetzte Branches — der Commit wird verhindert"

mkrepo a1 && {
  # ⚠️ ZUERST: ist der Pruefling der, den wir zu pruefen glauben? Genau hier ist
  # der Vorgaenger dieser Suite gescheitert — ohne diese Zeile belegt die ganze
  # Tabelle nur, dass ein Repo ohne Hook Commits durchlaesst.
  if cmp -s .githooks/pre-commit "$HOOK"; then
    ok "Pruefling im Fixture ist byte-gleich mit $HOOK"
  else
    ko "Pruefling im Fixture weicht vom echten Hook ab — alles darunter misst etwas anderes (§18a g)"
  fi
  echo x >> f.txt; git add f.txt; deny "auf main" "HEAD auf 'main'"
}

mkrepo a2 && {
  git branch -qm master
  echo x >> f.txt; git add f.txt
  deny "auf master" "HEAD auf 'master' — beide Namen, nicht nur main"
}

mkrepo a3 && {
  echo x >> f.txt; git add f.txt
  # --amend auf main ist derselbe Defekt: er schreibt einen neuen Commit auf
  # den geschuetzten Branch. Gemessen: git ruft pre-commit dafuer auf.
  git commit -qm vorbereitung --no-verify
  if git commit -q --amend --no-edit >/dev/null 2>&1; then
    ko "git commit --amend auf 'main' — lief DURCH"
  else
    ok "git commit --amend auf 'main'"; N_DENY=$((N_DENY+1))
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
sec "B · Was ausdruecklich durchgeht"

mkrepo b1 && {
  git switch -qc feature
  echo x >> f.txt; git add f.txt
  allow "auf feature" "HEAD auf einem Feature-Branch"
}

mkrepo b2 && {
  git switch -qc feature
  echo x >> f.txt; git add f.txt; git commit -qm erst --no-verify
  echo y >> f.txt; git add f.txt
  if git commit -q --amend --no-edit >/dev/null 2>&1; then
    ok "git commit --amend auf einem Feature-Branch"; N_ALLOW=$((N_ALLOW+1))
  else
    ko "git commit --amend auf einem Feature-Branch — ABGELEHNT"
  fi
}

mkrepo b3 && {
  # Losgeloester HEAD. Ein Commit hier bewegt 'main' nicht — er haengt frei.
  # ⚠️ Das ist der Fall, den ein naiver Vergleich VERSEHENTLICH durchlaesst:
  # `symbolic-ref` scheitert, die Variable ist leer, der Vergleich mit 'main'
  # schlaegt fehl, und es sieht aus wie eine bestandene Pruefung (§18a c).
  # Hier steht er als ABSICHT, damit ein spaeteres "Aufraeumen" ihn nicht
  # stillschweigend zur Ablehnung macht.
  git checkout -q --detach
  echo x >> f.txt; git add f.txt
  allow "losgeloest" "losgeloester HEAD — bewegt keinen Branch"
}

# ── Laufende Mehrschritt-Vorgaenge, jeder als ECHTER Konflikt ────────────────
# Nicht ueber ein `touch .git/MERGE_HEAD`: das pruefte die Implementierung
# gegen sich selbst, statt gegen das, was git tatsaechlich hinterlegt.
konflikt_aufbauen(){
  git switch -qc andere
  echo andere > f.txt; git add f.txt; git commit -qm andere --no-verify
  git switch -q main
  echo main > f.txt; git add f.txt; git commit -qm main --no-verify
}

mkrepo b4 && {
  konflikt_aufbauen
  git merge -q andere >/dev/null 2>&1
  [ -e "$(git rev-parse --git-dir)/MERGE_HEAD" ] \
    && ok "Fixture: MERGE_HEAD liegt vor (der Vorgang laeuft wirklich)" \
    || ko "Fixture: kein MERGE_HEAD — der Fall darunter misst nichts"
  echo geloest > f.txt; git add f.txt
  allow "merge" "Konfliktaufloesung eines Merge auf 'main'"
}

mkrepo b5 && {
  konflikt_aufbauen
  git cherry-pick andere >/dev/null 2>&1
  [ -e "$(git rev-parse --git-dir)/CHERRY_PICK_HEAD" ] \
    && ok "Fixture: CHERRY_PICK_HEAD liegt vor" \
    || ko "Fixture: kein CHERRY_PICK_HEAD — der Fall darunter misst nichts"
  echo geloest > f.txt; git add f.txt
  allow "cherry-pick" "Konfliktaufloesung eines Cherry-Pick auf 'main'"
}

mkrepo b6 && {
  echo zwei > f.txt; git add f.txt; git commit -qm zwei --no-verify
  ZIEL=$(git rev-parse HEAD)
  echo drei > f.txt; git add f.txt; git commit -qm drei --no-verify
  git revert --no-edit "$ZIEL" >/dev/null 2>&1
  [ -e "$(git rev-parse --git-dir)/REVERT_HEAD" ] \
    && ok "Fixture: REVERT_HEAD liegt vor" \
    || ko "Fixture: kein REVERT_HEAD — der Fall darunter misst nichts"
  echo geloest > f.txt; git add f.txt
  allow "revert" "Konfliktaufloesung eines Revert auf 'main'"
}

mkrepo b7 && {
  # ⚠️ DER REBASE-FALL GEHT DURCH — ABER NICHT UEBER DIE VORGANG-AUSNAHME.
  # Am 01.09.2026 gemessen und nicht angenommen: waehrend eines angehaltenen
  # Rebase ist HEAD LOSGELOEST. `symbolic-ref` liefert leer, der Commit laeuft
  # also schon ueber den Zweig aus b3 durch; die rebase-merge/rebase-apply-
  # Eintraege in VORGANG feuern dabei gar nicht. Sie bleiben als Guertel neben
  # den Hosentraegern stehen — wer sie entfernt, aendert an diesem Fall nichts,
  # und wer den losgeloesten HEAD "aufraeumt", bricht ihn. Genau deshalb steht
  # die Messung hier als Assertion und nicht als Kommentar im Hook (§18a i:
  # ein Kriterium, das den falschen Mechanismus unterstellt, faellt nicht auf).
  git switch -qc thema; echo thema > f.txt; git add f.txt; git commit -qm thema --no-verify
  git switch -q main;   echo mainseite > f.txt; git add f.txt; git commit -qm mainseite --no-verify
  git switch -q thema;  git rebase main >/dev/null 2>&1
  G=$(git rev-parse --git-dir)
  { [ -d "$G/rebase-merge" ] || [ -d "$G/rebase-apply" ]; } \
    && ok "Fixture: ein Rebase laeuft wirklich (rebase-Verzeichnis liegt vor)" \
    || ko "Fixture: kein rebase-Verzeichnis — der Fall darunter misst nichts"
  [ -z "$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" ] \
    && ok "waehrend des Rebase ist HEAD losgeloest — der Fall haengt an b3, nicht an der VORGANG-Ausnahme" \
    || ko "HEAD ist waehrend des Rebase NICHT losgeloest — die Begruendung im Hook stimmt dann nicht mehr"
  echo geloest > f.txt; git add f.txt
  allow "rebase" "Konfliktaufloesung eines Rebase"
}

# ═════════════════════════════════════════════════════════════════════════════
sec "C · Ausweg, Reihenfolge und beide Ausgaenge"

mkrepo c1 && {
  echo x >> f.txt; git add f.txt
  if git commit -qm "umgangen" --no-verify >/dev/null 2>&1; then
    ok "--no-verify auf 'main' geht durch — der Hook ist kein Ersatz fuer die Branch Protection"
  else
    ko "--no-verify auf 'main' wurde blockiert — das kann ein pre-commit-Hook gar nicht"
  fi
}

# ── Die Reihenfolge im Hook, gemessen statt behauptet ────────────────────────
# Die Laufzeitaussage im Hook-Kopf ("13 ms Abbruch auf main gegen 739-1151 ms
# fuer gitleaks") gilt nur, wenn der Branch-Check VOR dem Scan liegt. Das ist am
# Quelltext ablesbar und deshalb genau die Sorte Behauptung, die beim naechsten
# Umsortieren still falsch wird. Der Stub zaehlt mit.
mkrepo c2 && {
  echo x >> f.txt; git add f.txt
  VOR=$(scans)
  git commit -qm "auf main" >/dev/null 2>&1
  [ "$(scans)" = "$VOR" ] \
    && ok "ein abgelehnter Commit erreicht gitleaks NICHT — der Branch-Check steht davor" \
    || ko "der abgelehnte Commit hat gitleaks trotzdem aufgerufen; der Branch-Check steht HINTER dem Scan"

  git switch -qc feature
  VOR=$(scans)
  git commit -qm "auf feature" >/dev/null 2>&1
  [ "$(scans)" -gt "$VOR" ] \
    && ok "GEGENRICHTUNG: ein durchgelassener Commit ruft gitleaks auf — der Scan ist nicht versehentlich abgeschaltet" \
    || ko "auch der durchgelassene Commit hat gitleaks nicht aufgerufen — der Stub oder der Hook ist kaputt, und der Fall darueber belegt dann nichts"
}

# ── Der Konfig-Zweig ist die zweite Sperre, und der Branch-Check steht auch VOR ihr
# Dieses Repo hat einen fail-closed Zweig fuer eine fehlende .gitleaks.toml, das
# Nachbar-Repo nicht. Beide Zweige lehnen ab — unterscheidbar sind sie nur an der
# MELDUNG. Ohne diesen Fall bewiese ein "abgelehnt auf main" ohne Konfig nur,
# dass IRGENDETWAS abgelehnt hat (§18a g).
meldung(){ git commit -m "$1" 2>&1 >/dev/null | tr -d '\r'; }

mkrepo c3 && {
  rm -f .gitleaks.toml
  echo x >> f.txt; git add f.txt
  M=$(meldung "ohne konfig auf main")
  case "$M" in
    *"HEAD steht auf"*) ok "ohne .gitleaks.toml auf 'main': die BRANCH-Meldung kommt, nicht die Konfig-Meldung" ;;
    *".gitleaks.toml fehlt"*) ko "ohne .gitleaks.toml auf 'main' kommt die Konfig-Meldung — der Branch-Check steht hinter dem Konfig-Zweig" ;;
    *) ko "ohne .gitleaks.toml auf 'main' kam keine der beiden erwarteten Meldungen: ${M:-<leer>}" ;;
  esac

  git switch -qc feature
  M=$(meldung "ohne konfig auf feature")
  case "$M" in
    *".gitleaks.toml fehlt"*) ok "GEGENRICHTUNG: auf einem Feature-Branch schlaegt der Konfig-Zweig zu — er ist nicht tot" ;;
    "") ko "auf dem Feature-Branch lief der Commit ohne .gitleaks.toml DURCH — der fail-closed Konfig-Zweig fehlt" ;;
    *) ko "auf dem Feature-Branch kam eine unerwartete Meldung: $M" ;;
  esac
}

cd "$REPO_ROOT" || exit 1
# §18a (a)+(d): kamen im selben Lauf BEIDE Ausgaenge vor? Eine Tabelle, in der
# alles abgelehnt wird, besteht jede deny-Pruefung und ist trotzdem kaputt.
if [ "$N_DENY" -gt 0 ] && [ "$N_ALLOW" -gt 0 ]; then
  ok "beide Ausgaenge kamen vor: $N_DENY Ablehnung(en), $N_ALLOW Durchlass"
else
  ko "nur EIN Ausgang im ganzen Lauf ($N_DENY deny / $N_ALLOW allow) — die Tabelle prueft nur eine Richtung"
fi

# ═════════════════════════════════════════════════════════════════════════════
sec "D · §7a — die PROTECTED-Liste steht zweimal"

# Sie kann nicht zusammengefuehrt werden: die beiden Hooks sind verschiedene
# Mechanismen (git-Hook gegen Claude-Code-PreToolUse) und koennen keine
# gemeinsame Datei lesen, ohne dass ein fehlgeschlagenes `source` eine LEERE
# Liste ergaebe — und eine leere Positivliste erlaubt alles (§18a d). Also die
# andere Haelfte von §7a: eine Assertion, die beide Vorkommen vergleicht.
P_HOOK=$(grep -m1 "^PROTECTED=" "$HOOK" | cut -d"'" -f2)
P_PUSH=$(grep -m1 "^PROTECTED=" "$GUARD_PUSH" | cut -d"'" -f2)
if [ -z "$P_HOOK" ] || [ -z "$P_PUSH" ]; then
  ko "PROTECTED in einer der beiden Dateien nicht gefunden (Hook='$P_HOOK' Push='$P_PUSH') — der Vergleich darunter waere gegen einen leeren Wert immer wahr (§18a c)"
else
  ok "beide PROTECTED-Listen gefunden: '$P_HOOK' / '$P_PUSH'"
  [ "$P_HOOK" = "$P_PUSH" ] \
    && ok "sie stimmen ueberein" \
    || ko "sie laufen auseinander: pre-commit '$P_HOOK' gegen guard-push '$P_PUSH'"
fi

# ═════════════════════════════════════════════════════════════════════════════
sec "E · §7a — der Rettungsweg steht in Hook UND AGENTS.md"

# Die REIHENFOLGE ist die ganze Aussage: `git reset --hard` vor `git branch`
# vernichtet den Commit. Sie steht an zwei Stellen, also wird sie verglichen —
# geprueft wird nicht, DASS die Zeilen da sind, sondern dass branch VOR reset
# kommt. Ein Aufraeumen, das die Zeilen umsortiert, wird hier rot.
#
# `pruefe_reihenfolge` MELDET NICHT SELBST, sondern gibt nur einen Code zurueck:
# 0 = richtig herum, 1 = verdreht, 2 = nicht gefunden. Nur so laesst sich
# derselbe Leser einmal gegen die echten Dateien und einmal gegen einen
# bekannten Gegenfall fahren, ohne dass die Kalibrierung in die Fehlerzahl
# rutscht.
#
# ⚠️ BACKTICKS AUSSCHLIESSEN. Der naive Leser naehme den ERSTEN Treffer je
# Befehl — und im Hook steht `git branch <name>` zuerst in einem KOMMENTAR, die
# Meldung erst gut fuenfzig Zeilen spaeter. Der Vergleich lautete dann
# Kommentar < reset: gruen, und aus dem falschen Grund (§18a g). Der
# Diskriminator folgt dem Schreibgebrauch und gilt in beiden Dateien: PROSA
# zitiert einen Befehl in Backticks, die ANWEISUNG selbst nie.
pruefe_reihenfolge(){ # datei -> Code, plus "b r" auf stdout
  local b r
  b=$(grep -n 'git branch <name>' "$1" | grep -v '`' | head -1 | cut -d: -f1)
  r=$(grep -n 'git reset --hard' "$1" | grep -v '`' | head -1 | cut -d: -f1)
  printf '%s %s' "${b:-0}" "${r:-0}"
  { [ -n "$b" ] && [ -n "$r" ]; } || return 2
  [ "$b" -lt "$r" ] || return 1
  return 0
}

melde(){ # datei  beschreibung
  local was="$2" zeilen code b r
  zeilen=$(pruefe_reihenfolge "$1"); code=$?
  b=${zeilen% *}; r=${zeilen#* }
  case $code in
    0) ok "$was — 'git branch' (Zeile $b) steht VOR 'git reset --hard' (Zeile $r)" ;;
    1) ko "$was — 'git reset --hard' (Zeile $r) steht VOR 'git branch' (Zeile $b). In dieser Reihenfolge ist der Commit weg." ;;
    2) ko "$was — Rettungsweg nicht gefunden; ein Vergleich gegen einen leeren Wert bestuende immer (§18a c)" ;;
  esac
}
melde "$HOOK"   "Meldung des Hooks"
melde "$AGENTS" "AGENTS.md §3"

# KALIBRIERUNG (§17a): der Leser muss eine verdrehte Reihenfolge auch erkennen.
# Ohne diesen Fall waeren die zwei Haken darueber auch dann gruen, wenn
# `pruefe_reihenfolge` immer 0 zurueckgaebe.
PROBE="$FIX/verdreht.txt"
printf 'git reset --hard origin/main\ngit branch <name>\n' > "$PROBE"
pruefe_reihenfolge "$PROBE" >/dev/null
[ $? -eq 1 ] \
  && ok "Kalibrierung: eine verdrehte Reihenfolge wird als verdreht erkannt" \
  || ko "Kalibrierung: der Leser meldet eine VERDREHTE Reihenfolge nicht — die zwei Pruefungen darueber belegen dann nichts"

LEER="$FIX/leer.txt"; : > "$LEER"
pruefe_reihenfolge "$LEER" >/dev/null
[ $? -eq 2 ] \
  && ok "Kalibrierung: eine Datei ohne Rettungsweg wird als 'nicht gefunden' erkannt" \
  || ko "Kalibrierung: eine leere Datei wird nicht als 'nicht gefunden' gemeldet"

# ── Der Anker, auf den der Hook zeigt ────────────────────────────────────────
# Der Hook nennt in seiner Meldung "AGENTS.md §3". Zeigt die Nummer irgendwann
# woanders hin oder faellt die Commit-Zeile weg, verweist eine Ablehnung auf
# eine Regel, die es nicht mehr gibt — und niemand merkt es, weil der Hook
# weiter funktioniert.
grep -q 'AGENTS.md §3' "$HOOK" \
  && ok "der Hook verweist auf AGENTS.md §3" \
  || ko "der Hook nennt seine Regel nicht mehr — der Verweis darunter prueft dann ins Leere"
grep -qE '^3\..*Autonomie-Grenze' "$AGENTS" \
  && ok "AGENTS.md §3 ist weiterhin die Autonomie-Grenze" \
  || ko "AGENTS.md hat unter Nummer 3 keine Autonomie-Grenze mehr — die Meldung des Hooks zeigt auf die falsche Regel"
grep -qF '**Commit auf `main`: nie**' "$AGENTS" \
  && ok "§3 traegt das Commit-Verbot — die Regel, die der Hook durchsetzt" \
  || ko "das Commit-Verbot steht nicht mehr in AGENTS.md; der Hook setzt dann eine Regel durch, die dort niemand findet"

ende
