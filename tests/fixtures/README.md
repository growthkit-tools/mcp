# Fixtures

## `hunter-find-contacts-uni-freiburg.json`

**Übernommen aus `supabase`**, `functions/_shared/enrichment/__fixtures__/` (PR #139).
Die Datei ist dort die Vorlage für `normalisiereKandidaten()`; hier ist sie die Vorlage
für die zweite Fassung desselben Normalisierers in `index.js`. Gleiche Datei, gleicher
Inhalt — zwei Kopien, damit beide Repos ohne den jeweils anderen prüfbar bleiben.
Ändert sich drüben etwas an ihr, gehört sie hier nachgezogen.

### Herkunft (aus dem README drüben)

Antwort eines **echten** Laufs vom 21.09.2026, ~17:40 (Europe/Berlin): `n8n-proxy`
`action: find_contacts`, ausgelöst über das MCP-Tool `findContacts` (Hunter
**Platform**-Key, 1 Credit). Aufruf: `{ domain: "uni-freiburg.de", limit: 3 }` — **kein**
`seniority`, **kein** `department`.

Das ist exakt das Objekt, das der Worker als `data` sieht: `n8n-proxy` gibt das
Handler-Ergebnis **flach** zurück (`:272`, keine `result`-Hülle), die Action-Hülle legt
`routed_to`/`routing_reason` darüber, `metered()` hängt `credits` an.

### Was original ist

Feldnamen, Verschachtelung, Typen, alle vier `null`-Stellen (`seniority`,
`verification_status`, `linkedin`, `phone`), `pattern`, `total_results`, `credits`,
`routed_to`, `routing_reason`, `position`, `department`, `confidence`.

### Was ersetzt wurde

**Die personenbezogenen Werte** — `first_name`, `last_name`, `email`, `linkedin`. Es sind
reale Beschäftigte einer Hochschule; ihre Namen gehören in kein getracktes Repo, und in
ein öffentliches erst recht nicht.

⚠️ **Strukturgleich ersetzt, und das trägt die Tests:**

- Die Adressen folgen weiter **`{last}{f}`**, genau dem `pattern`, das die Antwort
  mitliefert (`musterm@`, `beispielt@`, `probstn@`).
- `linkedin` behält die URL-Form, **und der dritte Eintrag bleibt `null`** — sonst prüfte
  kein Fall mehr, dass der Normalisierer ein fehlendes Profil übersteht.
- `seniority` des ersten Eintrags bleibt `null`, `verification_status` ebenso: „Hunter
  kennt die Stufe nicht" ist der interessantere Fall.

### ⚠️ Dieses Repo ist öffentlich

Die Datei enthält keine Secrets und keine echten Personendaten. Was bleibt, ist eine reale
Domain (`uni-freiburg.de`) als Beleg für das `pattern`. Wer das nicht will, ersetzt die
Domain **in beiden Repos gleichzeitig** — eine einseitige Änderung macht aus einer
übernommenen Fixture zwei verschiedene, und dann prüfen die Tests hier etwas anderes als
die drüben, ohne dass es auffällt.

### Wenn die Fixture erneuert wird

Denselben Aufruf über `findContacts` fahren, danach erneut anonymisieren — die drei
Eigenschaften oben müssen erhalten bleiben, sonst prüfen die Tests etwas anderes, ohne rot
zu werden.

---

## `hunter-find-contacts-nur-generisch.json`

Der Fall aus `SPEC-generische-adressen-sind-keine-kontakte.md`: Hunter liefert für eine
kleine Firma **nur generische Postfächer**. Gemessen am 21.09.2026, 19:26 (`findContacts`
im team@-Workspace, Hunter Platform-Key): drei Treffer, **alle** `type: "generic"`
(`info@`, `jobs@`, `verkauf@`), `first_name` / `last_name` / `position` durchgängig `null`.
Der Worker schrieb daraufhin `contact_email = info@…` mit `contact_name = null`; der Lead
trug danach `has_email = true` und wurde vom reveal übersprungen.

### Was aus der Messung stammt

| | |
|---|---|
| drei Einträge, **alle** `type: "generic"` | gemessen |
| `first_name`, `last_name`, `position` je `null` | gemessen |
| die drei lokalen Teile `info@`, `jobs@`, `verkauf@` | gemessen — sie sind der Gegenstand |
| Feldnamen, Verschachtelung, Typen | gemessen (dieselbe Hunter-Form wie nebenan) |

### Was **nicht** aus der Messung stammt

⚠️ **Ausdrücklich, damit hier niemand eine Provenienz liest, die es nicht gibt:**
`confidence` (95/88/85), `organization`, `pattern`, `total_results` und `credits` sind
**plausibel gesetzt, nicht gemessen**. Sie tragen keine Assertion. Wer einen Test darauf
stützt, stützt ihn auf eine Erfindung.

### Die Domain ist ersetzt — und zwar anders als nebenan

Die gemessene Firma ist ein realer Lead aus einer Kampagne. Bei
`hunter-find-contacts-uni-freiburg.json` ist die Domain stehen geblieben, weil sie dort
das `pattern`-Feld belegt; hier belegt sie nichts — die Aussage steckt in `type` und in den
lokalen Teilen. In einem **öffentlichen** Repo ist eine Prospect-Domain ohne Belegwert
nicht nötig, also steht `kmu-beispiel.invalid`.

⚠️ **Wenn dieselbe Fixture drüben in `supabase` entsteht, muss die Ersetzung dort genauso
erfolgen** — sonst sind es zwei verschiedene Fixtures unter einem Namen, und die Tests hier
prüfen etwas anderes als die dort, ohne dass es auffällt.
