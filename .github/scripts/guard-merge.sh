#!/usr/bin/env bash
# GrowthKit MCP — guard-merge: braucht dieser PR einen Menschen?
#
#   printf '{"files":["index.js"],"body":"...","commits":["..."]}' | .github/scripts/guard-merge.sh
#
# Ausgabe auf stdout: eine Zeile je VERLETZTER Regel, mit Praefix R1':/R2:/R4:
# Exit 0 = keine Regel verletzt (Auto-Merge darf greifen)
# Exit 1 = mindestens eine Regel verletzt (Mensch entscheidet)
# Exit 2 = Setup-/Eingabefehler (fail-closed, zaehlt wie rot)
#
# ─────────────────────────────────────────────────────────────────────────────
# ROT IST KEIN FEHLER, SONDERN EINE ANWEISUNG.
#
# Gruen heisst "Auto-Merge darf greifen", rot heisst "Chris schaut hin". Er kann
# als Admin auch einen roten PR mergen; CC kann es nicht. Deshalb ist ein
# falsches Rot billig und ein falsches Gruen teuer — dieselbe Fehlerrichtung wie
# bei guard-push, und derselbe Entwurf: alles Undurchschaubare wird abgelehnt.
#
# VORLAGE: supabase `.github/scripts/guard-merge.sh` (#142/#143/#145). Die
# Bauart ist uebernommen, die REGELN sind hier gemessen (SPEC-guard-merge-
# auto-merge.md §6, R0 vom 22.09.2026). Drei Stellen weichen von der Vorlage ab,
# und alle drei aus einem Messwert, nicht aus Geschmack:
#
#   * R1 heisst hier R1' und meint den GOLDEN MASTER statt Migrationen — dieses
#     Repo hat keine Migrationen, aber zwei Golden-Dateien.
#   * R2 liest ZUSAETZLICH die Commit-Messages. §18b dieses Repos legt den
#     Beleg ausdruecklich in den Commit, nicht in die PR-Beschreibung —
#     gemessen ueber die letzten 21 Code-PRs: im Body allein trugen ihn 2, in
#     Body ODER Commit 18. Ein Body-only-R2 waere auf 19 von 21 rot gewesen,
#     und eine Regel, die fast jeden PR blockiert, wird abgeschaltet.
#   * R3 entfaellt (Begruendung an seiner Stelle unten).
#
# R5 und R6 der Spec gibt es hier nicht — wie drueben (W1/W4).
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

