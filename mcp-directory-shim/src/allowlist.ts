// Demo-path tool allowlist (defense-in-depth + curation).
//
// The Worker enforces its own server-side DEMO_TOOLS set for is_demo sessions —
// this shim list is a curated SUBSET of it: the memory suite (verified non-empty
// since 2026-07-23, fictional "ScaleUp Metrics GmbH") plus the campaign/lead
// scoring core (demo workspace seeded 2026-07: one campaign, 9 scored leads).
// Deliberately dropped from the server set because they are EMPTY in the demo
// workspace: listTasks, getOpenTasks, listDocuments, getDocument, listReminders.
//
// crm* tools are excluded on BOTH sides (they depend on the external CRM
// connector and return setup_required/empty in demo).
//
// With a user-provided gk_ token this list is NOT applied — the upstream's
// role-based filtering is the only authority.
export const DEMO_ALLOWLIST = new Set<string>([
  // Memory suite
  "getChapterOverview",
  "searchMemory",
  "listMemories",
  "countMemories",
  "getHistory",
  // Campaign / lead scoring core (seeded demo campaign)
  "getTopLeads",
  "scoreLeads",
  "listCampaigns",
  "getCampaign",
  "listCampaignLeads",
  "getCampaignLeadFields",
  "show_callable_leads",
]);

export const DEMO_BLOCKED_MESSAGE =
  "This tool isn't available in the GrowthKit demo. Sign up free at https://app.growthkit.tools to use it with your own data.";
