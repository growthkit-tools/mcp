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
    werden. `gk_view_` reicht, solange die CI-Pfade nur lesen — `probe.sh`,
    `report-tools.sh` und `auth-paths.sh` tun das alle. `gk_team_` wäre die Obergrenze,
    ein präfixloses Token nie.
- Deploy: **automatisch bei Push** via Cloudflare Workers Builds (Git-Integration).
  Deploy-Command `npx wrangler deploy`, Version-Command `npx wrangler versions upload`.
  Es gibt **bewusst keine GitHub-Action** dafür — das ist kein Versäumnis, füge keine hinzu.
- **Builds für Non-Production-Branches sind aktiv:** jeder Push auf einen Feature-Branch
  erzeugt eine **Preview-Version mit eigener URL**, ohne Production anzufassen.
  ⚠️ Preview-Versionen nutzen **dieselben Bindings und Secrets wie Production** — sie
  sprechen mit der echten Supabase. Probes dürfen nur lesen.
- **Build-Watch-Excludes:** `*.md`, `specs/**`, `.claude/**`, `.github/**`, `tests/**`,
  `scripts/**` lösen **keinen** Build aus. Regel dahinter: ausgeschlossen wird, was das
  ausgelieferte Deployable nicht verändert. **Aber sie greifen erst auf einem Branch mit
  Build-Historie — der erste Push eines neuen Branches baut immer**, weil es ohne
  vorherigen Build keine Diff-Basis gibt. Beides belegt: `abe9ca3` (erster Push, nur
  exkludierte Pfade, baute trotzdem) gegen die Merge-Commits `9670879` und `7187c66` auf
  `main` (nur exkludierte Pfade, kein Build, `probe`-Job übersprungen). „Kein Build" ist
  also nichts, was man vom ersten Push eines Branches erwarten darf. Autoritativ ist die
  Liste im Cloudflare-Dashboard; `.github/workflows/ci.yml` spiegelt sie im Kommentar am
  `wait`-Step. *(Beobachtet, 20.08.)*

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
    - **§18a — Eine Assertion ohne roten Lauf gilt als nicht verifiziert.** Drei
      beobachtete Fehlerklassen produzieren grüne Tests, die nichts prüfen. Der
      Mechanismus ist jedes Mal derselbe: **Abwesenheit wird als Bestehen gelesen.**
      (a) eine Prüfung „keine Verstöße" über einer leeren Liste ist immer grün — jede
      Iteration über eine Liste braucht daher zusätzlich eine Prüfung, dass die Liste
      nicht leer ist; (b) in `jq` rebindet `|` das `.`, sodass `$d | contains(.)` zu
      `$d contains $d` wird und immer wahr ist — Werte vor dem Vergleich mit `. as $e`
      binden; (c) ein Vergleich gegen einen Wert, der bei fehlender Quelle leer ist,
      besteht immer — die **Existenz der Quelle** muss eigenständig geprüft werden.
      Belege für (c): ein fehlendes `index.js` gab in `probe.sh` nur eine Notiz aus und
      blieb grün; ein umbenanntes `const PROTOCOL_VERSION` lieferte `""` und war damit
      gegen jeden Vergleich mit dem ext-apps-Wert grün. Alle drei fallen beim Lesen
      nicht auf, nur beim Falsifizieren. *(Beobachtet, 20.08.)*
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

- ⚠️ TODO — erweitern, sobald der Golden Master das erste Mal etwas Unerwartetes fängt.

---

## Bewusst zurückgestellt — nicht bauen

- **HMAC-Nonce-Härtung für `place_call`:** signierte Nonce, eingebettet ins
  `resources/read`-Card-HTML, serverseitig verifiziert — macht einen gefälschten direkten
  `place_call` unmöglich. Absichtlich zurückgestellt; nur bei konkretem Compliance- oder
  Trust-Center-Bedarf bauen. Die aktuelle App-Private-Lösung erfüllt UWG § 7 bereits.
