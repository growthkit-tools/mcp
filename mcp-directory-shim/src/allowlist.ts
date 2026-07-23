// Demo-path tool allowlist (defense-in-depth + curation).
//
// Quelle / Single Source of Truth: llm-router DEMO_MODE_SUFFIX ("ERLAUBTE TOOLS —
// lesend, echte Daten"), gemappt auf MCP-Tool-Namen. Bei Suffix-Änderung hier
// UND in DEMO_TOOLS im MCP-Worker (index.js) spiegeln — beide Listen identisch.
//
// Rationale: der Demo-Modus ist ein LLM-System-Prompt-Suffix, das nur greift,
// wenn Calls durch GrowthKits eigenen Agenten laufen. Ein Directory-Playground
// ruft Tools DIREKT auf (kein llm-router dazwischen) — dort liefern nur die
// Suffix-"Erlaubt"-Reads echte Daten. Die Suffix-"VERBOTEN/simulieren"-Tools
// (getTopLeads, scoreLeads, show_callable_leads, alle crm*/enrich*) sind
// designbedingt LLM-simuliert → im Direkt-Call Sad-Path (leer/Fehler) → raus.
// Suffix-Einträge ohne exponiertes MCP-Gegenstück (Deep Search, Load Playbook,
// Search/List Feedback) sind weggelassen.
//
// With a user-provided gk_ token this list is NOT applied — the upstream's
// role-based filtering is the only authority.
export const DEMO_ALLOWLIST = new Set<string>([
  // Memory (Reads)
  "searchMemory",
  "listMemories",
  "countMemories",
  "getChapterOverview",
  "getHistory",
  "listDeleted",
  "getWorkingMemory",
  // Campaigns / Leads (Reads) — Wow-Träger: listCampaignLeads
  "listCampaigns",
  "getCampaign",
  "listCampaignLeads",
  "getCampaignLeadFields",
  // Documents / Team / Reminders (Reads)
  "listDocuments",
  "getDocument",
  "listTeam",
  "listReminders",
]);

export const DEMO_BLOCKED_MESSAGE =
  "This tool isn't available in the GrowthKit demo. Sign up free at https://app.growthkit.tools to use it with your own data.";
