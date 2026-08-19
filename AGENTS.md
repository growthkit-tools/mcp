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
- Auth: Bearer-Token, **token-hash-scoped**, nicht user-id-scoped.
- Deploy: **automatisch bei Push** via Cloudflare Workers Builds (Git-Integration).
  Deploy-Command `npx wrangler deploy`, Version-Command `npx wrangler versions upload`.
  Es gibt **bewusst keine GitHub-Action** dafür — das ist kein Versäumnis, füge keine hinzu.
- **Builds für Non-Production-Branches sind aktiv:** jeder Push auf einen Feature-Branch
  erzeugt eine **Preview-Version mit eigener URL**, ohne Production anzufassen.
  ⚠️ Preview-Versionen nutzen **dieselben Bindings und Secrets wie Production** — sie
  sprechen mit der echten Supabase. Probes dürfen nur lesen.

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

⚠️ TODO — Scripts existieren noch nicht, werden im Harness-Bootstrap angelegt.

```
Tool-Versionen:  package.json (exakte Versionen, kein Caret) + package-lock.json
                 Node: 24.16.0 · Deno: 2.8.0 (nicht in diesem Repo genutzt)
Lokal starten:   npm run dev                     # wrangler dev → localhost:8787
Tests:           npm test                        # vitest + @cloudflare/vitest-pool-workers
Golden Master:   tests/golden/tools.json
Golden updaten:  npm run golden:update           # NUR bei beabsichtigter Schema-Änderung
Probe:           ./scripts/probe.sh <base-url>   # lokal oder Preview-Version-URL
Preview-URL:     steht im Cloudflare-Build-Log des Branch-Pushes
```

**Kein Docker im Code-Server verfügbar** und nichts hier braucht welches. Wenn du auf ein
Werkzeug stößt, das Docker voraussetzt: nicht umgehen, eskalieren.

---

## Leitplanken (nicht verhandelbar)

### Deploy & Git

1. **Kein manuelles `wrangler deploy`.** Deploy passiert ausschließlich über Push.
   Manueller Deploy erzeugt unsichtbare Drift zwischen Repo-Stand und Live-Worker.
2. **Keine GitHub-Action fürs Deployment hinzufügen.** Die Abwesenheit ist Absicht.
3. 🔵 **ENTSCHEIDUNG — Autonomie-Grenze:**
   - Commit + Push auf **Feature-Branch**: erlaubt
   - Push auf `main`: **nie**
   - PR öffnen: erlaubt
   - PR mergen: **nie** — Mensch approved
4. **Keine DDL, keine SQL-Migrationen, kein `apply_migration`, kein `deploy_edge_function`.**
   Schema-Änderungen gehören ins `supabase`-Repo und brauchen einen Menschen. Wenn eine
   Änderung hier eine DB-Änderung erfordert: als Vorschlagsdatei ausgeben und stoppen.
5. **`package.json` verändert das Build-Verhalten.** Seit 19.08. existiert eines im Root
   (vorher bewusst keins). Ob Workers Builds dadurch einen Install-Step fährt, ist noch
   nicht verifiziert. Änderungen an `package.json`, `package-lock.json` oder `wrangler.toml`
   **nie direkt auf `main`** — immer erst als Preview-Version, Build-Log lesen.
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
11. **`ui/initialize` MUSS `protocolVersion: "2026-01-26"` enthalten.** Fehlt es, schlägt
    der Client still fehl — keine Fehlermeldung, kein Log, nur „geht nicht". *(Beobachtet.)*

### Compliance — `place_call`

12. **`place_call` ist app-private** über `_meta.ui.visibility: ["app"]` (MCP-Apps /
    SEP-1865). Es steht in `tools/list`, aber der Host verbirgt es vor dem Modell und
    proxied nur `tools/call` aus dem Lead-Call-Card-Iframe. Das Modell kann es nie sehen
    oder aufrufen — human-initiated only, damit UWG § 7 erfüllt.
    **Dieses `_meta` ist compliance-tragend. Es zu verlieren bricht nichts sichtbar.**
    Nie entfernen, nie umbenennen, nie „aufräumen".
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
- ⚠️ TODO — erweitern, sobald der Golden Master das erste Mal etwas Unerwartetes fängt.

---

## Bewusst zurückgestellt — nicht bauen

- **HMAC-Nonce-Härtung für `place_call`:** signierte Nonce, eingebettet ins
  `resources/read`-Card-HTML, serverseitig verifiziert — macht einen gefälschten direkten
  `place_call` unmöglich. Absichtlich zurückgestellt; nur bei konkretem Compliance- oder
  Trust-Center-Bedarf bauen. Die aktuelle App-Private-Lösung erfüllt UWG § 7 bereits.
