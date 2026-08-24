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

- **Ein hand-rolled File: `index.js`, ~4050 Zeilen.** MCP JSON-RPC manuell implementiert,
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

**Maßgeblich ist der Code, nicht diese Datei.** Bei Widerspruch gewinnt der Code — aber
melde den Widerspruch, statt ihn still zu übergehen.

---

## Werkzeuge

```
Tool-Versionen:  package.json (exakte Versionen, kein Caret) + package-lock.json
                 Node: 24.16.0 · Deno: 2.8.0 (nicht in diesem Repo genutzt)
Lokal starten:   npm run dev                     # wrangler dev → localhost:8787
Tests:           npm test                        # vitest + @cloudflare/vitest-pool-workers
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
                 # servierte Fläche. B (server.json), G (Golden) und H (index.js)
                 # vergleichen den Checkout GEGEN die Fläche und gelten nur, wenn beide
                 # Seiten aus demselben Commit stammen. Die frühere Kurzformel
                 # „A–G gegen die URL, H von Disk" war falsch.
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
     fiele Richtiges. Drei Stellen in dieser Datei, die ausdrücklich **bleiben**:
     „68 Tools für `admin`, 63 für `gk_team_`" und „30 von 68 Tools, davon 29 lesend"
     (beide *live verifiziert, 20.08.*) sowie „12 von 87" in §18a **(k)**
     (`growthkit-website`, 21.08.2026). Diese Zahlen ergeben sich nicht — sie wurden
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
    *(Beobachtet.)*
22. **`str_replace`-Hunks statt File-Rewrites.** Bei 4050 Zeilen ohne Modulschnitt ist ein
    Full-Rewrite nicht reviewbar.
23. Tests liegen unter `tests/`. Änderungen dort gehören in einen **separaten Commit** mit
    Begründung im Body. Test und Fix im selben Commit ist ein Warnsignal.

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
- Der Stateless-HTTP-RC (`server/discover`, kein `initialize`-Handshake) ist **additiv**
  geplant, kein Rewrite. Bestehende Handshake-Pfade bleiben funktionsfähig.

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
| §7a-Ausnahme-Absatz | `growthkit-website` | **dieser PR** · in `supabase` |
| Notausgang `enforce_admins` | `growthkit-website` | **dieser PR** · in `supabase` |

**Offen: derzeit nichts.** Das ist ein Messergebnis vom 24.08.2026, kein Dauerzustand.

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