die(){ printf 'guard-merge: %s\n' "$1" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq fehlt — ohne jq ist die Eingabe nicht lesbar, also Ablehnung (fail-closed)."

EVENT=$(cat)
printf '%s' "$EVENT" | jq -e . >/dev/null 2>&1 || die "Eingabe ist kein valides JSON (erwartet: {\"files\":[...],\"body\":\"...\",\"commits\":[...]})."

# ─────────────────────────────────────────────────────────────────────────────
# DIE EINGABE-GUARDS, und die Unterscheidung dazwischen traegt.
#
# `files` FEHLT oder ist kein Array  -> Exit 2. Ohne diesen Guard liefe jede
#   Regel ueber eine leere Liste: "kein Golden geaendert", "kein Workflow
#   geaendert" — alles gruen, lautlos (§18a a).
# `files` ist ein LEERES Array       -> gruen. Ein PR ohne Dateien verletzt
#   nichts. Der fehlgeschlagene API-Abruf sieht von hier aus genauso aus;
#   deshalb faengt ihn der WORKFLOW, wo sein Exit-Code noch sichtbar ist
#   (§18a l: ein Objekt, zwei Ereignisse).
#
# `commits` ist hier PFLICHT, anders als drueben, weil R2 es liest. Fehlt es,
# liefe R2 nur ueber den Body — und ein kaputter Aufrufer saehe aus wie "kein
# Commit traegt einen Beleg". Schlimmer waere der umgekehrte Umbau, bei dem ein
# fehlendes Feld als "Beleg vorhanden" durchginge. Also Exit 2.
# ─────────────────────────────────────────────────────────────────────────────
printf '%s' "$EVENT" | jq -e 'has("files")' >/dev/null 2>&1 || die "Feld 'files' fehlt — ohne Dateiliste laeuft jede Regel leer-wahr durch."
printf '%s' "$EVENT" | jq -e '.files | type == "array"' >/dev/null 2>&1 || die "Feld 'files' ist kein Array."
printf '%s' "$EVENT" | jq -e 'has("commits")' >/dev/null 2>&1 || die "Feld 'commits' fehlt — R2 laese dann nur den Body, und ein kaputter Aufrufer saehe aus wie ein PR ohne Beleg."
printf '%s' "$EVENT" | jq -e '.commits | type == "array"' >/dev/null 2>&1 || die "Feld 'commits' ist kein Array."

FILES=$(printf '%s' "$EVENT" | jq -r '.files[]' 2>/dev/null)
BODY=$(printf '%s' "$EVENT" | jq -r '.body // ""' 2>/dev/null)
# Die Commit-Messages als EIN Text: fuer den Wortstamm genuegt das, und eine
# Nachricht mit Zeilenumbruechen bleibt dabei heil.
COMMITS=$(printf '%s' "$EVENT" | jq -r '.commits | join("\n")' 2>/dev/null)

VERSTOSS=0
melde(){ printf '%s\n' "$1"; VERSTOSS=1; }

# Zaehlt Treffer eines Musters in der Dateiliste, ohne bei 0 zu scheitern.
zaehle(){ printf '%s\n' "$FILES" | grep -cE "$1" 2>/dev/null || true; }
nenne(){  printf '%s\n' "$FILES" | grep -E "$1" 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/ $//'; }

# ── R1' · Golden Master ──────────────────────────────────────────────────────
# Der Golden Master ist die Stelle, an der eine Schema-Aenderung SICHTBAR wird
# (Leitplanke 19): weicht er ab, ohne dass jemand die Aenderung gewollt hat,
# ist die Aenderung der Bug. Eine stille Golden-Aenderung waere genau der Fall,
# in dem ein Agent den Golden "repariert", damit CI gruen wird.
#
# Beide Dateien, die es gibt (R0, 22.09.2026): tests/golden/tools.json schreibt
# scripts/probe.sh, tests/golden/demo-tools.json schreibt tests/demo-surface.sh.
#
# ⚠️ "MIT GRUND" IST TEIL DER REGEL. Die Phrase allein reicht nicht — sonst
# waere sie eine Zauberformel, die man ohne Nachdenken dazuschreibt. Verlangt
# wird, dass nach "Golden aktualisiert" auf derselben Zeile noch ein Wort
# folgt: "Golden aktualisiert: neue Property x" besteht, "Golden aktualisiert."
# nicht.
#
# ⚠️ NUR DER BODY, nicht die Commit-Messages — anders als R2. Die Phrase ist
# eine NEUE Abmachung (gemessen: 6 der letzten 7 Golden-PRs tragen sie nicht),
# und sie richtet sich an den, der den PR liest. R2 dagegen trifft auf eine
# BESTEHENDE Abmachung (§18b), die den Beleg in den Commit legt.
R1_PAT='^tests/golden/'
if [ "$(zaehle "$R1_PAT")" -gt 0 ]; then
  GRUND=$(printf '%s' "$BODY" | grep -ciE 'golden aktualisiert[^[:alnum:]]*[[:alnum:]]' || true)
  if [ "${GRUND:-0}" -eq 0 ]; then
    melde "R1': $(nenne "$R1_PAT") geaendert, aber die PR-Beschreibung nennt kein 'Golden aktualisiert' mit Grund — eine stille Golden-Aenderung merged Chris manuell."
  fi
fi

# ── R2 · Falsifikationsbeleg ─────────────────────────────────────────────────
# Gilt nur fuer PRs, die Code oder Suiten anfassen — ein Docs-PR hat nichts zu
# falsifizieren (drueben W2, hier uebernommen).
#
# ⚠️ WAS HIER "CODE" IST, IST GEMESSEN (R0). Die Spec sagt `src/**`; dieses Repo
# hat kein src/ auf oberster Ebene. Der Worker ist `index.js` im Root — ein
# wortgetreues `src/**` haette die Hauptquelle NIE erfasst und den Guard fuer
# fast jeden Code-PR stumm gemacht (§18a k, zu kleine Grundmenge). Code sind:
#   index.js                  der Worker
#   mcp-directory-shim/src/   der zweite Worker (eigenes Deployable)
#   scripts/                  probe.sh — schreibt den Golden
#   tests/                    die Suiten
#   .githooks/, .claude/hooks/  die lokalen Waechter
#
# ⚠️ BODY ODER COMMIT-MESSAGE, und das ist die Messung, die den Zuschnitt
# traegt: §18b sagt woertlich "Der Beleg gehoert in die Commit-Message, nicht
# in die PR-Beschreibung". Ueber die letzten 21 Code-PRs: Beleg im Body 2,
# in Body ODER Commit 18. Die drei ohne (#42, #44, #46) tragen tatsaechlich
# keinen — dort ist rot richtig.
#
# ⚠️ Wortstamm, case-insensitiv (drueben kalibriert: "## Falsifikation",
# "FALSIFIZIERT" und "falsifiziert" muessen alle bestehen). `grep -c` statt
# `grep -q` wegen pipefail/SIGPIPE — sonst greift die Regel zufaellig mal
# nicht (drueben gemessen: 18 von 40 Laeufen).
R2_RELEVANT='^(index\.js$|mcp-directory-shim/src/|scripts/|tests/|\.githooks/|\.claude/hooks/)'
if [ "$(zaehle "$R2_RELEVANT")" -gt 0 ]; then
  IM_BODY=$(printf '%s' "$BODY" | grep -ciE 'falsifi' || true)
  IM_COMMIT=$(printf '%s' "$COMMITS" | grep -ciE 'falsifi' || true)
  if [ "${IM_BODY:-0}" -eq 0 ] && [ "${IM_COMMIT:-0}" -eq 0 ]; then
    melde "R2: weder PR-Beschreibung noch Commit-Messages nennen eine Falsifikation — ein ungepruefter Code-PR merged Chris manuell."
  fi
fi

# ── R3 · entfaellt ───────────────────────────────────────────────────────────
# Drueben verhindert R3 die Sammelaenderung "ein _shared-Modul plus viele
# Aufrufer in einem PR". Hier gibt es dafuer keine Entsprechung, gemessen am
# 22.09.2026:
#   * index.js ist EINE Datei ohne Modulschnitt (AGENTS.md, "Bekannte Fallen")
#     — es gibt kein Modul und keine Aufrufer, die man auseinandersortieren
#     muesste.
#   * mcp-directory-shim importiert NICHTS aus dem Worker; seine Importe sind
#     die eigenen Dateien und npm-Pakete.
#   * Die einzige Kopplung ist eine GESPIEGELTE Liste (DEMO_ALLOWLIST im Shim ↔
#     DEMO_TOOLS im Worker). Das ist das Gegenteil einer Sammelaenderung: dort
#     ist der Fehler, NUR eine Seite zu aendern.
# Eine Regel ohne moegliches Ausloesen waere ein toter Zweig, der wie eine
# Absicherung aussieht (§18a a).

# ── R4 · Das Netz aendert nur ein Mensch ─────────────────────────────────────
# Workflows und der Guard selbst. Ein Guard, der seine eigene Aenderung
# durchwinken koennte, ist keiner — er koennte sich in einem Lauf abschalten.
R4_PAT='^\.github/workflows/|^\.github/scripts/guard-merge\.sh$|^tests/guard-merge\.sh$'
if [ "$(zaehle "$R4_PAT")" -gt 0 ]; then
  melde "R4: $(nenne "$R4_PAT") geaendert — Workflows und guard-merge selbst merged Chris manuell."
fi

if [ "$VERSTOSS" -eq 0 ]; then
  printf 'guard-merge: keine Regel verletzt.\n'
  exit 0
fi
exit 1
