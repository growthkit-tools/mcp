#!/usr/bin/env bash
# GrowthKit MCP Worker — was eine DEMO-Session zu sehen bekommt.
#
#   ./tests/demo-surface.sh <base-url>
#
# ─────────────────────────────────────────────────────────────────────────────
# WARUM EIGENE SUITE UND NICHT EINE ZEILE IN probe.sh.
#
# probe.sh ist secret-frei und laeuft gegen eine LOKALE Instanz genauso wie
# gegen eine Preview — sein Kopf sagt das ausdruecklich. Diese Pruefung kann das
# nicht: sie braucht eine Session, und eine Session entsteht nur ueber den
# OAuth-Weg gegen die echte Supabase. Eine Zeile in probe.sh haette entweder
# einen FREMDEN, deployten Host fest verdrahtet (dann braucht jeder lokale
# probe.sh-Lauf Netz und einen fremden Deploy) oder probe.sh schreibend gemacht.
# Beides waere ein Rueckschritt fuer ein Werkzeug, das heute ueberall laeuft.
#
# ⚠️ WAS HIER GEMESSEN WIRD, IST index.js — nicht der Directory-Shim.
# `growthkit-mcp-demo` deployt `mcp-directory-shim/`, einen Proxy auf
# mcp.growthkit.tools. Er holt sich seine Session mit genau dem `demo=1`-Weg,
# den diese Suite geht, und die Tool-Filterung fuer `is_demo` passiert danach im
# Worker. Die Assertion gilt also der Demo-Flaeche dieses Repos; der Shim ist
# nur der Aufrufer, den sie nachahmt.
#
# ⚠️ DIESE SUITE SCHREIBT EINE ZEILE. Der `demo=1`-Tanz legt einen
# `oauth_codes`-Eintrag an (den der Token-Tausch selbst wieder loescht) und eine
# `oauth_tokens`-Zeile mit einer Stunde TTL. Ohne Service-Key kann sie die nicht
# entfernen; sie sagt es dann laut, statt es zu verschweigen. Gemessen am
# 04.09.2026: in `oauth_tokens` liegen 1697 Demo-Zeilen, 1696 davon abgelaufen,
# die aelteste vom 17.02.2026 — abgelaufene Demo-Tokens werden heute von nichts
# aufgeraeumt. Ein Lauf dieser Suite ist gegen diesen Bestand nichts; die
# fehlende Aufraeumung gehoert trotzdem berichtet und nicht durch eine weitere
# Quelle vergroessert.
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

BASE="${1:-}"
[ -n "$BASE" ] || { echo "Usage: $0 <base-url>" >&2; exit 2; }
BASE="${BASE%/}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN="$REPO_ROOT/tests/golden/demo-tools.json"
UPDATE=0
[ "${2:-}" = "--update-golden" ] && UPDATE=1

