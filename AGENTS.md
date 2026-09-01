# GrowthKit MCP Worker — Agent Quick Reference

> **Ablage:** Repo-Root als `AGENTS.md`. Danach `git rm CLAUDE.md && ln -s AGENTS.md CLAUDE.md`
> — eine Quelle, zwei Namen. Zwei getrennte Guide-Dateien driften auseinander.
>
> **Prinzip:** Jede Zeile geht auf einen beobachteten Fehler oder eine reale Invariante
> zurück. Neue Zeilen nur bei echtem Anlass. Zeilen ohne Anlass sind Rauschen.
>
> `⚠️ TODO` = gegen das Repo verifizieren. `🔵 ENTSCHEIDUNG` = Chris muss bestätigen.

---

## Wissen

Cloudflare Worker, serviert den GrowthKit MCP-Server auf `mcp.growthkit.tools`.

- **Ein hand-rolled File: `index.js`, ~4200 Zeilen** *(Stand 24.08.2026)*. MCP JSON-RPC
  manuell implementiert,
  **kein SDK**. `tools/list`, `tools/call`, `resources/list`, `resources/read`, Prompts
  und OAuth sind alle von Hand gebaut. Es gibt keine Bibliothek, die Fehler abfängt.
- Konsumenten: Claude (Desktop/Web/Code), ChatGPT, MCP-Registries. **Regressionen brechen
  still** — kein Alert, nur sinkende Nutzung. Deshalb ist der Golden Master nicht optional.
- Backend: Supabase-Projekt (EU Frankfurt) über Edge Functions,
  Custom Domain `api.growthkit.tools` proxied `/functions/v1/*`.
  Project-Ref steht in `wrangler.toml` / den Worker-Secrets, nicht hier.
- Auth: **Zwei Auflösungswege, unterschieden allein am Token-Präfix** (`index.js` ~1321).
  Die Entscheidung fällt vor jedem Backend-Aufruf.
  - Bearer beginnt mit `gk_` → **direkter API-Token-Pfad**: `resolve_user_token` gegen
    `user_api_tokens`; die RPC hasht selbst und prüft `is_active`. Kein OAuth, kein
    Browser — das ist der Pfad für Tests, CI und Automatisierung. Zwei bewusste
    Nicht-Handlungen: `last_used_at` bleibt **ungeschrieben** (`resolve_user_token`
    schreibt nicht, das tut nur `use_api_token`), Tokens sehen über diesen Weg also
    unbenutzt aus; und `isDemo` ist hier **immer `false`** — `user_api_tokens` hat kein
    `is_demo`, Demo-Sessions laufen ausschließlich über OAuth.
  - Alles andere → **OAuth-Pfad** wie bisher: gegen `oauth_tokens.access_token` mit
    Ablaufprüfung; das `gk_`-Token liegt dort als `user_token`.

  Beide Wege enden bei `userToken`; alles danach — Rollenableitung, Metering,
  Tool-Dispatch — hängt nur noch daran. Beide antworten bei Misserfolg mit **derselben**
  Meldung (`Invalid or expired token`) — Absicht, sie darf nicht verraten, ob ein Token
  unbekannt oder deaktiviert ist. Damit ist die Meldung allein kein Beleg, welcher Zweig
  lief; dafür gibt es den maschinenlesbaren Diskriminator `data.path`
  (`api_token` | `oauth`), an dem `tests/auth-paths.sh` hängt.
  *(Live verifiziert, 20.08.)*
  — Nicht zu verwechseln mit dem **Query-Scoping** auf `to_token_hash`, siehe §14.
    Das ist eine andere Aussage über eine andere Ebene und weiterhin gültig.

- **Die Rolle kommt aus dem Präfix, nicht aus der Datenbank** (`index.js` ~1376):
  `gk_team_` → `team`, `gk_view_` → `view`, **alles andere → `admin`**. Das Präfix kann
  nur **herabstufen** — ein präfixloses `gk_`-Token bekommt die höchste Rolle.
  Live belegt an einem Workspace: **68 Tools für `admin`, 63 für `gk_team_`** (die fünf
  Differenzen sind die admin-only-destruktiven). Beide Tokens lösen auf **denselben
  `user_id`** auf — **die Rolle unterscheidet sich, der Datenraum nicht.** Wer die
  Rollenfilterung für eine Mandantengrenze hält, liegt falsch.
  *(Live verifiziert, 20.08.)*
  - **Betriebsregel: ein CI-/Testtoken wird bewusst als `gk_view_` angelegt.** Sonst
    läuft der Runner mit `admin` — schreibend, auf echte Workspace-Daten, denn
    Preview-Versionen nutzen dieselben Bindings und Secrets wie Production. Die Rolle
    steckt im **Namen** des Tokens, nicht in einer Prüfung: im Workflow steht nur ein
    Secret-Name, beim Review sieht man sie nicht. Sie muss beim **Anlegen** entschieden
    werden. `gk_team_` wäre die Obergrenze, ein präfixloses Token nie.

    Konkret statt „weniger": `gk_view_` sieht **30 von 68 Tools**. Davon sind **29
    lesend — und eines nicht.** `setWorkingMemory` ist für `view` freigegeben, steht
    nicht in `READ_ONLY_TOOLS` (wird also als Write gemetert) und ist als
    `DESTRUCTIVE_TOOLS` klassifiziert; ein Handler-Guard fängt es nicht ab. Der
    Working-Memory-Zustand ist session-lokal und bewusst für alle Rollen schreibbar —
    aber **„`gk_view_` ist schreibfrei" ist damit falsch.** Für die CI-Pfade folgenlos
    (`probe.sh`, `report-tools.sh`, `auth-paths.sh` rufen es nicht auf); als Zusage an
    einen Token-Empfänger wäre es eine, die der Code nicht deckt.
- Deploy: **automatisch bei Push** via Cloudflare Workers Builds (Git-Integration).
  Deploy-Command `npx wrangler deploy`, Version-Command `npx wrangler versions upload`.
  Es gibt **bewusst keine GitHub-Action** dafür — das ist kein Versäumnis, füge keine hinzu.
- **Builds für Non-Production-Branches sind aktiv:** jeder Push auf einen Feature-Branch
  erzeugt eine **Preview-Version mit eigener URL**, ohne Production anzufassen.
  ⚠️ Preview-Versionen nutzen **dieselben Bindings und Secrets wie Production** — sie
  sprechen mit der echten Supabase. Probes dürfen nur lesen.