PASS=0; FAIL=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
ko(){ printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
sec(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
ende(){ printf '\n\033[1mErgebnis: %s grün, %s rot\033[0m\n' "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

printf '\n\033[1m%s\033[0m\n' "demo-surface — $BASE"
for w in curl jq python3; do
  command -v "$w" >/dev/null 2>&1 || { ko "$w fehlt"; ende; exit 2; }
done

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ═════════════════════════════════════════════════════════════════════════════
sec "A · Demo-Session holen (derselbe Weg wie der Directory-Shim)"

RED="http://localhost/demo-surface-callback"
LOC=$(curl -s -m 25 -o /dev/null -D - -X POST "$BASE/authorize" \
  --data-urlencode "client_id=demo-surface-test" \
  --data-urlencode "redirect_uri=$RED" \
  --data-urlencode "response_type=code" \
  --data-urlencode "demo=1" | tr -d '\r' | awk '/^[Ll]ocation:/ {print $2}')
CODE=$(printf '%s' "$LOC" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
if [ -n "$CODE" ]; then
  ok "/authorize?demo=1 liefert einen Code"
else
  ko "kein Code aus /authorize — Location war: ${LOC:-<leer>}. Gegen eine lokale Instanz ist das erwartbar: der Demo-Weg schreibt in die echte Supabase und braucht deren Secrets."
  ende; exit 1
fi

TOK=$(curl -s -m 25 -X POST "$BASE/token" -H 'content-type: application/x-www-form-urlencoded' \
  --data-urlencode "grant_type=authorization_code" --data-urlencode "code=$CODE" \
  --data-urlencode "client_id=demo-surface-test" --data-urlencode "redirect_uri=$RED" \
  | jq -r '.access_token // empty')
if [ -n "$TOK" ]; then
  ok "/token tauscht den Code gegen ein Access-Token"
else
  ko "kein access_token — der Tausch ist fehlgeschlagen"; ende; exit 1
fi

# ═════════════════════════════════════════════════════════════════════════════
sec "B · Die Demo-Flaeche"

curl -s -m 25 -X POST "$BASE/" -H 'content-type: application/json' -H "Authorization: Bearer $TOK" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' -o "$TMP/demo.json"
jq -r '.result.tools[]?.name' "$TMP/demo.json" | sort > "$TMP/demo.txt"
ANZ=$(grep -c . < "$TMP/demo.txt" || true)

# §18a (a): eine leere Liste besteht jede "nur Read-only"-Pruefung.
if [ "${ANZ:-0}" -gt 0 ]; then
  ok "die Demo-Session sieht $ANZ Tools (Liste nicht leer)"
else
  ko "die Demo-Session sieht KEIN Tool — alles Weitere waere leer-wahr (§18a a): $(head -c 200 "$TMP/demo.json")"
  ende; exit 1
fi

# GEGENRICHTUNG: ohne Token ist der Katalog groesser. Ohne diesen Fall waere
# auch eine kaputte Filterung, die zufaellig 15 Tools liefert, gruen.
curl -s -m 25 -X POST "$BASE/" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' -o "$TMP/offen.json"
OFFEN=$(jq -r '.result.tools | length' "$TMP/offen.json")
if [ "${OFFEN:-0}" -gt "$ANZ" ]; then
  ok "GEGENRICHTUNG: unauthentifiziert sind es $OFFEN Tools — die Demo-Flaeche ist wirklich gefiltert"
else
  ko "unauthentifiziert sind es $OFFEN, als Demo $ANZ — die Filterung greift nicht oder misst nichts"
fi

# ── nur Read-only ────────────────────────────────────────────────────────────
# READ_ONLY_TOOLS steht in index.js und ist die Liste, an der auch die
# Write-Meterung haengt. Der Vergleich gilt nur, wenn Checkout und Flaeche aus
# demselben Commit stammen — dieselbe Bedingung wie fuer probe.sh Sektion G/H.
python3 - "$REPO_ROOT/index.js" "$TMP/demo.txt" > "$TMP/ro.txt" <<'PY'
import re, sys
quelle, liste = sys.argv[1], sys.argv[2]
s = open(quelle, encoding='utf-8').read()
m = re.search(r'const READ_ONLY_TOOLS = new Set\(\[(.*?)\]\);', s, re.S)
if not m:
    print("KAPUTT"); raise SystemExit
ro = set(re.findall(r'"([A-Za-z_]+)"', m.group(1)))
demo = [z.strip() for z in open(liste, encoding='utf-8') if z.strip()]
print(len(ro))
print(" ".join(t for t in demo if t not in ro))
PY
RO_N=$(sed -n '1p' "$TMP/ro.txt")
SCHREIBEND=$(sed -n '2p' "$TMP/ro.txt")
if [ "$RO_N" = "KAPUTT" ] || [ -z "$RO_N" ] || [ "$RO_N" = "0" ]; then
  ko "READ_ONLY_TOOLS nicht aus index.js gelesen ($RO_N) — der Vergleich darunter waere gegen eine leere Menge immer wahr (§18a c)"
else
  ok "READ_ONLY_TOOLS aus index.js gelesen ($RO_N Eintraege)"
  if [ -z "$SCHREIBEND" ]; then
    ok "alle $ANZ Demo-Tools stehen in READ_ONLY_TOOLS — die Demo-Flaeche ist lesend"
  else
    ko "SCHREIBENDE Tools in der Demo-Flaeche: $SCHREIBEND"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
sec "C · Golden"

# ⚠️ LISTE, NICHT NUR ANZAHL. Eine Zahl sagt, WIE VIELE Tools die Demo sieht;
# sie sagt nicht, WELCHE. Wird ein lesendes Tool gegen ein anderes getauscht,
# bleibt die Zahl gleich und der Golden gruen. Dieselbe Begruendung wie beim
# Lint-Schuldschein in tests/deno-lint.sh. Die Anzahl steht mit drin und wird
# eigens verglichen, damit der haeufigste Fall (eines mehr, eines weniger) auch
# in der Meldung sichtbar ist.
jq -n --argjson n "$ANZ" --arg liste "$(cat "$TMP/demo.txt")" \
  '{count: $n, tools: ($liste | split("\n") | map(select(length > 0)))}' > "$TMP/neu.json"

if [ "$UPDATE" = "1" ]; then
  cp "$TMP/neu.json" "$GOLDEN"
  ok "Golden aktualisiert: $GOLDEN ($ANZ Tools)"
elif [ ! -f "$GOLDEN" ]; then
  ko "Golden fehlt ($GOLDEN) — mit --update-golden anlegen"
else
  G_N=$(jq -r '.count' "$GOLDEN")
  if [ "$G_N" = "$ANZ" ]; then
    ok "Anzahl unveraendert: $ANZ"
  else
    ko "Anzahl weicht ab: Golden $G_N, live $ANZ"
  fi
  if diff -u <(jq -S '.tools' "$GOLDEN") <(jq -S '.tools' "$TMP/neu.json") > "$TMP/diff.txt"; then
    ok "Tool-Liste identisch zum Golden"
  else
    ko "Demo-Tool-Liste weicht vom Golden ab:"
    sed 's/^/      /' "$TMP/diff.txt" | head -20
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
sec "D · Aufraeumen"

# Der Token-Tausch loescht die `oauth_codes`-Zeile selbst; uebrig bleibt eine
# `oauth_tokens`-Zeile mit einer Stunde TTL. Loeschen braucht den Service-Key —
# ohne ihn wird es GEMELDET, nicht verschwiegen (§18a c).
if [ -n "${SUPABASE_URL:-}" ] && [ -n "${SUPABASE_SECRET_KEY:-}" ]; then
  # ⚠️ HEADER WIE sbHeaders() IN index.js, nicht wie es naheliegt: ein
  # Legacy-JWT-Key (beginnt mit "eyJ") braucht apikey UND Authorization, ein
  # `sb_secret_`-Key NUR apikey. Mit dem falschen Satz antwortet PostgREST 401,
  # und das Aufraeumen scheiterte still an einer Kopfzeile.
  HDR=(-H "apikey: ${SUPABASE_SECRET_KEY}")
  case "$SUPABASE_SECRET_KEY" in
    eyJ*) HDR+=(-H "Authorization: Bearer ${SUPABASE_SECRET_KEY}") ;;
  esac
  CODE_HTTP=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X DELETE \
    "${SUPABASE_URL%/}/rest/v1/oauth_tokens?access_token=eq.${TOK}" \
    "${HDR[@]}" -H "Prefer: return=minimal")
  case "$CODE_HTTP" in
    2*) ok "die erzeugte oauth_tokens-Zeile ist geloescht (HTTP $CODE_HTTP)" ;;
    *)  ko "Loeschen fehlgeschlagen (HTTP $CODE_HTTP) — die Zeile laeuft in einer Stunde ab" ;;
  esac
else
  printf '  \033[33m⚠\033[0m %s\n' "kein SUPABASE_SECRET_KEY in der Umgebung: die erzeugte oauth_tokens-Zeile bleibt und laeuft in einer Stunde ab. Kein Fehler, aber auch keine Aufraeumung."
fi

ende