- **Build-Watch-Konfiguration** (Dashboard, dort am 20.08. nachgesehen):
  Include `*` · Exclude `*.md`, `specs/**`, `.claude/**`, `.github/**`, `tests/**`,
  `scripts/**`. Gedanke dahinter: ausgeschlossen wird, was das ausgelieferte Deployable
  nicht verändert.

  **Wann die Excludes tatsächlich greifen, ist nur teilweise belegt.** Der Belegstand,
  und nur er:
  - Merge-Commits auf `main` mit ausschließlich exkludierten Pfaden bauen **nicht**
    (`9670879`, `7187c66` — `probe`-Job übersprungen).
  - Der **erste** Push eines neuen Branches baut **immer**, auch mit ausschließlich
    exkludierten Pfaden (`abe9ca3`).
  - Ein **Folge-Push** auf einem Branch mit Build-Historie baut **ebenfalls** —
    `a198ebd` fasste nur `AGENTS.md` an und hat gebaut, obwohl `*.md` im Dashboard als
    Exclude gesetzt ist (PR #10, Step-Conclusions geprüft: kein Step `skipped`).
  - Ein weiterer Folge-Push, andere exkludierte Pfade: `tests/**` und `.github/**`
    (PR #12) — **ebenfalls gebaut**.

  **Vier gleichgerichtete Beobachtungen sind kein Einzelfall mehr.** Das Muster, das
  sich daraus abzeichnet: **auf Feature-Branches greifen die Excludes offenbar generell
  nicht** — unabhängig von Build-Historie und unabhängig davon, welcher exkludierte Pfad
  angefasst wird. Nur Merge-Commits auf `main` verhalten sich anders.

  ⚠️ **Das Muster erklärt nichts.** Warum `main` und Feature-Branches sich unterscheiden,
  ist weiterhin **OFFEN** — die Exclude-Liste ist es nicht, sie wurde am 20.08. im
  Dashboard geprüft und steht vollständig. Ein Muster ist kein Mechanismus: es sagt, was
  man erwarten kann, nicht warum. Praktisch heißt das unverändert: **auf einem
  Feature-Branch mit „kein Build" zu rechnen, ist unbegründet.** Die frühere Fassung
  dieser Zeile behauptete, die Excludes griffen „ab einem Branch mit Build-Historie" —
  das war aus den `main`-Merge-Commits extrapoliert und ist widerlegt.
  *(Beobachtet, 20.08.)*

- **Die Build-Konfiguration lebt ausschließlich im Cloudflare-Dashboard** — Include- und
  Exclude-Paths, Deploy- und Version-Command, Branch-Einstellungen. Sie hinterlässt
  **keine Repo-Spur**: keine Datei definiert sie, und wenn sie sich ändert, zeigt das
  kein Diff. Jede Aussage darüber im Repo — diese Datei, der Kommentar am `wait`-Step in
  `ci.yml` — ist eine **Kopie mit Stand-Datum** und kann still veraltet sein.
  **Vor Gebrauch nachsehen lassen, nicht aus der Datei zitieren.** Am 20.08. lagen wir
  dreimal darüber falsch; jedes Mal war die Korrektur ein Blick ins Dashboard und keine
  Analyse. Ein Agent kommt nicht heran — also fragen, nicht schlussfolgern.
  *(Beobachtet, 20.08.)*

### Dieses Repo ist ÖFFENTLICH

Öffentlich gemacht für die MCP-Directory-Listings. **Niemals** committen: Secrets, Tokens,
API-Keys, interne URLs mit eingebetteten Keys, Kundendaten, `gk_`- oder `sb_secret_`-Werte.
Alle Secrets laufen über Worker-Env-Vars (`wrangler secret put`); lokale Secrets gehören in
`.dev.vars` / `.env` (gitignored). Wenn du beim Debuggen versucht bist, einen echten
Token/Key als Konstante hart zu setzen: **STOPP und frag** — niemals hardcoden.

Diese Datei selbst ist absichtlich eingecheckt: Konventions- und Workflow-Doku, keine
Secrets, und öffentlich zu sein ist hier ein gutes Engineering-Signal.

**Seit 28.08.2026 steht ein Scanner dahinter, nicht nur dieser Absatz.** `gitleaks` in
drei Ebenen, absteigend nach Verbindlichkeit:

| Ebene | wo | greift | Lücke |
|---|---|---|---|
| **Gate** | `.github/workflows/ci.yml`, unit-Job | jeder PR, fail-closed | sieht nur, was gepusht ist |
| **Hook** | `.githooks/pre-commit` | vor dem Commit, `--staged` | nur wo `core.hooksPath` gesetzt ist; `--no-verify` übergeht ihn |
| **Push Protection** | GitHub, serverseitig | beim Push | engerer Regelsatz, siehe unten |

⚠️ **Push Protection allein reicht hier nicht, und das ist gemessen.** Sie greift erst
beim **Push** — der Wert steht dann schon in einem lokalen Commit. Und ihr Regelsatz ist
enger: ein echter `gk_view_…`-Token wird vom gitleaks-**Standardsatz** nicht gefunden
(0 Funde), erst von der eigenen Regel in `.gitleaks.toml` (1 Fund). Was der Standardsatz
nicht kennt, kennt GitHub auch nicht. Die frühere Begründung „mcp braucht keinen Hook,
weil öffentlich" war falsch herum: **öffentlich heißt höheres Risiko, nicht geringeres.**

⚠️ **Der Erstscan am 28.08.2026 war sauber — beide Hälften.** Getrackter Checkout:
479 635 B, **0 Funde**. Historie über alle Refs: **79 von 80 Commits** (der 80. ist ein
leerer Commit ohne Inhalt), **0 Funde**. Lokal mit den ignorierten Dateien: 2 Funde, beide
in `gk-mcp-key.pem` und `.gk-ci-token` — ungetrackt, gitignored, nie in einem Commit.
**Es ist also nichts zu rotieren.** Wäre etwas gefunden worden, gälte es als
kompromittiert, auch wenn es heute nicht mehr im Checkout liegt: bei einem öffentlichen
Repo zählt, was je in einem gepushten Commit stand.

**Maßgeblich ist der Code, nicht diese Datei.** Bei Widerspruch gewinnt der Code — aber
melde den Widerspruch, statt ihn still zu übergehen.

---

## Werkzeuge

```
Tool-Versionen:  package.json (exakte Versionen, kein Caret) + package-lock.json
                 Node: 24.16.0 · Deno: 2.8.0 (seit 30.08.2026 für `deno lint` genutzt)
Lokal starten:   npm run dev                     # wrangler dev → localhost:8787
Tests:           npm test → exit 1, ERWARTET, kein Gate
                 # Es gibt keine Testdatei und gab nie eine. Diese Zeile stand hier
                 # bis 28.08.2026 als "vitest + @cloudflare/vitest-pool-workers" und
                 # hat damit eine Verdrahtung behauptet, die es nie gab. CI ruft
                 # dasselbe MIT --passWithNoTests und ist deshalb grün.
                 # Warum das so bleibt: "Bekannte Fallen".
Secret-Scan:     gitleaks 8.30.1 (in CI gepinnt, .github/workflows/ci.yml)
                 git config core.hooksPath .githooks   # einmal je Clone, sonst
                 # liegt .githooks/pre-commit im Repo und laeuft nie.
                 # ⚠️ Der Hook traegt seit dem 01.09.2026 ZWEI Pruefungen: erst die
                 # Branch-Haelfte (§3), dann diesen Scan. Wer core.hooksPath nicht
                 # setzt, verliert beide.
                 gitleaks detect --no-git --source . --config .gitleaks.toml
                 # derselbe Befehl, den CI faehrt. Die Pfad-Ausnahmen in der
                 # Konfig existieren nur, damit er LOKAL nicht dauerhaft rot ist.
Lint:            ./tests/deno-lint.sh           # deno lint + Schuldschein
                 # Bis 30.08.2026 lief hier KEIN Linter. deno lint statt eslint:
                 # keine npm-Dependency, parst .js und .ts. Läuft im unit-Job.
                 # Die 11 verbleibenden Verstöße stehen als LINT_DEBT IN der
                 # Suite — Liste, keine Zahl, und sie darf nur schrumpfen.
                 # ⚠️ deno lint hat KEINEN Massen-Suppressions-Mechanismus wie
                 # eslint 9.32; seine Bordmittel (deno-lint-ignore, rules.exclude)
                 # sagen alle „für immer in Ordnung". Deshalb ein eigener
                 # Schuldschein statt einer Ausnahmeliste.
Quell-Checks:    ./tests/source-invariants.sh   # §11, ohne HTTP, ohne Instanz
                 # Laufen im unit-Job, der NIE übersprungen wird. probe.sh delegiert
                 # in Sektion H mit --nested hierher. Einzige Kopie von
                 # EXP_UI_PROTOCOL im Repo — nie eine zweite anlegen.
Auth-Pfade:      ./tests/auth-paths.sh <base-url>
                 # Prüft, WELCHER Auflösungsweg betreten wurde (data.path) und dass
                 # die öffentlichen Pfade offen bleiben. Secret-frei, weil nur
                 # Negativfälle: der Positivfall braucht ein echtes gk_-Token und
                 # bleibt manuell. Läuft im probe-Job.
Report-Tools:    ./tests/report-tools.sh <base-url>   # läuft im probe-Job
Golden Master:   tests/golden/tools.json
Golden updaten:  ./scripts/probe.sh <base-url> --update-golden
                 # NUR bei beabsichtigter Schema-Änderung
Golden LOKAL:    npm run dev                     # Terminal 1
                 ./scripts/probe.sh http://localhost:8787 --update-golden
                 # Bevorzugter Weg. Code und Golden landen atomar in EINEM Commit —
                 # kein amend, kein force-push, und keine Race zwischen zwei schnell
                 # aufeinanderfolgenden Pushes (die branch-basierte Alias-URL zeigt
                 # auf die neuere Version, während der Check-Run noch zum älteren
                 # Commit gehört).
                 # Läuft OHNE .dev.vars: SUPABASE_URL steht in [vars], KV wird lokal
                 # simuliert, und A–G fassen nur unauthentifizierte Pfade an.
                 # Sektionen sind nicht gleichartig: A, C, D, E, F prüfen nur die
                 # servierte Fläche. B (server.json), G (Golden), H (index.js) und
                 # I (Handshake) vergleichen den Checkout GEGEN die Fläche und gelten
                 # nur, wenn beide Seiten aus demselben Commit stammen. Die frühere
                 # Kurzformel „A–G gegen die URL, H von Disk" war falsch.
Handshake:       ./scripts/probe.sh <base-url>   # Sektion I, seit 29.08.2026
                 # Nagelt fest, was initialize liefern MUSS: protocolVersion gegen die
                 # Konstante (nicht gegen ein Literal — §7), serverInfo.name/.version
                 # gegen SERVER_NAME/SERVER_VERSION, die drei capabilities-Schlüssel
                 # mit booleschem listChanged, und dass ping mit {} antwortet.
                 # ⚠️ GRENZE, nachgemessen: wer die KONSTANTE bumpt, bewegt beide
                 # Seiten und bleibt grün. Das ist beabsichtigt (§7: eine Quelle) und
                 # heißt zugleich, dass kein Test prüft, ob der Server die Revision,
                 # die er ansagt, auch implementiert.
Probe:           ./scripts/probe.sh <base-url>   # lokal oder Preview-Version-URL
Preview-URL:     https://<branch-slug>-growthkit-mcp.purple-sun-a0b3.workers.dev
                 (Branch-Slug = Branch-Name mit '/' → '-')
CI:              .github/workflows/ci.yml — testet und probt NUR, deployt nie
```

**Kein Docker im Code-Server verfügbar** und nichts hier braucht welches. Wenn du auf ein
Werkzeug stößt, das Docker voraussetzt: nicht umgehen, eskalieren.

### Push, der `.github/workflows/**` anfasst, braucht einen Umweg

**Für dieses Repo am 24.08. nachgesehen, nicht übernommen:** das Remote ist inzwischen
**HTTPS** (früher SSH), `~/.gitconfig` bindet `gh auth git-credential` an
`https://github.com`, und der `gh`-Token trägt `admin:public_key, gist, read:org, repo` —
**kein `workflow`**. Ein blanker `git push` greift immer zuerst auf ihn zu und scheitert,
sobald der Commit eine Workflow-Datei anfasst.

Es braucht das fine-grained PAT **und** einen leeren `-c credential.helper=` als **ersten**
Eintrag, der die geerbte Helper-Liste zurücksetzt. Ohne den leeren Eintrag ist git fertig,
bevor der eigene Helper drankommt — **und die Fehlermeldung nennt den Grund nicht.**

---

## Leitplanken (nicht verhandelbar)

### Deploy & Git

1. **Kein manuelles `wrangler deploy`.** Deploy passiert ausschließlich über Push.
   Manueller Deploy erzeugt unsichtbare Drift zwischen Repo-Stand und Live-Worker.
2. Keine GitHub-Action fürs Deployment. Deploy und Preview-Upload gehören Cloudflare
    Workers Builds. Actions dürfen ausschließlich testen und proben — nie deployen, nie
    wrangler deploy/versions upload aufrufen.
3. 🔵 **ENTSCHEIDUNG — Autonomie-Grenze:**
   - Commit + Push auf **Feature-Branch**: erlaubt
   - **Commit auf `main`: nie** — auch der, den niemand pusht
   - Push auf `main`: **nie**
   - PR öffnen: erlaubt
   - PR mergen: **nie** — Mensch approved
   - **Ein CC-Lauf arbeitet in genau einem Repo.** Pushes in Nachbar-Repos lehnt
     `.claude/hooks/guard-push.sh` ab und tut das zu Recht: er prüft `symbolic-ref` und
     `PROTECTED` **des Repos, in dem er läuft**. Bei einem Push woanders hin wäre das die
     falsche Prüfung mit grünem Ergebnis.
     ⚠️ Ein `--git-dir`-Umweg **liefe durch** und wäre genau diese Scheinsicherheit — er
     ist keine Lösung, sondern die Umgehung.
     Für Arbeit in mehreren Repos: **pro Repo ein eigener Lauf.** Die Alternative — der
     Mensch als Push-Knopf — war am 24.08. zweimal nötig und ist keine Dauerlösung.
     *(Der Guard zitiert diesen Paragraphen in seiner `cd`-Ablehnung.)*

   ⚠️ **Die Commit-Zeile stand hier bis zum 01.09.2026 nicht** — die Liste nannte den
   Commit nur in der **Erlaubnis** („Commit + Push auf Feature-Branch"), das Verbot
   darunter nur den **Push**. Wer committen will, liest damit eine Erlaubnis und
   findet kein Verbot; der Feature-Branch liest sich als der übliche Ort, nicht als
   der einzige. Geschärft, nicht verdoppelt: eine zweite Formulierung an anderer
   Stelle wäre die Fassung, die als erste veraltet.

   Der zweite Grund ist struktureller und mit einer Regel nicht zu beheben: der
   einzige Durchsetzer, den dieser Paragraph nennt, ist `.claude/hooks/guard-push.sh`
   — und der sitzt am **Push**. Zu dem Zeitpunkt ist der Commit geschrieben. Er ist
   zudem ein PreToolUse-Hook von Claude Code und feuert nur, wenn Claude Code das
   Kommando ausführt; ein `git commit` aus dem Terminal läuft an ihm vorbei. Die
   **Commit-Fläche war unbewacht**, bis `.githooks/pre-commit` sie am 01.09.2026
   übernommen hat — der einzige Hook dieses Repos, der am Commit statt am Push
   greift. Er lässt losgelösten HEAD und laufende Merge-, Rebase-, Cherry-Pick- und
   Revert-Vorgänge ausdrücklich durch; die Gründe stehen dort.

   ⚠️ **Der Anlass lag in den Nachbar-Repos, nicht hier.** Am 01.09.2026 landete
   zweimal an einem Tag ein Commit direkt auf `main`: `2ae46bc` in
   `growthkit-website`, `b14365c` in `supabase`. **Hier ist das seit dem
   PR-Workflow nicht passiert** — gemessen, nicht angenommen: alle 34 Commits auf
   `main` seit `13c2d12` (19.08.2026) sind Squash-Merges mit PR-Nummer, der letzte
   Direkt-Commit `8b4d26d` stammt vom 07.08.2026. Der Hook ist hier **Vorsorge,
   keine Reparatur**; in einem Repo, in dem `main` der Arbeitszweig ist, gehörte er
   nicht hin.

   Passiert es doch, in **genau dieser Reihenfolge**:

   ```bash
   git branch <name>              # ZUERST — rettet den Commit
   git reset --hard origin/main   # dann erst zurücksetzen
   git switch <name>
   ```

   ⚠️ **`reset` vor `branch` und der Commit ist weg.** `git reset --hard` bewegt
   `main` auf `origin/main`; danach zeigt keine Referenz mehr auf den Commit, er ist
   nur noch über `git reflog` erreichbar. `git branch` zuerst setzt eine Referenz,
   die ihn hält. Dieselbe Reihenfolge steht in der Meldung des Hooks — sie steht
   damit zweimal, und `tests/pre-commit.sh` vergleicht beide Stellen (§7a).
4. **Keine DDL, keine SQL-Migrationen, kein `apply_migration`, kein `deploy_edge_function`.**
   Schema-Änderungen gehören ins `supabase`-Repo und brauchen einen Menschen. Wenn eine
   Änderung hier eine DB-Änderung erfordert: als Vorschlagsdatei ausgeben und stoppen.
5. **`package.json` steuert den Install-Step im Workers Build.** Seit 19.08. existiert
   eines im Root (vorher bewusst keins). **Verifiziert:** Workers Builds fährt
   `npm clean-install` und `npx wrangler` greift danach auf die lokal gepinnte Version —
   der Production-Deploy-Pfad ist damit gepinnt. `.nvmrc` steuert die Node-Version im Build.
   Änderungen an `package.json`, `package-lock.json`, `.nvmrc` oder `wrangler.toml`
   trotzdem **nie direkt auf `main`** — immer erst als Preview-Version, Build-Log lesen.
6. **Kein blankes `npx` in Skripten oder CI.** `npx` löst `latest` auf und fragt bei
   fehlendem Paket interaktiv nach — in einer autonomen Session hängt das ohne Fehler.
   Werkzeuge kommen aus `devDependencies` über `npm run`. *(Beobachtet, 19.08.)*

### Discovery-Files — Sync-Invarianten

Single Source of Truth: `SERVER_NAME`, `SERVER_VERSION`, `PROTOCOL_VERSION`, `MCP_ENDPOINT`
sind Module-Level-Consts in `index.js`. **Beides** liest sie: die `initialize`-Response
**und** `/.well-known/mcp/server-card.json`.

7. **Diese vier Werte nie zweimal hardcoden.** Die Card fällt automatisch aus der Const.
   - **§7a — Eine abgeleitete Größe gehört an genau eine Stelle, auch in Prosa.**
     §7 verbietet doppeltes Hardcoden von Konstanten; für Zahlen und Positionsangaben in
     der Doku gilt dasselbe. Beleg, 24.08.: die §18a-Eröffnungszeile nannte „Acht", die
     Schlusszeile „dreizehn" — und es waren dreizehn Fälle. Die Zahl stand zweimal und ist
     gedriftet. `growthkit-website` und `supabase` hatten den Widerspruch **nicht**, und
     zwar **nicht** weil sie sorgfältiger gepflegt wären, sondern weil ihre
     Eröffnungszeile die Zahl **gar nicht nennt** — sie sind bauartbedingt immun.
     Dasselbe gilt für Positionsangaben: „bei den letzten beiden" war richtig, als (g)/(h)
     die letzten waren, und zeigte nach dem Anfügen von (i)–(m) auf zwei Fälle, die etwas
     anderes sagen.
     **Handgriff:** die Zahl **streichen statt korrigieren** — ein korrigierter Wert ist
     heute richtig und beim nächsten Eintrag wieder falsch. Einen Fall beim **Buchstaben**
     nennen statt bei der Position. Steht eine abgeleitete Größe unvermeidbar zweimal,
     braucht es eine Assertion, die beide vergleicht: sonst ist es eine
     Synchronisationspflicht, die keine Prüfliste zuverlässig abdeckt.

     ⚠️ **Nicht betroffen sind datierte Messbefunde und abgeschlossene historische
     Mengen.** Sie driften nicht — sie **veralten**, und das Datum sagt es. Das Kriterium
     ist nicht „Zahl oder nicht", sondern ob sie sich aus etwas anderem **ergibt**. Ohne
     diesen Absatz liest sich §7a als Verbot aller Zahlen, und beim nächsten Aufräumen
     fiele Richtiges. Stellen in dieser Datei, die ausdrücklich **bleiben** — die
     Aufzählung ist bewusst nicht abschließend, eine Anzahl wäre hier selbst eine
     abgeleitete Größe:
     „68 Tools für `admin`, 63 für `gk_team_`" und „30 von 68 Tools, davon 29 lesend"
     (beide *live verifiziert, 20.08.*) sowie „12 von 87" in §18a **(k)**
     (`growthkit-website`, 21.08.2026); dazu die Belegtabelle in **§17a** und die Zählung
     der Commit-Bodies in **§18b**. Diese Zahlen ergeben sich nicht — sie wurden
     **gemessen**.
     Umgekehrt gilt: eine Messzahl **ohne** Datum ist keine Ausnahme, sondern der
     Normalfall der Regel.
     *(Beobachtet, 24.08.)*
8. **`server.json`** (Registry-Publish): `name` / `version` / `description` müssen mit der
   Card übereinstimmen. Bei Version-Bump: (1) Const in `index.js`, (2) `server.json`,
   (3) ggf. Registry-Re-Publish.
9. **`tools`**: Card nutzt `"tools": "dynamic"` → kein Per-Tool-Sync. `tools/list` bleibt
   die einzige Quelle des tatsächlichen Tool-Sets.
10. **OAuth-Triplet** muss konsistent auf dieselbe Resource/AS zeigen:
    `/.well-known/oauth-protected-resource`, `/.well-known/oauth-authorization-server`,
    `authentication.resourceMetadata` in der Card. Ändern sich OAuth-Endpoints → alle drei.
11. Zwei Protokoll-Versionen — absichtlich verschieden, nie vereinheitlichen.
    PROTOCOL_VERSION (Const) ist die MCP-Kernprotokoll-Version und speist initialize
    und die server-card. ui/initialize (MCP-Apps/ext-apps) hat eine eigene, separate
    Version — sie ist ein bewusst eigenständiger Literal, kein vergessener Hardcode und
    keine Verletzung von Leitplanke 7. Fehlt oder stimmt sie nicht, schlägt der Client
    still fehl: keine Fehlermeldung, kein Log, nur „geht nicht". (Beobachtet.)
    Beide Werte gehören in den Golden Master, damit eine versehentliche Angleichung rot wird.

### Compliance — `place_call`

12. **Zwei Tools sind app-private:** `place_call` UND `save_call_outcome`, beide über
    `_meta.ui.visibility: ["app"]` (MCP-Apps / SEP-1865). Sie stehen in `tools/list`, aber
    der Host verbirgt sie vor dem Modell und proxied nur `tools/call` aus dem
    Lead-Call-Card-Iframe. Das Modell kann sie nie sehen oder aufrufen — human-initiated
    only, damit UWG § 7 erfüllt.
    **Dieses `_meta` ist compliance-tragend. Es zu verlieren bricht nichts sichtbar.**
    Nie entfernen, nie umbenennen, nie „aufräumen".
    Gegenstück: **`show_callable_leads` MUSS modell-sichtbar bleiben** — es rendert die
    Karte und trägt bewusst keine `visibility`, dafür `_meta.ui.resourceUri`. Nicht
    „der Konsistenz halber" app-private machen. `probe.sh` prüft alle drei.
13. `place_call` **nicht** aus `tools/list` weglassen. Der frühere Katalog-Hiding-Ansatz
    wurde verworfen: ein weggelassenes Tool kann vom Host als „unknown" abgelehnt werden,
    wenn das Iframe es aufruft.

### Auth & Scoping

14. **Token-Hash-Scoping, nicht User-ID-Scoping.** Notifications und alle
    empfänger-gebundenen Queries filtern auf `to_token_hash`. Ein Filter auf `to_user_id`
    liefert die Nachrichten aller Team-Mitglieder desselben Workspace aus. *(Beobachtet.)*
15. Bei Weitergabe von Tokens an n8n: **`Bearer `-Prefix explizit in den Value schreiben.**
    n8n Header-Auth übergibt den Wert verbatim und ergänzt nichts. *(Beobachtet.)*

### Styling & Cross-Repo

16. Für Cards / Komponenten / visuelle UI (Visual Cards, MCP-Apps HTML-Resources) ist die
    **`styles.css` im `chrome-extension`-Repo die visuelle Source of Truth** — die
    `vc-*`-Klassen (`vc-card`, `vc-card-header`, `vc-card-title`, `vc-card-body`,
    `vc-lead-*`, `vc-action`, …) und die Design-Tokens (`--gk-accent`, `--vc-bg`,
    `--vc-item-*`, …). Relevante Styles **inline** kopieren (kein Cross-Repo-Import — das
    MCP-Iframe hat keinen Zugriff auf `styles.css`), Klassennamen und Tokens spiegeln.
17. **`chrome-extension` ist Read-Only-Referenz — nie editieren.** Auch die Click-Handler
    **nicht** übernehmen: die Extension feuert `callout-call` direkt per `fetch`
    (`panel.js`); in MCP Apps muss der Click über die Host-Bridge → app-privates
    `place_call`. Struktur und Optik übernehmen, nicht das Verhalten.

### Arbeitsweise

18. **Kein Fix ohne reproduzierenden, vorher failenden Test.** Wenn du nicht reproduzieren
    kannst: eskalieren, nicht raten. Plausibel aussehende Änderungen an Code, der nicht der
    Verursacher war, sind die teuerste Fehlerklasse.
    **Die Umkehrung ist die Abnahmebedingung, keine Empfehlung: jede neue Assertion muss
    vor dem Commit absichtlich rot gefahren worden sein.** Eine Prüfung, die nie rot war,
    ist ungeprüft, nicht grün. Dieser Satz stand bis zum 27.08.2026 in keiner Zeile dieser
    Datei — §18a zählt seit dem 20.08. die Fehlerklassen auf, die beim Falsifizieren
    auffallen, und **setzt die Pflicht dazu nur voraus**. Wie der rote Lauf festgehalten
    wird, steht als **§18b**.
    - **§18a — Eine Assertion ohne roten Lauf gilt als nicht verifiziert.** Die unten
      aufgeführten Fehlerklassen produzieren grüne Tests, die nichts prüfen. Der
      Mechanismus ist meist derselbe — **Abwesenheit wird als Bestehen gelesen**;
      **(g)** dreht die Richtung um: **ein roter Lauf belegt nicht, was er zu belegen
      scheint.** *(Weder Anzahl noch Position hier wiederholen — §7a.)*
      (a) eine Prüfung „keine Verstöße" über einer leeren Liste ist immer grün — jede
      Iteration über eine Liste braucht daher zusätzlich eine Prüfung, dass die Liste
      nicht leer ist; (b) in `jq` rebindet `|` das `.`, sodass `$d | contains(.)` zu
      `$d contains $d` wird und immer wahr ist — Werte vor dem Vergleich mit `. as $e`
      binden; (c) ein Vergleich gegen einen Wert, der bei fehlender Quelle leer ist,
      besteht immer — die **Existenz der Quelle** muss eigenständig geprüft werden.
      Belege für (c): ein fehlendes `index.js` gab in `probe.sh` nur eine Notiz aus und
      blieb grün; ein umbenanntes `const PROTOCOL_VERSION` lieferte `""` und war damit
      gegen jeden Vergleich mit dem ext-apps-Wert grün.
      (d) **invertiert-leer-wahr** — eine zu breite Regel macht *alle* Positivprüfungen
      grün, und die Assertion prüft dann nur noch, **dass** etwas gilt, nicht dass das
      **Richtige** gilt. Jede Positivliste braucht deshalb eine Gegenrichtung. Beleg:
      ein `*` in `.gitignore` hätte alle „ist ignoriert"-Prüfungen bestanden; erst die
      Negativkontrolle („diese Kerndateien dürfen NICHT ignoriert sein") fängt es.
      (e) **Arbeitsbaum-Zustand ist in CI immer grün**, weil `actions/checkout` einen
      sauberen Baum liefert — `git status --porcelain` ist dort stets leer. Prüfbar ist
      nur, was eine **Funktion des Commits** ist. Beleg: „keine untracked
      Build-Artefakte" wäre nie rot geworden; die prüfbare Invariante ist stattdessen,
      dass die betreffenden Pfade *ignoriert* sind.
      (f) **Ein Werkzeug konsultiert still eine andere Quelle als angenommen**, und das
      Ergebnis ist plausibel und falsch. Beleg: `git check-ignore` wertet ohne
      `--no-index` den **Index** mit aus und meldet jede getrackte Datei als „nicht
      ignoriert" — unabhängig von den Regeln. Die Negativkontrolle aus (d) blieb damit
      grün, weil die Kerndateien getrackt sind: sie prüfte den Tracking-Status statt
      der Regel. Diese Klasse ist nicht auf `check-ignore` beschränkt; das ist nur das
      Beispiel.
      (g) **Eine Falsifikation kann aus dem falschen Grund gelingen.** Der rote Lauf
      muss aus **dem** Grund rot sein, für den die Assertion gebaut wurde — sonst ist
      er dieselbe Sorte Scheinsicherheit wie ein grüner Test, der nichts prüft, nur
      mit umgekehrtem Vorzeichen. Drei Belege an zwei Tagen: ein `sed`-Muster mit
      sechs Leerzeichen dort, wo eines steht, injizierte **nichts** — der Lauf blieb
      grün und sah aus wie ein Test, der den Fehler nicht fängt (#14); ein
      `grep`-Injektionscheck traf eine **Kommentarzeile** statt des Codes, mit
      demselben Ergebnis (#17); und die Skript-Kopie im temporären Testverzeichnis
      war die Fassung **vor** der Änderung, sodass der neue Zweig fälschlich stumm
      blieb (#19). Daraus zwei Handgriffe: nach dem Injizieren die geänderte Zeile
      **ausgeben**, nicht dem Ersetzungsbefehl vertrauen — und vor dem Lauf prüfen,
      dass der **Prüfling der ist, den man zu prüfen glaubt**.
      (h) **Eine Prüfung, die eine Umgebungseigenschaft der Testmaschine voraussetzt,
      ist auf einer anderen wirkungslos — und meldet grün.** Beleg: der Fall „`jq`
      fehlt" wurde zunächst über `PATH=/usr/bin:/bin` gebaut. Lokal liegt `jq` in
      `~/.local/bin`, der Fall war also korrekt; auf dem Runner liegt es in
      `/usr/bin` — dort wäre `jq` weiterhin erreichbar gewesen, der Fall hätte nichts
      geprüft, und der Lauf wäre grün gewesen. Die Lösung ist, die Eigenschaft
      **herzustellen statt sie vorauszusetzen**: ein Verzeichnis mit genau den
      benötigten Werkzeugen, ohne das fehlende. Verwandt mit (e), aber anderer
      Gegenstand — dort der Checkout-Zustand, hier Werkzeugpfade.
      (i) **Ein Abnahmekriterium kann den falschen Mechanismus unterstellen. Es scheitert
      dann nicht — es passt nicht.** Die anderen acht produzieren ein falsches Signal:
      (c) und (h) ein falsches Grün, (g) ein falsches Rot. Dieser Fall produziert **gar
      keins**. Das Kriterium ist wohlgeformt und wäre schlüssig, *wenn* der Mechanismus
      der unterstellte wäre; ist er es nicht, tritt weder Bestehen noch Scheitern ein.
      Übrig bleibt eine Nicht-Beobachtung, die wie „noch nicht geprüft" aussieht — und
      genau deshalb zur Wiederholung einlädt. **Wer wiederholt, sammelt keine Evidenz,
      sondern dieselbe Nicht-Beobachtung.**
      Beleg, 21.08.2026 in `supabase`: das Abnahmekriterium für einen `deny` auf ein
      MCP-Tool lautete „ein Aufruf muss abgelehnt werden — die Ablehnung ist der Beleg".
      Es unterstellt Ablehnung zur **Aufrufzeit**. Beobachtet wurde stattdessen, dass das
      Tool gar nicht erst im aufrufbaren Satz erscheint; eine Ablehnung kann dann nie
      eintreten. Zwei Anläufe an verschiedenen Tagen lieferten dieselbe Leerstelle. Der
      Ausweg ist **nicht**, es erneut zu versuchen, sondern es umzuformulieren.
      (j) **Index und Commit laufen auseinander — geprüft gehört der Commit.**
      `git add --chmod=+x` setzt den Modus im **Index**. Die pfadbegrenzte Form
      `git commit -- <pfad>` liest jedoch den **Arbeitsbaum** und verwirft ihn dabei. Mit
      `core.fileMode = false` ist der Arbeitsbaum-Modus bedeutungslos, also landet
      `100644` im Commit, während der Index `100755` zeigt.
      Beleg, 21.08.2026 in `growthkit-website`: alle sechs Skripte jenes Harness waren
      davon betroffen. Die Exec-Bit-Assertion war dabei **grün** — sie las
      `git ls-files -s`, also den Index, und der war richtig. Ausgeliefert wird der
      Commit. Verwandt mit (e), aber schärfer: dort ist der Arbeitsbaum in CI *immer
      sauber*, hier ist der Index *lokal etwas anderes als HEAD*.
      **Jede Assertion über Datei-Metadaten muss `git ls-tree HEAD` lesen, nicht nur den
      Index.** Betrifft auch den `CLAUDE.md`-Symlink (Modus `120000`).
      (k) **Eine Positivprüfung über einer zu kleinen Grundmenge ist derselbe Fehler wie
      über einer leeren — nur schwerer zu sehen, weil die Zahl nicht null ist.**
      (a) fängt den Fall „Liste leer". Nicht gefangen wird „Liste enthält 12 von 87
      Elementen".
      Beleg, 21.08.2026 in `growthkit-website`: die Emit-Kollisionsprüfung iterierte über
      `"$DIST"/*.html` und sah damit nur die **12 Dateien der obersten Ebene**; die
      übrigen 75 liegen in Unterverzeichnissen. Sie fand 10 Paare, meldete „alle 10
      byte-identisch" und war grün — 77 Paare waren nie geprüft. Der Nicht-Leer-Guard
      hatte gegriffen und trotzdem nichts gesagt. **Neben „ist die Menge nicht leer?"
      gehört „ist sie so groß, wie sie sein müsste?" geprüft** — gegen eine unabhängig
      ermittelte Zahl, nicht gegen sich selbst.
      (l) **Eine Messung am gemeinsamen Objekt zweier Ereignisse kann die Ereignisse
      nicht unterscheiden.** Verwandt mit (k), aber eigenständig: dort ist die Grundmenge
      zu klein, hier ist sie richtig und die **Auflösung des beobachteten Objekts**
      falsch. Zwei Ereignisse hinterlassen ihre Spur am selben Ding, und die Spur trägt
      kein Merkmal, das sie trennt.
      Beleg, 23.08.2026 in `growthkit-website`: Der erste Rückmerge lief als
      **Fast-Forward**, zwei Branches zeigen danach auf denselben Commit. Check-Runs
      hängen aber am **SHA**, nicht am Branch. Die dort sichtbaren Einträge stammen vom
      einen Push — und wären exakt dieselben, wenn der andere zusätzlich welche erzeugt
      hätte. Die Frage „hat dieser Push etwas ausgelöst?" ist an diesem Objekt **nicht
      entscheidbar**, egal wie genau man hinsieht.
      Zwei Auswege, beide brauchen einen Schritt **vor** der Messung: an etwas messen,
      das die unterscheidende Dimension trägt — oder einen Zustand herstellen, in dem die
      Objekte verschieden sind.
      ⚠️ Der praktische Teil: **die richtige Quelle steht oft in einem ANDEREN SYSTEM als
      die falsche.** „Hat der Push einen Actions-Lauf ausgelöst?" beantwortet nicht der
      Check-Run am Commit, sondern die **Run-Liste** (`head_branch` + `event`); „hat der
      Push einen Preview gebaut?" nicht GitHub, sondern das **Dashboard des bauenden
      Systems** — für dieses Repo also Cloudflare, wo Workers Builds nur Check-Runs
      anlegt und die Deployments-API leer bleibt. Daraus die Handregel: **wenn die
      naheliegende Quelle nicht trennen kann, ist die Frage nicht unbeantwortbar —
      sondern am falschen Ort gestellt.**
      (m) **Eine leere Antwort unterscheidet nicht zwischen „es gibt nichts" und „es gibt
      noch nichts".** Eine Messung, die vor dem Ereignis stattfindet, kann es nicht sehen,
      und das Ergebnis liest sich wie ein Negativbefund statt wie ein zu früher Blick.
      Beleg, 24.08.2026: `gh pr checks --watch` kehrte **sofort** mit „no checks reported"
      zurück, weil die Runs nach einem `update-branch` noch nicht angelegt waren.
      Abgrenzung, und sie trägt die Klasse: gegen (c) fehlt die Quelle dort *dauerhaft*,
      hier existiert sie und ist nur noch nicht befüllt; gegen (l) ist die Frage dort
      *nie* entscheidbar, hier wird sie es durch bloßes Warten. Das macht (m)
      **gefährlicher als beide**, weil ein Neuversuch sie scheinbar behebt — es sieht nach
      Flakiness aus statt nach Methodenfehler, und dann sucht niemand weiter.
      ⚠️ Der Prüfort, an dem die Klasse sofort etwas wert ist: **überall, wo auf einen
      externen Zustand gewartet wird, gehört „ist die Liste nicht leer?" VOR „sind alle
      grün?".** Derselbe Nicht-Leer-Guard wie in (a) und (k), nur auf eine
      **Wartebedingung** statt auf eine Assertion angewandt.
      **In diesem Repo gibt es genau so eine Stelle, und sie ist richtig gebaut:** der
      `wait`-Step in `.github/workflows/ci.yml` schließt aus einer leeren Check-Run-Liste
      **nicht sofort** auf „kein Workers Build", sondern erst nach acht Runden. Seine
      dokumentierte Begründung nennt allerdings die Build-Watch-Excludes — nicht die
      Race. Zwei Gründe für dieselbe Schleife; der zweite steht bisher nur hier.
      Alle dreizehn fallen beim Lesen nicht auf, nur beim Falsifizieren.
      *(a–h beobachtet 20.–21.08.2026 hier; i am 21.08. in `supabase`; j und k am 21.08.
      sowie l am 23.08. in `growthkit-website`, von dort am 24.08. zurückportiert;
      m am 24.08.)*
19. **Tool-Schema-Änderungen nur mit Golden-Master-Update im selben Commit.** Wenn das
    Golden abweicht und du die Änderung nicht bewusst gemacht hast, ist **die Änderung der
    Bug** — nicht das Golden-File. Golden nie „reparieren", damit CI grün wird.
20. Neues Tool = `tools/list`-Eintrag **und** vollständiges `inputSchema` **und**
    Golden-Update. Alle drei, sonst gar nicht.
21. **Vollständigkeitschecks per Repo-Grep, nicht per Sampling.** Beim
    `campaign_leads`-Umbau hat Suche nach Funktionsnamen zwei Write-Pfade übersehen.
    Autoritativ war `grep -rn "\.from('<table>')"` kombiniert mit `.update/.insert/.upsert`.
    **Ein solcher Grep ist ein Messinstrument**, und ein unkalibriertes liefert eine Zahl,
    die *aussieht* wie ein Befund. Der Handgriff dazu steht als **§17a** — die Regel, an
    der er hängt, ist diese hier, nicht die gleichnamige Nummer 17.
    *(Beobachtet.)*
22. **`str_replace`-Hunks statt File-Rewrites.** Bei dieser Dateigröße ohne Modulschnitt
    ist ein Full-Rewrite nicht reviewbar.
23. Tests liegen unter `tests/`. Änderungen dort gehören in einen **separaten Commit** mit
    Begründung im Body. Test und Fix im selben Commit ist ein Warnsignal.

### §17a — Der bekannte Treffer: jede Messung braucht einen Fall, dessen Ergebnis vorher feststeht.

*(Übernommen aus `growthkit-website`, 27.08.2026. Der Name bleibt `§17a`, damit Verweise über
alle Repos hinweg gültig bleiben — wie bei `§7a` und `§18a`. **Er hängt hier an einer anderen
Regel:** dort ist §17 „jede Zählung ist eine Messung", hier ist 17 die
`chrome-extension`-Leseregel. Zuständig ist **Leitplanke 21**. Eigener Abschnitt statt
eingerücktem Unterpunkt wie §7a/§18a, weil Tabelle und Codeblöcke auf einer Listenebene nicht
lesbar sind.)*

**Ein kaputtes Instrument und ein echter Negativbefund liefern dieselbe Ausgabe.** „0
Treffer" ist ohne einen vorher benannten Treffer nicht von „es gibt nichts" zu
unterscheiden — und die Null liest sich wie ein Befund, weil sie eine Zahl ist.

Das ist kein weiterer §18a-Fall, sondern ein Schritt **davor**. §18a fragt, ob eine
**Assertion** je rot war. §17a fragt, ob die **Messung** überhaupt messen kann. Eine
Assertion ohne roten Lauf ist *unverifiziert*; eine Messung ohne bekannten Treffer ist
*unbrauchbar* — und gefährlicher, weil sie ein Ergebnis ausgibt, das man weiterverwendet.

**Der Handgriff, vier Schritte:**

1. **Vor** dem Zählen einen Fall benennen, der im Ergebnis **auftauchen muss** — und ihn
   hinschreiben, nicht nur denken.
2. Messen.
3. **Fehlt der bekannte Treffer, ist das Instrument kaputt.** Nicht berichten. Reparieren,
   neu messen.
4. Gibt es keinen Fall mit vorher bekanntem Ergebnis, gehört **das** in den Bericht — statt
   einer Zahl, die so aussieht, als sei sie geprüft.

⚠️ **Der bekannte Treffer muss unabhängig vom Instrument sein.** Wer die Erwartung aus
demselben `grep` ableitet, mit dem er misst, hat nichts kalibriert, sondern das Instrument
mit sich selbst verglichen.

⚠️ **Die Plausibilität der Zahl ist kein Ersatz.** Fast alle Belege unten sahen plausibel
aus. Aufgefallen sind sie an einer Unstimmigkeit, die es auch nicht hätte geben müssen —
„0 von 68" bei einer Seite, von der bekannt war, dass sie funktioniert.

**Belege, 26.–27.08.2026, alle in `growthkit-website`** — sechs Fälle aus zwei Tagen:

| Instrument | Ausgabe, die wie ein Befund aussah | tatsächlich |
|---|---|---|
| `grep hreflang` case-sensitiv | „0 von 68 Seiten tragen hreflang" | react-helmet schreibt `hrefLang`; alle 68 korrekt |
| Chunk-Suche nur über die Eager-Chunks | „`gk_src` in keinem Chunk" | im lazy geladenen `signup-cta`-Chunk. **Zweimal aufgetreten**, an beiden Enden desselben PR |
| zsh-Schleifenvariable `path` | „33 von 33 Abweichungen" | `path` ist an `PATH` gebunden; `curl` war nach der ersten Zeile nicht mehr auffindbar |
| Marker-`grep` über deutsche Prosa | „`tsconfig-scopes`: 0 Belege" | die Musterliste war zu eng |
| `awk` mit Kommentarpuffer | „alle 17 Suiten: 0 Inline-Belege" | der Puffer wurde an der `if`-Zeile geleert, bevor das `ok` kam |
| `grep gk_notrack` im aufrufenden Modul | „FEHLT" | die Funktion ist im *definierenden* Modul; der Aufrufer trägt nur den Call |

Drei davon lohnen die Ausführung:

**(a) Die zsh-Variable ist der klarste Fall, weil das Instrument sich selbst zerstört hat.**
Eine Prüfschleife las Pfade in die Variable `path`. In zsh ist `path` an `PATH` gebunden —
mit der ersten gelesenen Zeile war `PATH` überschrieben und `curl` nicht mehr auffindbar.
Ergebnis: 33 von 33 Richtungen „abweichend", keine davon echt. Gefangen **nur**, weil 33 von
33 unplausibel ist. Bei drei Abweichungen hätte man am falschen Objekt gesucht, mit einem
Ergebnis, das dort nichts erklärt hätte. Der Merkposten gilt überall, wo die Shell zsh ist,
also auf dieser Maschine auch hier: `path`, `cdpath`, `fpath`, `manpath` sind **keine freien
Variablennamen**.

**(b) Die Chunk-Messung ist die lehrreichste, weil sie zweimal passiert ist** — an beiden
Enden desselben Vorgangs. Gemessen wurden die Chunks, die eine HTML referenziert; das sind
die Eager-Chunks, und der gesuchte Code lag in einem lazy nachgeladenen. Beide Male lautete
die Schlussfolgerung „der Code ist nicht im Bundle", beide Male war er es. Der bekannte
Treffer hätte nichts gekostet: eine Datei nennen, von der feststeht, dass ihr Inhalt drin
sein **muss**.

**(c) Der `awk`-Puffer ist der unheimlichste, weil das Ergebnis perfekt gleichmäßig war.**
Alle 17 Suiten meldeten null Inline-Belege. Eine Null in *jeder* Zeile sieht nach einer
Eigenschaft der Grundmenge aus, nicht nach einem Fehler im Werkzeug. Gefangen nur, weil für
eine der 17 der Erwartungswert bekannt war — sie war am selben Tag geschrieben worden.

**Zwei hiesige Fälle, beide an dieser Datei — die Klasse ist nicht importiert:**

- **Der Abgleich-Abschnitt trägt einen §17a-Befund, ohne ihn so zu nennen:** „Ein Grep über
  drei Repos misst drei Formatierungen, nicht eine." Am 24.08. hat dieselbe Prüfung dreimal
  „fehlt" gemeldet, jedes Mal falsch. Dort steht der Befund, hier die Regel — bewusst nicht
  beides an beiden Stellen (§7a).
- **Bei der Erhebung zu §18b, 27.08.2026.** Gezählt werden sollte, in wie vielen
  Commit-Bodies die Notation steht. `grep -c '^FALSIFIZIERT'` über die Commit-Bodies auf
  `main` findet **zwei weniger** als die Zählung in §18b: `7187c66` und `13c2d12` schreiben
  „Falsifiziert:", und case-sensitiv sieht der Grep sie nicht. Gefangen, weil `7187c66`
  **vorher** als bekannter Treffer benannt und von Hand gelesen worden war — nicht mit
  demselben Grep. Ohne ihn wäre die kleinere Zahl in diese Datei gegangen, und sie hätte
  ausgesehen wie ein Befund.

⚠️ Der Anwendungsbereich ist **die Untersuchung, nicht der Code**. Die meisten dieser Fälle
sind in einer Erhebung entstanden, nicht in einer eingecheckten Assertion — sie hätten
keinen Test rot gemacht, sondern einen Bericht falsch. Für Assertionen im Repo greift
zusätzlich §18a; der Nicht-Leer-Guard aus §18a **(a)** ist die eingecheckte Fassung desselben
Gedankens, und §18a **(k)** — „zu kleine Grundmenge" — ist der Chunk-Fall in Assertionsform.

*(Die Fremdbelege beobachtet 26.–27.08.2026 in `growthkit-website`; die beiden hiesigen
Fälle am 24. und 27.08. hier. Übertragen am 27.08.2026 — siehe „Abgleich".)*

### §18b — Wie ein roter Lauf festgehalten wird. Die Notation.

*(**Teil 1 ist hier entstanden** und stand seit dem 19.08.2026 nur in Commit-Bodies, nie in
dieser Datei; `growthkit-website` hat ihn am 27.08. aufgeschrieben und gibt ihn damit
zurück. **Teil 2 und Teil 3** sind dort entstanden und hier neu. Eigener Abschnitt statt
eingerücktem Unterpunkt unter 18 — aus demselben Grund wie bei §17a.)*

Die **Pflicht** steht bei Leitplanke 18: jede neue Assertion muss vor dem Commit absichtlich
rot gefahren worden sein. Sie sagt nicht, **wie** man das festhält.

**Der Beleg gehört in die Commit-Message, nicht in die PR-Beschreibung.** Die Commit-Message
wandert mit dem Commit, übersteht Rebase und Squash und ist über `git log` auffindbar, ohne
dass jemand GitHub befragen muss. Wie nötig das ist, zeigt `supabase`, hier nachgezählt am
27.08.2026: **zehn Commits fassen dort `tests/` an, keiner trägt einen Body** — nur Titel
und `Co-authored-by`, über vier Suiten hinweg. Die Falsifikationen sind, falls sie
stattfanden, nicht mehr auffindbar.

#### Zuerst: der Rückweg — vor der ersten Injektion, nicht danach

**Sicherung anlegen, bevor injiziert wird. Zurückgestellt wird aus der Sicherung.**

```bash
cp <datei> "$SCRATCH/<datei>.backup"   # VOR der ersten Injektion
…injizieren, prüfen…
cp "$SCRATCH/<datei>.backup" <datei>   # zurückstellen
```

⚠️ **`git checkout -- <datei>` ist der falsche Rückweg, sobald die Arbeit noch nicht im
Commit steht** — und das ist bei einer Falsifikation der Normalfall, weil man gerade das
baut, was man prüft. Der Grund ist nicht Geschmackssache, sondern die Semantik. Am
30.08.2026 an einem Wegwerf-Repo gemessen, alle drei Fälle:

| Zustand der Arbeit | Rückweg | Ergebnis |
|---|---|---|
| nur im Arbeitsbaum, ungestagt | `git checkout -- f` | **Arbeit weg** — auf HEAD zurück |
| gestagt (`git add`) | `git checkout -- f` | Arbeit **überlebt**, sie kommt aus dem Index |
| gestagt | `git checkout HEAD -- f` | **Arbeit weg**, Index eingeschlossen |

`git checkout -- <datei>` stellt aus dem **Index** her, nicht aus HEAD. Es ist damit genau
dann richtig, wenn die eigene Arbeit im Index liegt, und genau dann zerstörerisch, wenn sie
nur im Arbeitsbaum steht. **Wer sich das im Moment der Injektion merken muss, merkt es sich
nicht** — die Sicherung nimmt die Frage weg.

⚠️ **Der Schaden ist stumm.** Die verlorene Arbeit macht nichts rot: die Suite läuft danach
mit einer Assertion weniger weiter und meldet grün. Am 29.08. hier so passiert — 13 statt 14
grün, ohne ein einziges rotes Zeichen; am 30.08. noch einmal, diesmal an einer Datei, die
ein Vorcommit gerade sauber gemacht hatte, sodass die beiden Folgeproben gegen einen
verunreinigten Prüfling liefen und Verstöße mitmeldeten, die es nicht mehr geben sollte.

⚠️ **Und der Grund, aus dem das hier als Handgriff steht und nicht als Warnung:** die Regel
stand nach dem ersten Mal in einem Commit-Body — und ist am nächsten Tag ein zweites Mal
eingetreten. Aufgeschrieben zu haben reicht nicht, weil der Handgriff **vor** die erste
Injektion gehört und die Nachbereitung der Moment ist, in dem man nicht nachliest. Deshalb
steht er hier **vor Teil 1** und nicht bei Teil 3.

#### Teil 1 — Der Block

Vorlage, wörtlich aus `993ef19` (20.08.2026):

```
FALSIFIZIERT, sechs Bruchstellen einzeln, jedes Mal mit vorheriger Pruefung ob
die Injektion gelandet ist:
  * chmod=-x auf report-tools.sh      -> Exec-Bit rot (100644 gemeldet)
  * Pathspec ohne Treffer             -> Nicht-Leer-Guard rot
  * .wrangler/ aus .gitignore         -> Positivrichtung rot
  * `*` in .gitignore                 -> Negativkontrolle rot (4 Dateien genannt)
  * git add -f fake-deploy.pem        -> Secret-Assertion rot
  * Lauf ausserhalb eines Repos       -> ko, nicht stiller Skip
Danach zurueckgesetzt: 10 gruen, 0 rot. probe.sh unveraendert bei 30 — der
delegierte Aufruf zaehlt dort als EIN Eintrag.
```

Die Schlusszeile zu `probe.sh` ist repo-eigene Zugabe (sie hängt an der Delegationszählung
aus „Bekannte Fallen"), kein viertes Pflichtelement. Verbindlich sind drei:

1. **Was injiziert wurde** — konkret genug, dass es jemand nachbauen kann. „Fehler
   eingebaut" ist keine Injektion, sondern eine Behauptung.
2. **Welche Assertion rot wurde** — namentlich, nicht „der Test". Ohne das ist nicht belegt,
   dass die Injektion vom **richtigen** Wächter gefangen wurde; ein roter Lauf aus einem
   anderen Grund sieht genauso aus (§18a **(g)**).
3. **Die Rückstellung mit der Zahl danach.** Sie belegt zugleich, dass kein Rest der
   Injektion im Commit gelandet ist.

**Gemessen am 27.08.2026:** die Notation steht in **acht** Commit-Bodies auf `main`, vom
ersten Harness-Commit `13c2d12` (19.08.) bis `4b96ee1` (24.08.) — gelebte Praxis, seit es
das Harness gibt, und trotzdem nie aufgeschrieben. Drei weitere Bodies tragen dieselben drei
Elemente unter anderer Überschrift (`ad343a1`, `fb14903`, `5f31850`: „VERIFIZIERT, alle
Zustände einzeln", „DIESER COMMIT IST ROT, mit Absicht: 25 gruen, 1 rot").

⚠️ **Die Überschrift ist ab jetzt `FALSIFIZIERT`**, groß und am Zeilenanfang — nicht aus
Formalismus: eine Notation, die man nicht greppen kann, wird im nächsten Repo als „fehlt"
gemessen. Genau das ist oben in §17a passiert, und der Abgleich-Abschnitt sagt dasselbe über
drei Schreibweisen von `(m)`.

#### Teil 2 — Die Gegenprobe

**Neu für dieses Repo.** Ein Lauf, der rot wird, belegt nur, dass **irgendetwas** prüft —
erst ein Lauf, der grün bleiben **muss**, trennt einen Sensor von einer Rechtschreibprüfung.
Sie steht als eigener Block neben der Injektionsliste; Form wörtlich aus
`growthkit-website`, 27.08.2026:

```
GEGENPROBE, muss gruen bleiben:
  * Reihenfolge der vier Parameter umgedreht -> 24 passed, 0 failed
```

**Warum das hier trägt.** Zwei Prüfungen dieses Repos vergleichen **Mengen**: Sektion G von
`scripts/probe.sh` (Golden Master gegen `tools/list` — Namen, Property-Keys, `required`,
`_meta`) und die Rollen-Map-Assertion in `tests/source-invariants.sh`
(`toolRoleMap` ≡ `toolPermissions`). Eine Mengenvergleichs-Assertion, die nur gegen
Verstöße gefahren wurde, kann **zu breit** sein: sie wäre bei jeder harmlosen Umformatierung
rot. Und dann greift Leitplanke 19 genau falsch herum — dort steht „Golden nie reparieren,
damit CI grün wird", und ein Golden, das dreimal grundlos rot war, wird beim vierten Mal
repariert. **Die Gegenprobe ist der Schutz für Leitplanke 19, nicht Zierde.**

Dass die Klasse real ist, ist drüben belegt (27.08.2026): die Gegenprobe „`href` vor
`hreflang`" — semantisch identisches XML — machte `route-parity` rot. Nicht die Assertion
war zu breit, sondern der Leser reihenfolgeabhängig; er meldete „de fehlt" für alle 64
gepaarten Seiten einer vollständig korrekten Sitemap. **Ohne die Gegenprobe wäre das erst
aufgefallen, wenn jemand die Sitemap einmal anders herum geschrieben hätte.**

#### Teil 3 — Die Trefferzahl

**Jede Injektion meldet, wie viele Stellen sie geändert hat. Eine Zahl unter 1 macht die
Probe ROT.**

Ohne das ist eine nicht gelandete Injektion mit grünem Lauf danach nicht von einer
bestandenen Probe zu unterscheiden — beide sehen aus wie „geprüft".

**Hier ist der Fall zweimal eingetreten und beide Male nur als Prosa festgehalten worden:**

- `80cc064`, 20.08.2026: *„Beim ersten F3-Versuch feuerte nichts — die Injektion war nicht
  gelandet (Regex erwartete sechs Leerzeichen, wo eines steht)."*
- `ad343a1`, 21.08.2026: derselbe Mechanismus beim Guard-Selbsttest — der
  `grep`-Injektionscheck traf eine **Kommentarzeile** statt des Codes. Beides steht als
  §18a **(g)** in dieser Datei, aber als **Fehlerklasse**, nicht als Handgriff.

Eine Woche später ist `growthkit-website` in dieselbe Lücke gelaufen: eine Gegenprobe suchte
`/>`, die Sitemap schreibt ` />`. Null Treffer, Lauf grün, nichts belegt — und es war nicht
aufgefallen, bis die Zählung eingebaut war. **Zwei Repos, dreimal dieselbe Lücke, dreimal
nur Prosa. Deshalb ist die Trefferzahl ab jetzt Pflichtangabe.**

Zwei Formen:

- **Von Hand injiziert** — der Normalfall hier: nach dem Injizieren die geänderte Zeile
  **ausgeben**, nicht dem Ersetzungsbefehl glauben (§18a **(g)**), und die Trefferzahl
  mitnennen.
- **Mechanisiert als Probe in einer Suite:** die Mutation gibt ihre Trefferzahl zurück, und
  die Suite wird bei `< 1` rot statt grün. So gebaut **nur** in `growthkit-website`
  (`tests/route-parity.sh` Abschnitt D); in diesem Repo gibt es die mechanisierte Form
  nicht. Das ist eine Feststellung, kein Auftrag — wer sie baut, tut es als eigenen Vorgang
  mit eigener Verifikation.

#### Wann der Block durch einen Verweis ersetzt wird

Bei **tabellengetriebenen Suiten** steht der Negativfall dauerhaft im Test selbst. In diesem
Repo gibt es dafür zwei Stellen:

- **`tests/guard-push.sh`, Abschnitt F — „Selbstpruefung des Tests".** Er prüft, dass die
  Fallliste nicht leer ist, dass **alle 13 Entscheidungszweige** des Guards getroffen wurden
  und dass **beide Ausgänge** (`allow` über `feature-push`, `deny` über `protected-named`)
  im selben Lauf vorkamen. Ein Guard, der immer dasselbe sagt, wäre sonst von einem
  funktionierenden nicht zu unterscheiden.
- **`tests/source-invariants.sh`, Abschnitt „Repo-Hygiene".** Die **Negativkontrolle**
  „diese Kerndateien dürfen NICHT ignoriert sein" steht dauerhaft neben der Positivliste,
  samt `--no-index` — die eingecheckte Antwort auf §18a **(d)** und **(f)**.

Dort tritt an die Stelle der Injektionsliste ein **Verweis auf die Stelle in der Suite**.
Das ist die **stärkere** Form, nicht die bequemere: sie wird bei jedem Lauf neu bewiesen,
statt einmal behauptet worden zu sein.

⚠️ **Keine Ausrede.** Der Verweis gilt nur, wo der Negativfall **tatsächlich** in der Suite
steht. „Die Suite prüft ja beide Richtungen" ohne eine benennbare Zeile ist genau die
Behauptung, gegen die §18a gerichtet ist. Gegenbeispiel im selben Verzeichnis:
`tests/auth-paths.sh` fährt für die Auth-Grenze **nur Negativfälle** — der Positivfall
braucht ein echtes `gk_`-Token und bleibt manuell. Dort ersetzt der Verweis den Block
**nicht**.

*(Teil 1 hier entstanden, seit 19.08.2026 gelebte Praxis, am 27.08. aus
`growthkit-website` zurückgeholt und aufgeschrieben. Teil 2 und 3 dort entstanden,
27.08.2026. In `supabase` fehlt beides — siehe „Abgleich".)*

---

## Feedback

- **CI ist das maßgebliche Signal**, nicht deine Einschätzung. „Sieht korrekt aus" zählt nicht.
- **Rot = Stopp.** Nicht umgehen, nicht den Test anpassen.
- Bei rotem Build: **erst Ursache benennen, dann fixen.** Kein Fix-Versuch vor Diagnose.
- `./scripts/probe.sh <preview-url>` muss grün sein, bevor du einen PR öffnest.
- Nach drei erfolglosen Iterationen: stoppen, Zustandsbericht schreiben, eskalieren.

---

## Bekannte Fallen dieser Codebasis

- `index.js` hat **keinen Modulschnitt**. Änderungen an einer Tool-Implementierung können
  Shared Helper betreffen, die andere Tools nutzen. Vor jeder Änderung: Aufrufer greppen.
- Der Stateless-HTTP-Teil der MCP-Revision **2026-07-28** ist **additiv** geplant, kein
  Rewrite: bestehende Handshake-Pfade bleiben funktionsfähig. *(Diese Zeile sagte bis zum
  29.08.2026 „RC" — die Revision ist seit dem 28.07.2026 final.)* **Welche Methoden dafür
  fehlen und welche noch da sind, steht als `MIGRATION_MARKERS` in
  `tests/source-invariants.sh` und nirgends sonst** — hier stünde es als Prosa und
  veraltete still. Die Entscheidung, wann umgebaut wird, steht unter „Bewusst
  zurückgestellt".

- **`growthkit-mcp-demo` baut aus diesem Repo, deployt aber nicht `index.js`.** Sein Root
  directory ist `/mcp-directory-shim`; ausgeliefert wird der Shim. Zwei Folgen: die
  `probe.sh`-Assertions gelten für ihn **nicht**, und eine Änderung an `index.js`
  verändert sein Deployable **nicht** — auch wenn sein Build grün danebensteht. Sein
  Include-Watch-Path ist trotzdem `*`, er baut also bei jeder `index.js`-Änderung mit,
  ohne dass sich etwas an ihm ändert; belegt am Merge-Commit `5be0777`, der beide Worker
  gebaut hat. `mcp-directory-shim/**` wäre der richtige Include-Path — **nicht nebenbei
  ändern**, eine Include-Path-Änderung ist ein eigener Vorgang mit eigener Verifikation.
  Der `wait`-Step in `ci.yml` matcht deshalb exakt auf `Workers Builds: growthkit-mcp`;
  ein Teilstring-Match würde den Shim-Build als „Build vorhanden" zählen.
  *(Beobachtet, 20.08.)*

- **Zwei Repräsentationen derselben Domain** in `supabase`,
  `functions/weekly-seo-report/index.ts`: ein **Slug** (Bindestriche) und ein **Label**
  (Punkte). Sie bedienen verschiedene Kontexte und sind leicht zu verwechseln. Für die
  `domain`-Argumente von `getSeoReport`/`getAeoReport` gilt der **Slug**. Ein falscher
  Wert liefert `{}` — still, ohne Fehler, und nicht vom Fall „Workspace hat noch keine
  Reports" unterscheidbar. So entstand der Description-Bug in #4. Welche Funktion was
  liefert, steht im Code drüben — hier nicht nacherzählt, weil eine Beschreibung fremden
  Codes still veraltet. *(Beobachtet, 20.08.)*

- **Descriptions stehen bewusst NICHT im Golden Master.** Er erfasst `name`, die *Keys*
  von `inputSchema.properties`, `required` und `_meta` — laut `probe.sh`, „sonst wird
  jede Formulierungsverbesserung ein roter Build". Zwei Folgen: nach einer reinen
  Description-Änderung ist ein „Golden-Update" ein **No-op**, und §19 greift dort nicht
  — wer eines verlangt, hat den Scope des Golden missverstanden. Umgekehrt gilt: eine
  **falsche** Description fängt der Golden Master nie. Dafür braucht es eine eigene
  Assertion (siehe `tests/report-tools.sh`). *(Beobachtet, 20.08.)*

- **Rollen-Doppeldeutigkeit.** `user_api_tokens` hat eine `role`-Spalte, und **der Worker
  liest sie nirgends** — die Rolle fällt allein aus dem Token-Präfix (siehe „Wissen").
  Beide können sich also widersprechen, ohne dass es auffällt: Chris' Token ist
  `gk_team_` bei `role='admin'` und wird als `team` behandelt. Wer die Spalte ändert,
  ändert am Verhalten des Workers nichts. (`is_demo` sticht jedes Präfix und erzwingt
  `demo` — aber nur auf dem OAuth-Pfad, der `gk_`-Pfad kennt kein `is_demo`.)
  *(Beobachtet, 20.08.)*

- **`probe.sh` zählt einen delegierten Aufruf als EINEN Eintrag.** Sektion H ruft
  `tests/source-invariants.sh --nested` auf; dessen Assertionszeilen werden gedruckt,
  aber im Kindprozess gezählt — der Elternzähler sieht sie nie. Die Summenzeile von
  `probe.sh` ist deshalb **keine Assertion-Anzahl**: sie blieb bei 30, als
  `source-invariants.sh` von 2 auf 6 Assertions wuchs. Wer sie als Abdeckungsmaß liest,
  unterschätzt sie. Was zählt und geprüft ist: der **Exit-Code propagiert** — Kind
  `exit 1` → `probe.sh` `exit 1`, über `if bash … --nested; then ok; else ko; fi`.
  *(Beobachtet, 20.08.)*

- **Reihenfolgen-Kopplung ist nicht Ergebnis-Kopplung.** In GitHub Actions koppelt
  `needs:` die **Reihenfolge**, `if: always()` entkoppelt das **Ergebnis**. Wer beides
  für dasselbe hält, verzichtet auf `needs:`, um „unabhängig" zu bleiben — und
  dupliziert dann Logik, ohne Unabhängigkeit zu gewinnen. Beleg: der `authed-smoke`-Job
  lief ohne `needs:` sofort los und scheiterte **84 s bevor** der Workers Build fertig
  war; das war kein Flake, sondern das deterministische Ergebnis jedes Laufs (Build
  ~90 s, Job-Start sofort). Mit `needs: probe` + `always()` wartet er auf den Build und
  läuft trotzdem, wenn `probe` rot ist. *(Beobachtet, 20.08.)*

- **Eine präfixbasierte `deny`-Regel schützt gegen Versehen, nicht gegen Umgehung.**
  `Bash(git push:*)` in der Permission-Konfiguration hat acht Pushes abgelehnt und sah
  aus wie eine Leitplanke. `true && git push origin main` beginnt nicht mit `git push`
  und wäre vollständig durchgelaufen — acht Tage lang. Die einzige echte Sperre war,
  dass es niemand probiert hat. Der Fall braucht **keine Umgehungsabsicht**:
  `cd <repo> && git push` ist Gewohnheit und trifft dieselbe Lücke. Was wie eine
  Leitplanke aussieht, ist ein Türschild, solange die Prüfung schwächer ist als die
  Menge der Formen, die sie treffen soll. Die `main`-Grenze zieht deshalb
  `.claude/hooks/guard-push.sh`, nicht eine Regel.
  **Die Regel wurde am 21.08. aus `~/.claude/settings.json` entfernt — nicht
  vergessen, sondern ersetzt.** Wer sie zurückspielt, macht den Guard
  **unerreichbar**: `deny` schlägt jedes `allow` und greift, bevor der Hook läuft.
  Das Ergebnis wäre nicht „doppelt abgesichert", sondern genau die
  Türschild-Illusion, gegen die der Guard gebaut wurde — nur diesmal mit einem
  Guard, der stumm danebensteht. *(Beobachtet, 20.–21.08.)*

- **Eine Sicherheitsprüfung darf nicht hinter einem Filter sitzen, der schwächer ist als
  sie selbst.** Hooks kennen ein `if`-Feld mit **derselben** Präfix-Semantik wie die
  Permission-Regeln. `"if": "Bash(git push:*)"` am Guard hätte bedeutet, dass
  `cd /x && git push` den Hook gar nicht erst startet — **fail-open, bevor die Logik
  läuft**. Der Guard läuft deshalb ohne `if` auf jedem Bash-Aufruf und entscheidet
  selbst. *(Beobachtet, 20.08.)*

- **`enforce_admins: false` macht Branch Protection für Admin-Credentials wirkungslos.**
  Bis zum 20.08. galt die PR-Pflicht auf `main` für alle **außer Admins** — und die
  Credentials auf dieser Maschine sind Admin. Ein direkter Push wäre durchgegangen; §3
  hatte serverseitig **null** Durchsetzung. Steht jetzt auf `true`, bindet also auch
  Chris. Die Regel dahinter ist dieselbe wie beim Cloudflare-Dashboard: **eine
  Konfiguration, die nur in einer Weboberfläche lebt, wird nachgesehen, nicht
  geschlussfolgert.** Ein Agent kommt nicht heran — also fragen.
  Die Kehrseite von `true` ist ein **verriegelbarer** Branch: greift die Protection
  einmal ins Leere, kann niemand sie von innen öffnen. Der Ausweg steht unten unter
  **„Notausgang: `enforce_admins` temporär lösen"** — dort verifiziert, nicht vermutet.
  *(Beobachtet, 20.08.)*

- **Ein Schritt, der besteht, weil er nichts prüft.** Der `vitest`-Step im unit-Job läuft
  mit `--passWithNoTests`, und es gibt **keine Testdatei — und gab nie eine.** (Zwei
  git-log-Instrumente über alle Commits, beide leer; dieselben Instrumente mit `*.sh`
  liefern Treffer, die Null ist also echt und kein kaputtes Werkzeug, §17a.) Der Schritt
  endet auf 0 und belegt allein, dass die gepinnte Werkzeugkette startet. **Nicht für
  Abdeckung halten.** Das Flag ist ein bewusster Platzhalter mit dokumentierter
  Rücknahmebedingung, kein Überbleibsel — drei Folgen überraschen trotzdem einzeln:
  - **`npm test` und CI fällen verschiedene Urteile über dieselbe Sache.** Das Script trägt
    das Flag **nicht** und endet lokal mit **1**; CI ruft
    `npx --no-install vitest run --passWithNoTests` und endet mit **0**. Die Divergenz
    **bleibt und ist gewollt**: lokal soll „es gibt keine Tests" sichtbar sein, im Job soll
    es nicht rot machen. Wer sie angleicht, macht eine der beiden Seiten unehrlich — und
    `npm test` auf grün zu ziehen wäre die schlechtere Hälfte, weil grün dann nach
    Abdeckung aussieht. Die exit-1 ist deshalb **kein Stopp-Signal im Sinne von
    „Feedback"**, sondern der Normalzustand.
  - **`@cloudflare/vitest-pool-workers` ist deklariert und unverdrahtet.** Es gab nie eine
    `vitest.config.*`, also kein `defineWorkersConfig`, also benutzt vitest seinen
    Default-Pool und lädt das Paket nie. `npm rebuild workerd` trägt heute entsprechend
    nichts — `esbuild` schon, weil vitest über vite bootet. Der Kommentar dort behauptete
    bis zum 28.08. das Gegenteil.
  - **Der Job heißt „Unit & Typecheck" und macht weder das eine noch das andere.** Ein
    `tsconfig.json` oder ein `tsc`-Aufruf hat in diesem Repo nie existiert. **Der Name
    bleibt trotzdem** — er ist required status check, siehe „Notausgang". Der Widerspruch
    ist in `ci.yml` an Ort und Stelle vermerkt, damit ihn niemand für einen Defekt hält
    und „repariert".

  Was der Job **wirklich** prüft: `bash -n` über die CI-Bash-Dateien,
  `tests/source-invariants.sh`, `tests/guard-push.sh` — und `npm ci`, die einzige Stelle,
  die den Install-Pfad aus §5 prüft, **bevor** Workers Builds ihn fährt. Wer den
  vitest-Step je entfernt, muss `npm ci` stehen lassen.
  *(Beobachtet 28.08.2026, aufgefallen bei der §17a/§18b-Übertragung.)*

- ⚠️ TODO — erweitern, sobald der Golden Master das erste Mal etwas Unerwartetes fängt.

---

## Notausgang: `enforce_admins` temporär lösen

`main` ist mit `enforce_admins: true` geschützt — die Regel gilt **auch für Admins** und
damit auch für Chris (§3). Das ist gewollt und die eigentliche Härte des Schutzes. Es
heißt aber auch: gerät die Branch Protection einmal in einen Zustand, aus dem heraus kein
PR mehr mergebar ist, ist der Branch **verriegelt** und niemand kann ihn von innen öffnen.

⚠️ **Hier ist der Fall konkret, nicht theoretisch** — er hängt an zwei Zeilen:

```
enforce_admins   true
strict           true
contexts         ["Probe (Preview)", "Unit & Typecheck"]
```

Diese beiden Contexts sind **wörtlich die `name:`-Werte der Jobs** in
`.github/workflows/ci.yml` (`Unit & Typecheck`, `Probe (Preview)`). **Wer einen der beiden
Jobs umbenennt, verriegelt `main`**: der required context berichtet nie wieder, der PR
wird nie mergebar — und der PR, der die Umbenennung zurücknähme, ist selbst blockiert.
Ein `required_status_check`, der nie berichtet, ist der Regelfall dieser Falle. `strict:
true` steht ebenfalls, PRs müssen also zusätzlich auf dem Stand von `main` sein.

**Kein Verriegelungsrisiko dagegen aus dem übersprungenen `probe`.** Der Job **läuft
immer**; nur seine Steps hängen an `steps.wait.outputs.skip`. Er berichtet deshalb auch
bei Doc-only-PRs, für die Workers Builds keinen Build erzeugt. *(Nachgesehen, 24.08.)*

Der Ausweg ist zwei Kommandos weit. Sie stehen hier, damit im Ernstfall niemand unter
Druck herumprobiert:

```bash
R=repos/growthkit-tools/mcp/branches/main/protection

gh api -X DELETE $R/enforce_admins       # lösen
gh api -X POST   $R/enforce_admins       # zurücksetzen
gh api $R/enforce_admins --jq .enabled   # prüfen: true / false
```

⚠️ **Beide Kommandos gehören in denselben Arbeitsgang.** Kein Lösen „bis morgen", kein
Lösen mit der Absicht, es später zurückzusetzen. Zwischen den beiden Aufrufen ist `main`
für Admins ungeschützt, und der einzige verlässliche Zeitpunkt für das Zurücksetzen ist
**sofort**. Wer löst, setzt im selben Befehl zurück — sonst bleibt es offen, und niemand
merkt es, weil nichts fehlschlägt.

⚠️ **Der Notausgang läuft über den `gh`-OAuth-Token, NICHT über das fine-grained PAT** in
`~/.config/growthkit/gh-workflow-token`. Dessen `Administration`-Recht steht seit dem
24.08.2026 auf **Read** — damit scheitert der `DELETE`, und zwar an einer Stelle, an der
gerade niemand Zeit zum Debuggen hat. Also **kein `GH_TOKEN=…`-Präfix** vor diesen
Kommandos; das PAT ist für Pushes auf `.github/workflows/*` da, nicht hierfür.

**Verifiziert am 24.08.2026 in diesem Repo**, Rundweg in einem Arbeitsgang:
`true → false → true`. Entscheidend war der **vollständige** Vorher-/Nachher-Dump der
Protection, nicht nur `enforce_admins`: der Diff ist **leer**. `DELETE` auf diesem
Unterpfad rührt also weder `required_status_checks` noch `strict` noch die beiden
Contexts an — was hier mehr zählt als in den Nachbar-Repos, weil hier mehr daran hängt.
Ein ungeprüftes Notfallkommando ist kein Notausgang, sondern eine Vermutung.

⚠️ **Vor dem `DELETE` das Wiederherstellungs-Kommando bereitlegen, nicht danach.** Räumt
`DELETE` wider Erwarten mehr ab, ist `main` bereits beschädigt — Melden reicht dann nicht.
Bereitliegen muss ein `PATCH` auf `$R/required_status_checks` mit `strict: true` und
beiden Contexts, ersatzweise ein `PUT` auf `$R` mit der gesamten Konfiguration aus dem
Vorher-Dump.

---

## Bewusst zurückgestellt — nicht bauen

- **Zielauflösung im Push-Guard.** Erwogen und **verworfen** (24.08.): der Guard könnte
  bei `cd <pfad>` oder `git -C <pfad>` den Zielpfad auflösen, dort `symbolic-ref` lesen
  und gegen die dort geltende Regel prüfen. Die Gründe stehen hier, damit die Idee nicht
  in sechs Wochen als neue wiederkommt:
  - **Die Risikorichtung.** Heute ist der Zweig ein *unbedingtes* Nein — der sicherste
    Zustand, den es gibt. Jede Auflösungslogik ersetzt diese Gewissheit durch eine
    Berechnung, und **jeder Fehler in dieser Berechnung ist ein stilles Ja auf einem
    fremden `main`**.
  - **Sie legitimiert genau den Arbeitsstil, den §3 abschafft.** Der Fall wird
    organisatorisch beantwortet; beides zu bauen löst dasselbe Problem zweimal, und die
    technische Lösung macht die Regel weich.
  - **Abdeckung klein, Restfläche groß.** Von drei beobachteten Fällen wären zwei literal
    auflösbar. Nicht abgedeckt blieben `pushd`, ein Wechsel in einer Subshell, mehrfache
    Wechsel, Variablen im Pfad, `GIT_DIR`/`GIT_WORK_TREE` aus der Umgebung und Symlinks —
    alle fielen ohnehin auf fail-closed zurück. Wir trügen die Komplexität **und**
    behielten den Deny-Pfad.
  - **Die fremde `PROTECTED`-Liste.** Den Nachbar-Guard zu parsen ist die gefährliche
    Variante: schlägt der Parse fehl, ist das Ergebnis eine **leere** Liste — und eine
    leere Positivliste erlaubt alles (§18a d), an der empfindlichsten Stelle des Systems.
    Tragfähig wäre nur „`main`/`master` gelten überall als geschützt", eine Annahme, die
    heute in allen drei Repos stimmt und dann ausgesprochen gehört.

- **In-Process-Ausführung von Worker-Code.** Zurückgestellt (28.08.2026), aber hier
  festgehalten, weil die Lücke sonst falsch benannt wird. Sie heißt **nicht** „es gibt
  keine Unit-Tests", sondern: **nichts führt Worker-Code aus, ohne dass eine Instanz
  läuft.** `probe.sh`, `report-tools.sh`, `auth-paths.sh` und `authed-smoke.sh` führen ihn
  aus — aber nur gegen `wrangler dev` oder eine Preview-Version. `source-invariants.sh`
  und Sektion H sind `grep` über die Quelle, keine Ausführung. Zwei Gründe, warum das ein
  **eigener Vorgang** ist und nicht nebenbei erledigt wird:
  - **`index.js` hat genau einen Export** (`export default {`); nichts auf Modulebene ist
    importierbar. Ein Test wäre zwangsläufig ein Integrationstest des fetch-Handlers, kein
    Unit-Test.
  - **Er liefe gegen die echte Supabase.** Der Handler braucht `SUPABASE_URL`, `DEMO_RL`
    (KV) und Secrets. KV kann `vitest-pool-workers` simulieren, Supabase nicht — die
    Aufrufe gingen an die Produktionsinstanz, dasselbe Problem wie bei Preview-Versionen
    („Probes dürfen nur lesen"). **Wer das baut, löst zuerst das, nicht die Testdatei.**

- **Umbau auf die MCP-Revision 2026-07-28.** Zurückgestellt (29.08.2026), **nicht
  vergessen**. Die Revision ist final (veröffentlicht 28.07.2026), die Mindestfrist für
  Abkündigungen beträgt zwölf Monate, und Clients sprechen weiterhin `2025-11-25`. Es
  drängt also nichts — und ohne die Handshake-Assertions aus PR #28 wäre der Umbau gar
  nicht überprüfbar gewesen.

  ⚠️ **Der gemessene Zustand steht NICHT hier, sondern als `MIGRATION_MARKERS` in
  `tests/source-invariants.sh`** — und zwar absichtlich: dort ist er eine Assertion, die
  rot wird, sobald sie nicht mehr stimmt. Eine Liste in dieser Datei wäre Prosa und
  verrottete still. Wer wissen will, was fehlt und was noch da ist, liest die Liste; wer
  eine Migration baut, streicht dort seinen Eintrag. **Keine zweite Kopie hier anlegen**
  — dieselbe Regel wie bei `EXP_UI_PROTOCOL`.

  Was die Liste **nicht** leistet und was deshalb ein Mensch entscheiden muss: sie prüft
  ihre eigene Vollständigkeit gegen die Spec nicht (§18a k). Und §11 gilt unverändert —
  es gibt **zwei** Protokollversionen mit 2026er-Datum, die ext-apps-Version und die
  Kernrevision, und sie dürfen nie angeglichen werden.

- **HMAC-Nonce-Härtung für `place_call`:** signierte Nonce, eingebettet ins
  `resources/read`-Card-HTML, serverseitig verifiziert — macht einen gefälschten direkten
  `place_call` unmöglich. Absichtlich zurückgestellt; nur bei konkretem Compliance- oder
  Trust-Center-Bedarf bauen. Die aktuelle App-Private-Lösung erfüllt UWG § 7 bereits.

---

## Abgleich mit den Nachbar-Repos

Die drei `AGENTS.md` (`mcp`, `supabase`, `growthkit-website`) werden **nicht** automatisch
synchron gehalten; was hier entsteht, muss von Hand hinüber und umgekehrt. Dieser Abschnitt
ist die Liste der Übertragungen — und der Grund, aus dem es ihn gibt: der Rückstand beim
`enforce_admins`-Notausgang stand seit dem 24.08. in supabase' Offen-Tabelle als
„**`mcp`: fehlt**" und war **von hier aus unsichtbar**.

**Erledigt** — jeder Eintrag in den Nachbardateien per Auge bestätigt, nicht per Muster:

| Gegenstand | Ursprung | Stand |
|---|---|---|
| §18a **(j)**, **(k)**, **(l)** | `growthkit-website` | hier PR #21 · `supabase` PR #15 |
| §18a **(m)** | strittig, s. u. | in allen drei |
| Exec-Bit-Assertion liest `ls-tree HEAD` | `growthkit-website` | in allen drei `tests/source-invariants.sh` |
| Guard-Verengung (`seg_is_push` / `PUSH_SEGS`) | `growthkit-website` PR #8 | hier PR #23 · `supabase` PR #16 |
| §7a | **hier** (PR #23) | `supabase` PR #19 · `growthkit-website` PR #9 |
| §7a-Ausnahme-Absatz | `growthkit-website` | hier PR #24 · in `supabase` |
| Notausgang `enforce_admins` | `growthkit-website` | hier PR #24 · in `supabase` |

**Offen — Stand 30.08.2026, um die letzte Zeile am 01.09.2026 ergänzt (nur diese neu
nachgesehen, die darüber unverändert übernommen):**

| Gegenstand | Ursprung | Stand |
|---|---|---|
| **§17a** (der bekannte Treffer) | `growthkit-website` | hier seit 27.08. · `supabase` **fehlt** |
| Bereichs-Scan `origin/main..HEAD` | **hier** (28.08.) | nur hier — die Begründung ist „öffentliches Repo" und gilt für die Nachbarn nicht |
| **§18b** (Falsifikations-Notation) | Teil 1 **hier**, Teil 2+3 `growthkit-website` | hier seit 27.08. · `supabase` **fehlt** |
| Falsifikations-**Pflicht** bei Leitplanke 18 | `growthkit-website` | hier seit 27.08. · `supabase` **fehlt** |
| §18b **Rückweg** (Sicherung vor der Injektion) | **hier** (30.08.) | hier seit 30.08. · in **beiden** Nachbarn **fehlt** — nachgesehen, nicht angenommen |
| **Commit-Verbot in §3 + Rettungsweg + Branch-Hälfte in `.githooks/pre-commit`** | `growthkit-website` PR #65, 01.09.2026 | hier mit diesem Commit · `supabase` **noch in keinem Commit** |

⚠️ **Die Branch-Hälfte ist übernommen, nicht kopiert — die drei Vorbedingungen sind hier
einzeln geprüft worden**, weil der Eintrag drüben ausdrücklich darum bittet („dort erst
prüfen, ob `main` überhaupt geschützt ist, statt zu übernehmen"): `main` ist hier
geschützt (01.09.2026 über die API nachgesehen: `enforce_admins` true, PR-Reviews
verlangt, `strict` true) — der Hook ist damit die frühe, nicht die einzige Ebene, anders
als in `chrome-extension`. `main` ist hier **nicht** der Arbeitszweig. Und die Regel
stand schon da, nur ohne die Commit-Hälfte — deshalb geschärft statt danebengestellt.

⚠️ **Zwei Angaben in der Tabelle drüben sind seit heute überholt, und keine davon ist
von hier aus zu berichtigen** (§3, ein Lauf, ein Repo): `growthkit-website` führt für
diesen Gegenstand „`mcp` und `supabase` fehlen". Für `mcp` erledigt dieser Commit das.
Für `supabase` stimmte es schon vorher nicht ganz — dort liegen Hook-Änderung und Suite
am 01.09.2026 **im Arbeitsbaum**, ungetrackt beziehungsweise ungecommittet. „Fehlt" und
„vorhanden" sind beide falsch; deshalb steht in der Zeile oben, was tatsächlich gemessen
wurde.

⚠️ **Der Rückweg-Handgriff gehört in beide Nachbar-Repos, und das ist gemessen:** dort steht
§18b bereits, aber `grep -ciE "sicherungskopie|rückweg|checkout -- "` über beide `AGENTS.md`
liefert **null**. Gleichzeitig steht `git checkout --` in `growthkit-website` in vier
Commit-Bodies und in `supabase` in einem — der Handgriff wird dort also gefahren, nur ohne
die Regel daneben. Die Klasse ist nicht repo-spezifisch: sie hängt an git, nicht an diesem
Repo. **Übertragen kann ich sie von hier aus nicht** — ein CC-Lauf arbeitet in genau einem
Repo (§3).

⚠️ **Die drei Zeilen gehören zusammen und dürfen nicht einzeln wandern.** Eine Notation ohne
die Pflicht, die sie notiert, ist eine Formvorschrift ohne Gegenstand; das war hier bis zum
27.08. der Fall, nur andersherum — die Fehlerklassen in §18a standen da, die Pflicht nicht.
In `supabase` fehlt beides, nachgesehen am 27.08.

⚠️ **`growthkit-website` führt §17a und §18b in seiner Offen-Tabelle noch als „nur hier".**
Das ist seit diesem PR falsch und **hier nicht korrigierbar** — ein CC-Lauf arbeitet in genau
einem Repo (§3). Die Gegenbuchung drüben ist ein eigener Vorgang.

⚠️ **Widersprüchliche Herkunft von §18a (m).** `supabase` führt sich selbst als Ursprung
(„hier"), `growthkit-website` führt `mcp` („hierher übernommen"). Beide können nicht
stimmen. Die Commit-Zeitstempel entscheiden es nicht: `supabase` 11:23:55, `mcp` 11:24:30
— 35 Sekunden auseinander, also parallel entstanden, während `growthkit-website` erst um
15:28 nachzog. **Nicht aufgelöst, sondern notiert.** Wer es auflöst, korrigiert die
falsche der beiden Tabellen; eine erfundene Herkunft wäre schlechter als eine offene.

⚠️ **Ein Grep über drei Repos misst drei Formatierungen, nicht eine.** Am 24.08. hat
dieselbe Prüfung dreimal falsch gemeldet, jedes Mal in Richtung „fehlt":

- `(m)` steht hier als `(m) **`, in beiden Nachbarn als `**(m)` — ein Muster für die eine
  Schreibweise findet die andere nicht.
- `(m)` galt beim Guard-Transfer als in `growthkit-website` fehlend. Es **wurde dort
  am selben Tag nachgetragen**; der Befund war richtig und ist es nicht mehr geblieben.
  **Ein Abgleich-Eintrag ist ein Messwert mit Datum, keine Eigenschaft.**
- Der Workflow-Token-Handgriff sah hier einzigartig aus, weil hier `-c credential.helper=`
  steht und in `supabase` `git config --local --add … ''`. **Gleiche Einsicht, andere
  Mechanik** — ein Muster auf die Mechanik misst nicht die Einsicht.

Ein Eintrag gehört hierher, sobald eine Klasse, eine Assertion oder eine Regel entsteht,
die **nicht repo-spezifisch** ist. Der Golden-Master-Scope etwa gehört **nicht** hierher:
es gibt nur hier einen. Ein Eintrag verschwindet erst, wenn er in **beiden** anderen Repos
steht — **nachgesehen, nicht angenommen.**
