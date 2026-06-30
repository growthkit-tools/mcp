// v1.10.0 — 2026-06-30: Playbook prompt bodies moved to private Edge (n8n-embed
//                       get_prompt) behind growth/pro plan-gate. Worker keeps only
//                       prompt metadata for prompts/list; prompts/get fetches body.
// v1.9.0 — 2026-06-23: Fixed reminders tools (user_token column removed → resolve to user_id
//                       via resolve_user_token). Added task_id link on createReminder + listReminders filter.
// v1.8.0 — 2026-04-29: Added updateCampaignLead tool (Task 8). Whitelist-based
//                       partial update with shallow metadata merge. lifecycle_stage='rejected'
//                       requires rejected_reason. Routes to n8n-embed action update_campaign_lead.
// v1.7.0 — 2026-04-28: Added working memory tools (setWorkingMemory, getWorkingMemory)
//                       for Session Working Memory System (Roadmap Task 6). Routes via
//                       n8n-embed actions working_memory_set / working_memory_get. The
//                       clear and list_active actions are intentionally NOT exposed —
//                       Build Messages calls them directly.
// v1.6.1 — 2026-04-27: Campaign tools route via n8n-embed (was: direct REST + n8n-router).
// v1.6.0 — 2026-04-27: Added campaign tools (createCampaign, listCampaigns,
//                       getCampaign, updateCampaign, addCampaignLeads,
//                       getCampaignLeadFields, listCampaignLeads). Custom
//                       fields auto-route to metadata jsonb via n8n-router.
// v1.5.0 — 2026-04-24: Removed deprecated gmail_send_message tool
//                       (use email_compose instead). Supabase-side
//                       gmail-send Edge Function wrapper stays until
//                       2026-05-21 for any direct callers.
// v1.4.0 — 2026-04-24: Added email_compose tool (draft + send via provider-agnostic dispatch).

// service_role → sb_secret_ Migration: Key nur auf apikey, kein Bearer (sonst PostgREST "Invalid JWT").
// Legacy-JWT (eyJ…) behält Bearer, damit der Übergang ohne gesetztes Secret nicht bricht.
function sbHeaders(env, extra = {}) {
  const key = env.SUPABASE_SECRET_KEY ?? env.SUPABASE_SERVICE_ROLE_KEY;
  return key.startsWith("eyJ")
    ? { apikey: key, Authorization: `Bearer ${key}`, ...extra }   // Legacy-JWT: apikey + Bearer
    : { apikey: key, ...extra };                                  // sb_secret_: NUR apikey
}

// ── MCP-Client-Erkennung aus redirect_uri ──────────────────────────────
// Nur der Client ist aus dem OAuth-Request ableitbar (nicht das Directory).
// Substring-Match auf der ganzen URI, robust auch für custom schemes (cursor://, claude://).
function detectMcpClient(redirectUri) {
  const u = String(redirectUri || "").toLowerCase();
  if (!u) return "other";
  if (u.includes("claude.ai") || u.includes("claude://") || u.includes("anthropic")) return "claude";
  if (u.includes("chatgpt.com") || u.includes("openai.com") || u.includes("chatgpt://")) return "chatgpt";
  if (u.includes("cursor")) return "cursor";
  if (u.includes("cline")) return "cline";
  if (u.includes("vscode") || u.includes("visualstudio")) return "vscode";
  if (u.includes("localhost") || u.includes("127.0.0.1")) return "inspector";
  return "other";
}

const MCP_CLIENT_LABELS = {
  claude: "Claude",
  chatgpt: "ChatGPT",
  cursor: "Cursor",
  cline: "Cline",
  vscode: "VS Code",
  inspector: "the MCP Inspector",
  other: "your AI client",
};

// ── Demo-Rate-Limit (Cloudflare KV, per IP, per Minute) ────────────────
// Nur für Demo-Sessions. Fail-OPEN: KV fehlt/fehlerhaft → Demo läuft weiter
// (lieber unbeschränkt als kaputt). 30 Calls/min/IP ist großzügig; Kosten-
// treiber ist nur das searchMemory-Embedding (Cent-Bruchteile).
const DEMO_RL_LIMIT = 30;            // Calls pro Minute pro IP
const DEMO_RL_TTL_SECONDS = 120;     // Key-Selbstreinigung
async function checkDemoRateLimit(env, request) {
  if (!env.DEMO_RL) return { allowed: true }; // KV nicht gebunden → fail open
  const ip = request.headers.get("CF-Connecting-IP") || "unknown";
  const minute = Math.floor(Date.now() / 60000);
  const key = `demo:${ip}:${minute}`;
  try {
    const cur = parseInt((await env.DEMO_RL.get(key)) || "0", 10);
    if (cur >= DEMO_RL_LIMIT) return { allowed: false };
    await env.DEMO_RL.put(key, String(cur + 1), { expirationTtl: DEMO_RL_TTL_SECONDS });
    return { allowed: true };
  } catch (e) {
    console.error("demo rate-limit KV error (failing open):", e);
    return { allowed: true };
  }
}

// ── Brand favicon (inlined; served via /favicon.svg + /favicon.ico) ────
const FAVICON_SVG = `<svg version="1.1" id="Layer_1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" x="0px" y="0px"
	 width="100%" viewBox="0 0 1667 1667" enable-background="new 0 0 1667 1667" xml:space="preserve">
<path fill="#4A1E60" opacity="1.000000" stroke="none"
	d="
M1058.000000,1668.000000
	C705.333435,1668.000000 353.166870,1668.000000 1.000236,1668.000000
	C1.000157,1112.333618 1.000157,556.667236 1.000079,1.000609
	C556.666199,1.000406 1112.332397,1.000406 1667.999023,1.000203
	C1667.999268,556.666077 1667.999268,1112.332153 1667.999634,1667.999023
	C1464.833374,1668.000000 1261.666626,1668.000000 1058.000000,1668.000000
M791.108337,152.605713
	C779.224121,163.789764 766.799683,174.457870 755.544983,186.243073
	C691.107056,253.718506 647.260193,333.233215 619.036987,421.738037
	C602.729126,472.877411 592.721313,525.272949 589.397949,578.820740
	C588.089722,599.898499 587.590088,621.145447 588.621033,642.222473
	C590.304321,676.636841 593.485107,710.979675 596.211426,745.338684
	C596.504822,749.036621 595.469482,751.608582 592.979126,754.169861
	C572.889343,774.831909 552.553040,795.268616 532.940247,816.376526
	C510.166016,840.886780 487.559418,865.587891 465.785461,890.982544
	C444.238312,916.112610 431.998566,945.228027 431.740997,978.982422
	C431.451447,1016.925842 430.073181,1054.863525 430.024353,1092.804932
	C430.000214,1111.587524 431.472778,1130.408081 433.039978,1149.146973
	C434.695618,1168.943115 456.685272,1179.156860 473.274872,1168.413818
	C521.632080,1137.098999 570.654236,1106.916504 622.832092,1082.246704
	C636.779907,1075.651978 651.011902,1069.658447 666.086487,1062.956421
	C668.909302,1070.286621 671.294556,1076.955322 674.032349,1083.476196
	C677.887939,1092.659668 681.786316,1101.838501 686.092163,1110.814941
	C688.658997,1116.166016 693.062927,1118.324707 699.458984,1118.306396
	C775.121399,1118.088867 850.784729,1118.169067 926.447815,1118.164429
	C941.600830,1118.163452 956.753845,1118.102417 971.906738,1118.136597
	C977.425354,1118.149170 981.025208,1115.630615 982.927002,1110.486816
	C985.578979,1103.313965 988.270325,1096.155396 990.983826,1089.005615
	C993.696167,1081.858887 996.422729,1074.717285 999.210938,1067.599976
	C1000.456299,1064.421021 1002.412781,1063.389893 1005.737244,1065.260620
	C1008.914307,1067.048340 1012.367004,1068.343384 1015.686523,1069.881104
	C1071.132568,1095.565552 1126.162231,1121.967041 1175.874146,1158.120361
	C1182.780518,1163.142944 1190.730957,1167.116699 1198.736206,1170.160156
	C1215.065796,1176.368408 1227.109619,1171.015259 1232.855957,1154.567993
	C1235.594849,1146.728760 1236.571533,1137.995483 1236.836060,1129.619385
	C1237.882202,1096.500000 1239.008667,1063.356934 1238.765625,1030.232422
	C1238.599731,1007.628784 1236.841187,984.979675 1234.634644,962.464600
	C1232.537109,941.063721 1222.333374,922.530518 1210.532959,905.024109
	C1183.834351,865.415344 1149.923950,832.087341 1116.671997,798.212830
	C1102.788208,784.069092 1088.731812,770.093811 1074.673218,756.123047
	C1072.222412,753.687561 1071.457275,751.159607 1071.774048,747.682922
	C1075.523071,706.536804 1077.782715,665.333069 1077.242310,623.978821
	C1076.776123,588.291809 1074.336060,552.801514 1069.191895,517.478821
	C1059.496826,450.904968 1040.246338,387.388184 1008.777222,327.769836
	C976.928467,267.432312 938.331055,211.986618 888.701172,164.809738
	C877.779114,154.427490 865.729431,145.026810 853.288818,136.502350
	C839.971008,127.376755 825.557617,127.922722 812.016113,136.891006
	C804.956116,141.566757 798.416809,147.028763 791.108337,152.605713
M715.552612,1434.091797
	C723.837280,1439.271729 731.902405,1437.624756 739.497864,1432.783813
	C744.194580,1429.790527 748.384705,1426.002075 753.049011,1422.379028
	C753.727417,1424.314453 754.408569,1426.165527 755.027405,1428.037231
	C766.385925,1462.391479 779.549927,1495.980469 799.267944,1526.523071
	C804.445251,1534.542358 810.714233,1542.179443 817.754761,1548.594971
	C827.377625,1557.363647 838.137634,1557.228149 848.052551,1548.753174
	C853.921387,1543.736694 859.185974,1537.683716 863.550720,1531.296143
	C879.503357,1507.950317 891.101318,1482.346558 901.005981,1455.958008
	C905.139404,1444.945312 908.925476,1433.802246 912.821594,1422.853394
	C918.443604,1426.789185 923.552063,1431.082642 929.291504,1434.222656
	C938.923157,1439.492188 947.780762,1438.130493 955.092651,1430.086426
	C959.515869,1425.220215 963.572876,1419.692383 966.455811,1413.806152
	C992.729858,1360.161499 998.465149,1304.336670 981.802490,1246.886841
	C972.281616,1214.060669 953.549561,1187.605103 922.741882,1170.875000
	C916.322510,1167.389160 909.664185,1165.378540 902.355042,1164.997070
	C856.091614,1162.582520 809.826477,1162.408936 763.584290,1165.196045
	C757.616455,1165.555908 751.304749,1167.091431 745.956177,1169.718628
	C713.563660,1185.629639 694.810303,1212.898804 684.144226,1246.363037
	C675.166016,1274.531982 673.262512,1303.500977 676.163330,1332.791260
	C679.077454,1362.215210 686.355713,1390.486694 700.948669,1416.401245
	C704.537292,1422.773926 710.201843,1427.977539 715.552612,1434.091797
z"/>
<path fill="#BFFF00" opacity="1.000000" stroke="none"
	d="
M791.375366,152.370682
	C798.416809,147.028763 804.956116,141.566757 812.016113,136.891006
	C825.557617,127.922722 839.971008,127.376755 853.288818,136.502350
	C865.729431,145.026810 877.779114,154.427490 888.701172,164.809738
	C938.331055,211.986618 976.928467,267.432312 1008.777222,327.769836
	C1040.246338,387.388184 1059.496826,450.904968 1069.191895,517.478821
	C1074.336060,552.801514 1076.776123,588.291809 1077.242310,623.978821
	C1077.782715,665.333069 1075.523071,706.536804 1071.774048,747.682922
	C1071.457275,751.159607 1072.222412,753.687561 1074.673218,756.123047
	C1088.731812,770.093811 1102.788208,784.069092 1116.671997,798.212830
	C1149.923950,832.087341 1183.834351,865.415344 1210.532959,905.024109
	C1222.333374,922.530518 1232.537109,941.063721 1234.634644,962.464600
	C1236.841187,984.979675 1238.599731,1007.628784 1238.765625,1030.232422
	C1239.008667,1063.356934 1237.882202,1096.500000 1236.836060,1129.619385
	C1236.571533,1137.995483 1235.594849,1146.728760 1232.855957,1154.567993
	C1227.109619,1171.015259 1215.065796,1176.368408 1198.736206,1170.160156
	C1190.730957,1167.116699 1182.780518,1163.142944 1175.874146,1158.120361
	C1126.162231,1121.967041 1071.132568,1095.565552 1015.686523,1069.881104
	C1012.367004,1068.343384 1008.914307,1067.048340 1005.737244,1065.260620
	C1002.412781,1063.389893 1000.456299,1064.421021 999.210938,1067.599976
	C996.422729,1074.717285 993.696167,1081.858887 990.983826,1089.005615
	C988.270325,1096.155396 985.578979,1103.313965 982.927002,1110.486816
	C981.025208,1115.630615 977.425354,1118.149170 971.906738,1118.136597
	C956.753845,1118.102417 941.600830,1118.163452 926.447815,1118.164429
	C850.784729,1118.169067 775.121399,1118.088867 699.458984,1118.306396
	C693.062927,1118.324707 688.658997,1116.166016 686.092163,1110.814941
	C681.786316,1101.838501 677.887939,1092.659668 674.032349,1083.476196
	C671.294556,1076.955322 668.909302,1070.286621 666.086487,1062.956421
	C651.011902,1069.658447 636.779907,1075.651978 622.832092,1082.246704
	C570.654236,1106.916504 521.632080,1137.098999 473.274872,1168.413818
	C456.685272,1179.156860 434.695618,1168.943115 433.039978,1149.146973
	C431.472778,1130.408081 430.000214,1111.587524 430.024353,1092.804932
	C430.073181,1054.863525 431.451447,1016.925842 431.740997,978.982422
	C431.998566,945.228027 444.238312,916.112610 465.785461,890.982544
	C487.559418,865.587891 510.166016,840.886780 532.940247,816.376526
	C552.553040,795.268616 572.889343,774.831909 592.979126,754.169861
	C595.469482,751.608582 596.504822,749.036621 596.211426,745.338684
	C593.485107,710.979675 590.304321,676.636841 588.621033,642.222473
	C587.590088,621.145447 588.089722,599.898499 589.397949,578.820740
	C592.721313,525.272949 602.729126,472.877411 619.036987,421.738037
	C647.260193,333.233215 691.107056,253.718506 755.544983,186.243073
	C766.799683,174.457870 779.224121,163.789764 791.375366,152.370682
M892.803589,457.700470
	C868.643555,444.379761 842.918152,439.982178 815.638428,443.860046
	C747.877563,453.492249 700.856873,521.294495 715.551758,588.311462
	C729.587341,652.321716 788.973267,692.880493 854.029724,682.887634
	C908.868042,674.464294 953.280518,625.098694 954.863770,569.772217
	C956.266418,520.756165 935.350952,483.506165 892.803589,457.700470
M1059.017700,829.604065
	C1045.560791,890.470520 1032.103882,951.336975 1018.636719,1012.250061
	C1075.871094,1033.050659 1128.453369,1061.975220 1180.000244,1094.926758
	C1180.000244,1091.978760 1180.023315,1090.349121 1179.996582,1088.720215
	C1179.724365,1072.071167 1179.423096,1055.422485 1179.171265,1038.772949
	C1178.813721,1015.126709 1178.312622,991.480286 1178.248169,967.832947
	C1178.225098,959.346497 1176.331055,951.485535 1171.606567,944.704041
	C1163.628418,933.251953 1155.785400,921.547363 1146.489624,911.203308
	C1124.126709,886.318420 1100.995483,862.122131 1078.073242,837.742981
	C1073.750977,833.145996 1069.002563,828.943359 1064.349121,824.669556
	C1063.500122,823.889832 1062.158203,823.646790 1060.769653,823.035278
	C1060.118408,825.336731 1059.627441,827.071472 1059.017700,829.604065
M649.000000,1011.214783
	C648.883728,1010.396484 648.881042,1009.542236 648.634949,1008.765015
	C632.197754,956.846619 619.776184,903.944580 609.806091,850.440491
	C608.263367,842.161133 606.675110,833.890259 604.933594,824.695190
	C602.873413,826.075745 601.414795,826.766174 600.319580,827.830505
	C586.358154,841.398499 571.840210,854.459656 558.671082,868.761353
	C539.622620,889.447937 521.395752,910.902283 503.150269,932.311951
	C494.658752,942.276123 489.565399,954.023132 488.642273,967.255737
	C487.889893,978.040283 486.902405,988.846436 486.935669,999.640259
	C487.022919,1027.944946 487.614929,1056.248169 487.994171,1084.552002
	C488.035034,1087.602295 487.999664,1090.653687 487.999664,1094.498047
	C539.752014,1062.244019 591.762634,1032.403442 649.000000,1011.214783
z"/>
<path fill="#BEFE01" opacity="1.000000" stroke="none"
	d="
M715.232361,1433.905273
	C710.201843,1427.977539 704.537292,1422.773926 700.948669,1416.401245
	C686.355713,1390.486694 679.077454,1362.215210 676.163330,1332.791260
	C673.262512,1303.500977 675.166016,1274.531982 684.144226,1246.363037
	C694.810303,1212.898804 713.563660,1185.629639 745.956177,1169.718628
	C751.304749,1167.091431 757.616455,1165.555908 763.584290,1165.196045
	C809.826477,1162.408936 856.091614,1162.582520 902.355042,1164.997070
	C909.664185,1165.378540 916.322510,1167.389160 922.741882,1170.875000
	C953.549561,1187.605103 972.281616,1214.060669 981.802490,1246.886841
	C998.465149,1304.336670 992.729858,1360.161499 966.455811,1413.806152
	C963.572876,1419.692383 959.515869,1425.220215 955.092651,1430.086426
	C947.780762,1438.130493 938.923157,1439.492188 929.291504,1434.222656
	C923.552063,1431.082642 918.443604,1426.789185 912.821594,1422.853394
	C908.925476,1433.802246 905.139404,1444.945312 901.005981,1455.958008
	C891.101318,1482.346558 879.503357,1507.950317 863.550720,1531.296143
	C859.185974,1537.683716 853.921387,1543.736694 848.052551,1548.753174
	C838.137634,1557.228149 827.377625,1557.363647 817.754761,1548.594971
	C810.714233,1542.179443 804.445251,1534.542358 799.267944,1526.523071
	C779.549927,1495.980469 766.385925,1462.391479 755.027405,1428.037231
	C754.408569,1426.165527 753.727417,1424.314453 753.049011,1422.379028
	C748.384705,1426.002075 744.194580,1429.790527 739.497864,1432.783813
	C731.902405,1437.624756 723.837280,1439.271729 715.232361,1433.905273
M783.873718,1361.638916
	C786.287292,1366.006958 789.058044,1370.218018 791.056458,1374.768433
	C803.827515,1403.848022 816.428467,1433.002197 829.086060,1462.131592
	C830.230469,1464.765381 831.378723,1467.397705 832.994019,1471.107422
	C838.659546,1457.708008 843.598999,1445.397583 849.032593,1433.309448
	C859.523560,1409.969604 869.808716,1386.513794 881.207764,1363.618164
	C885.264587,1355.469727 891.621948,1348.116089 898.161072,1341.644287
	C906.049988,1333.836548 915.289185,1335.812622 921.134399,1345.306030
	C922.876648,1348.135498 924.160950,1351.259766 926.028137,1353.994141
	C926.942383,1355.332886 928.711365,1356.087891 930.093506,1357.107178
	C930.774475,1355.721436 931.931641,1354.379272 932.063416,1352.943115
	C933.521179,1337.053223 935.836182,1321.155640 935.942139,1305.246948
	C936.140442,1275.493530 927.235657,1248.454102 907.413391,1225.768677
	C904.111877,1221.990356 899.083130,1217.971069 894.437683,1217.392212
	C854.961243,1212.472046 815.387146,1212.729126 775.785339,1216.512695
	C767.558716,1217.298462 761.351929,1220.824707 757.091553,1227.330566
	C750.736145,1237.035400 743.789062,1246.648804 739.327576,1257.241943
	C726.006104,1288.871582 728.452515,1321.726440 734.075317,1354.570923
	C734.234680,1355.501709 735.205078,1356.850708 735.965820,1356.975342
	C736.852356,1357.120483 738.312927,1356.388916 738.844788,1355.586914
	C740.585083,1352.963013 742.034668,1350.144287 743.563965,1347.382690
	C750.437500,1334.970825 760.232422,1333.370239 770.095398,1343.687256
	C775.112488,1348.935303 779.051819,1355.213745 783.873718,1361.638916
z"/>
<path fill="#4A1F60" opacity="1.000000" stroke="none"
	d="
M893.130859,457.866638
	C935.350952,483.506165 956.266418,520.756165 954.863770,569.772217
	C953.280518,625.098694 908.868042,674.464294 854.029724,682.887634
	C788.973267,692.880493 729.587341,652.321716 715.551758,588.311462
	C700.856873,521.294495 747.877563,453.492249 815.638428,443.860046
	C842.918152,439.982178 868.643555,444.379761 893.130859,457.866638
M772.221436,575.052185
	C779.635620,606.480530 803.638367,626.231262 834.339111,626.166077
	C861.273376,626.108887 884.998230,609.068298 893.584351,583.612488
	C902.164368,558.174866 893.723694,530.289307 872.430481,513.726013
	C851.445068,497.402130 821.532471,495.995056 799.528137,511.051666
	C777.354614,526.224060 768.570435,547.650330 772.221436,575.052185
z"/>
<path fill="#4A1F60" opacity="1.000000" stroke="none"
	d="
M1059.077148,829.205139
	C1059.627441,827.071472 1060.118408,825.336731 1060.769653,823.035278
	C1062.158203,823.646790 1063.500122,823.889832 1064.349121,824.669556
	C1069.002563,828.943359 1073.750977,833.145996 1078.073242,837.742981
	C1100.995483,862.122131 1124.126709,886.318420 1146.489624,911.203308
	C1155.785400,921.547363 1163.628418,933.251953 1171.606567,944.704041
	C1176.331055,951.485535 1178.225098,959.346497 1178.248169,967.832947
	C1178.312622,991.480286 1178.813721,1015.126709 1179.171265,1038.772949
	C1179.423096,1055.422485 1179.724365,1072.071167 1179.996582,1088.720215
	C1180.023315,1090.349121 1180.000244,1091.978760 1180.000244,1094.926758
	C1128.453369,1061.975220 1075.871094,1033.050659 1018.636719,1012.250061
	C1032.103882,951.336975 1045.560791,890.470520 1059.077148,829.205139
z"/>
<path fill="#4A1F60" opacity="1.000000" stroke="none"
	d="
M648.763428,1011.536011
	C591.762634,1032.403442 539.752014,1062.244019 487.999664,1094.498047
	C487.999664,1090.653687 488.035034,1087.602295 487.994171,1084.552002
	C487.614929,1056.248169 487.022919,1027.944946 486.935669,999.640259
	C486.902405,988.846436 487.889893,978.040283 488.642273,967.255737
	C489.565399,954.023132 494.658752,942.276123 503.150269,932.311951
	C521.395752,910.902283 539.622620,889.447937 558.671082,868.761353
	C571.840210,854.459656 586.358154,841.398499 600.319580,827.830505
	C601.414795,826.766174 602.873413,826.075745 604.933594,824.695190
	C606.675110,833.890259 608.263367,842.161133 609.806091,850.440491
	C619.776184,903.944580 632.197754,956.846619 648.634949,1008.765015
	C648.881042,1009.542236 648.883728,1010.396484 648.763428,1011.536011
z"/>
<path fill="#4A1E60" opacity="1.000000" stroke="none"
	d="
M783.676025,1361.332642
	C779.051819,1355.213745 775.112488,1348.935303 770.095398,1343.687256
	C760.232422,1333.370239 750.437500,1334.970825 743.563965,1347.382690
	C742.034668,1350.144287 740.585083,1352.963013 738.844788,1355.586914
	C738.312927,1356.388916 736.852356,1357.120483 735.965820,1356.975342
	C735.205078,1356.850708 734.234680,1355.501709 734.075317,1354.570923
	C728.452515,1321.726440 726.006104,1288.871582 739.327576,1257.241943
	C743.789062,1246.648804 750.736145,1237.035400 757.091553,1227.330566
	C761.351929,1220.824707 767.558716,1217.298462 775.785339,1216.512695
	C815.387146,1212.729126 854.961243,1212.472046 894.437683,1217.392212
	C899.083130,1217.971069 904.111877,1221.990356 907.413391,1225.768677
	C927.235657,1248.454102 936.140442,1275.493530 935.942139,1305.246948
	C935.836182,1321.155640 933.521179,1337.053223 932.063416,1352.943115
	C931.931641,1354.379272 930.774475,1355.721436 930.093506,1357.107178
	C928.711365,1356.087891 926.942383,1355.332886 926.028137,1353.994141
	C924.160950,1351.259766 922.876648,1348.135498 921.134399,1345.306030
	C915.289185,1335.812622 906.049988,1333.836548 898.161072,1341.644287
	C891.621948,1348.116089 885.264587,1355.469727 881.207764,1363.618164
	C869.808716,1386.513794 859.523560,1409.969604 849.032593,1433.309448
	C843.598999,1445.397583 838.659546,1457.708008 832.994019,1471.107422
	C831.378723,1467.397705 830.230469,1464.765381 829.086060,1462.131592
	C816.428467,1433.002197 803.827515,1403.848022 791.056458,1374.768433
	C789.058044,1370.218018 786.287292,1366.006958 783.676025,1361.332642
z"/>
<path fill="#BEFE00" opacity="1.000000" stroke="none"
	d="
M772.153442,574.628418
	C768.570435,547.650330 777.354614,526.224060 799.528137,511.051666
	C821.532471,495.995056 851.445068,497.402130 872.430481,513.726013
	C893.723694,530.289307 902.164368,558.174866 893.584351,583.612488
	C884.998230,609.068298 861.273376,626.108887 834.339111,626.166077
	C803.638367,626.231262 779.635620,606.480530 772.153442,574.628418
z"/>
</svg>`;

// ── Demo-CTA in Tool-Responses (sanft, rotierend, kein Hard-Block) ─────
// Nutzt das bestehende DEMO_RL-KV (separater Key-Prefix demo:calls:<token>).
// Skip die ersten 2 Calls, danach jeder 3. → eine kontextabhängige Pricing-Zeile.
const DEMO_CTA_SKIP = 2;
const DEMO_CTA_EVERY = 3;
const DEMO_MEMORY_TOOLS = new Set(["searchMemory","listMemories","countMemories","getChapterOverview","getHistory"]);
const DEMO_PIPELINE_TOOLS = new Set(["listTasks","getOpenTasks","listCampaigns","getCampaign","getCampaignLeadFields","listCampaignLeads"]);
async function maybeDemoCta(env, accessToken, toolName, client, lang) {
  if (!env.DEMO_RL || !accessToken) return null;
  let count = 0;
  try {
    count = parseInt((await env.DEMO_RL.get(`demo:calls:${accessToken}`)) || "0", 10) + 1;
    await env.DEMO_RL.put(`demo:calls:${accessToken}`, String(count), { expirationTtl: 3600 });
  } catch (e) { return null; }
  if (count <= DEMO_CTA_SKIP || count % DEMO_CTA_EVERY !== 0) return null;
  const url = `https://growthkit.tools/${lang || "en"}/pricing?utm_source=${encodeURIComponent(client || "other")}&utm_medium=mcp_demo&utm_campaign=tool_cta`;
  let msg;
  if (DEMO_MEMORY_TOOLS.has(toolName)) msg = `Demo workspace (read-only). Connect your own GTM memory: ${url}`;
  else if (DEMO_PIPELINE_TOOLS.has(toolName)) msg = `Demo data. See this on your real pipeline: ${url}`;
  else msg = `You're in the GrowthKit demo. Get your own workspace: ${url}`;
  return `\n\n— ${msg}`;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const BASE_URL = "https://mcp.growthkit.tools";

    // Read-only demo surface. ONLY these tools are exposed/allowed when a session
    // is is_demo. Every entry returns real data from the seeded demo workspace and
    // never calls a paid third-party API or performs a write/side-effect.
    // Deliberately EXCLUDED: all writes, all CRM tools (would return setup_required),
    // enrich*/find*/verifyEmail, scoreLeads, email_compose, sendNotification.
    const DEMO_TOOLS = new Set([
      "getChapterOverview", "searchMemory", "listMemories", "countMemories", "getHistory",
      "listTasks", "getOpenTasks",
      "listCampaigns", "getCampaign", "listCampaignLeads", "getCampaignLeadFields",
      "listDocuments", "getDocument", "listReminders",
    ]);

    // Direct Edge Function URLs — no n8n webhook proxy
    const EDGE_EMBED_URL = `${env.SUPABASE_URL}/functions/v1/n8n-embed`;
    const EDGE_SEARCH_URL = `${env.SUPABASE_URL}/functions/v1/n8n-search`;
    const EDGE_PROXY_URL = `${env.SUPABASE_URL}/functions/v1/n8n-proxy`;
    const EDGE_SCORE_LEADS_URL   = `${env.SUPABASE_URL}/functions/v1/score-leads`;
    const EDGE_GET_TOP_LEADS_URL = `${env.SUPABASE_URL}/functions/v1/get-top-leads`;
    const EDGE_EMAIL_COMPOSE_URL = `${env.SUPABASE_URL}/functions/v1/email-compose`;

    console.log("==== INCOMING REQUEST ====");
    console.log("PATH:", url.pathname, "METHOD:", request.method);

    const CORS_HEADERS = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization, MCP-Protocol-Version",
      "Access-Control-Max-Age": "86400",
    };

    // Set once per request in the tools/call demo path (C3). When present, the
    // next successful (non-error) tool result gets exactly one CTA text-block.
    let pendingDemoCta = null;
    function json(data, status = 200, extraHeaders = {}) {
      if (pendingDemoCta && data && data.result && Array.isArray(data.result.content) && !data.result.isError) {
        data.result.content.push({ type: "text", text: pendingDemoCta });
        pendingDemoCta = null; // append at most once
      }
      return new Response(JSON.stringify(data), {
        status,
        headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...CORS_HEADERS, ...extraHeaders },
      });
    }

    // Helper: call Edge Function directly
    async function callEdge(fnUrl, payload) {
      const res = await fetch(fnUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${env.N8N_AUTH_TOKEN}`,
        },
        body: JSON.stringify(payload),
      });
      const data = await res.json();
      return { data, ok: res.ok, status: res.status };
    }

    // Helper: direct PostgREST RPC call with service_role.
    // Mirrors the Reminders fetch pattern (apikey + Bearer service_role); the
    // RPC resolves/hashes the user token itself, so userToken is passed as a
    // plain p_token argument, never as an auth header.
    async function callRpc(fn, body) {
      const res = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
        method: "POST",
        headers: sbHeaders(env, { "Content-Type": "application/json" }),
        body: JSON.stringify(body),
      });
      let data;
      try { data = await res.json(); } catch { data = await res.text(); }
      return { data, ok: res.ok };
    }

    // Resolve a gk_ user token to its user_id (mirrors background.js resolveUserId).
    async function resolveUserId(tok) {
      const { data, ok } = await callRpc("resolve_user_token", { p_token: tok });
      return ok && typeof data === "string" ? data : null;
    }

    // Helper: format search results into readable resource content
    function formatResourceContent(title, searchResponse) {
      const results = searchResponse?.results || [];
      if (results.length === 0) {
        return title + "\n\nNo data stored yet. Use the tools to save " + title.toLowerCase() + " information.";
      }
      let content = title + "\n" + "=".repeat(title.length) + "\n\n";
      for (const r of results) {
        const tags = r.metadata?.tags || "";
        content += r.content + "\n";
        if (tags) content += "[Tags: " + tags + "]\n";
        content += "\n---\n\n";
      }
      return content.trim();
    }

    // Helper: format chapter overview into readable content
    function formatChapterOverview(overviewResponse) {
      const chapters = overviewResponse?.chapters || {};
      const total = overviewResponse?.total || 0;
      const names = {
        icp: "ICP (Ideal Customer Profile)",
        strategy: "Strategy & Roadmap",
        campaigns: "Campaigns & Content",
        analytics: "Analytics & KPIs",
        brand: "Brand & Messaging",
        competitors: "Competitors & Battlecards",
        learnings: "Learnings & Insights",
        pipeline: "Pipeline & Deals",
        signals: "Signals & Intent",
        playbook: "Playbook & System Config",
        general: "General",
      };
      let content = "Memory Chapter Overview\n=======================\n\nTotal memories: " + total + "\n\n";
      for (const [key, name] of Object.entries(names)) {
        const count = chapters[key] || 0;
        content += name + ": " + count + " memories\n";
      }
      return content;
    }

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    if (url.pathname === "/favicon.svg" || url.pathname === "/favicon.ico") {
      return new Response(FAVICON_SVG, { headers: { "content-type": "image/svg+xml", "cache-control": "public, max-age=86400" } });
    }

    // Glama Connector-Ownership-Verify. Statische, öffentliche Datei — kein Secret.
    // Glama crawlt /.well-known/glama.json und matcht die maintainer-Email gegen
    // die E-Mail des Glama-Accounts.
    if (request.method === "GET" && url.pathname === "/.well-known/glama.json") {
      return new Response(
        JSON.stringify({
          "$schema": "https://glama.ai/mcp/schemas/connector.json",
          maintainers: [{ email: "team@growthkit.tools" }],
        }),
        {
          headers: {
            "content-type": "application/json",
            "cache-control": "public, max-age=3600",
            ...CORS_HEADERS,
          },
        }
      );
    }

    async function sha256Hex(input) {
      const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
      return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, "0")).join("");
    }

    if (request.method === "GET" && url.pathname.startsWith("/px/") && url.pathname.endsWith(".gif")) {
      const tracking_id = url.pathname.slice(4, -4);
      const ip = request.headers.get("CF-Connecting-IP") || "";
      const user_agent = request.headers.get("User-Agent") || "";

      ctx.waitUntil((async () => {
        const ip_hash = await sha256Hex(ip + (env.PIXEL_SALT || ""));
        await fetch(`${env.SUPABASE_URL}/rest/v1/gmail_opens`, {
          method: "POST",
          headers: sbHeaders(env, { "Content-Type": "application/json", Prefer: "return=minimal" }),
          body: JSON.stringify({ tracking_id, ip_hash, user_agent }),
        }).catch(() => {});
      })());

      const GIF = new Uint8Array([
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00,
        0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0x21,
        0xf9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2c, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44,
        0x01, 0x00, 0x3b,
      ]);
      return new Response(GIF, {
        status: 200,
        headers: {
          "Content-Type": "image/gif",
          "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
        },
      });
    }

    if (request.method === "GET" && url.pathname === "/") {
      return json({ name: "growthkit-mcp", version: "1.10.0", protocol: "2025-11-25", status: "running" });
    }

    if (request.method === "POST" && url.pathname === "/") {
      const body = await request.json();
      const { method, params = {}, id } = body;

      const authHeader = request.headers.get("authorization");
      const token = authHeader?.startsWith("Bearer ") ? authHeader.substring(7) : null;
      const isInitialize = method === "initialize";
      const isInitialized = method === "initialized";
      // Discovery methods are public (no token) so registry/directory scanners
      // (Smithery, Glama, mcp.so, MCP-Inspector without login) can enumerate
      // capabilities without running the OAuth flow. Execution methods
      // (tools/call, prompts/get, resources/read) stay gated below.
      const PUBLIC_METHODS = new Set(["initialize", "initialized", "ping", "tools/list", "prompts/list", "resources/list"]);
      const requiresAuth = !PUBLIC_METHODS.has(method);

      // Point OAuth-capable clients at the resource metadata so they can find
      // the auth server when they hit a gated 401.
      const WWW_AUTH = { "WWW-Authenticate": `Bearer resource_metadata="${BASE_URL}/.well-known/oauth-protected-resource"` };

      if (requiresAuth && !token) {
        return json({ jsonrpc: "2.0", id, error: { code: -32000, message: "Authentication required" } }, 401, WWW_AUTH);
      }

      let userToken = null;
      let isDemo = false;
      let demoClient = "other", demoLang = "en";
      // Resolve the token whenever one is present (except on the handshake), so an
      // authenticated discovery call (e.g. tools/list) still gets role-based
      // filtering. A public method with a missing/invalid token falls through
      // unauthenticated; a gated method with an invalid token is rejected.
      if (token && !isInitialize && !isInitialized) {
        try {
          const tokenLookup = await fetch(
            `${env.SUPABASE_URL}/rest/v1/oauth_tokens?access_token=eq.${token}&select=*`,
            { headers: sbHeaders(env) }
          );
          if (tokenLookup.ok) {
            const tokenRows = await tokenLookup.json();
            if (tokenRows.length && Number(tokenRows[0].expires_at) > Date.now()) {
              userToken = tokenRows[0].user_token || null;
              isDemo = tokenRows[0].is_demo === true;
              demoClient = tokenRows[0].mcp_client || "other";
              demoLang   = tokenRows[0].lang || "en";
            }
          }
        } catch (e) { console.error("Token lookup error:", e); }
        if (!userToken && requiresAuth) {
          return json({ jsonrpc: "2.0", id, error: { code: -32000, message: "Invalid or expired token" } }, 401, WWW_AUTH);
        }
      }

      // Derive role from token prefix
      let userRole = "admin";
      if (userToken && userToken.startsWith("gk_team_")) userRole = "team";
      else if (userToken && userToken.startsWith("gk_view_")) userRole = "view";
      // is_demo wins over any prefix-derived role: a demo session is always read-only.
      if (isDemo) userRole = "demo";

      // Chapter-level permissions per role
      const chapterPerms = {
        admin: {
          read: ["icp", "strategy", "campaigns", "analytics", "brand", "competitors", "learnings", "general", "pipeline", "playbook"],
          write: ["icp", "strategy", "campaigns", "analytics", "brand", "competitors", "learnings", "general", "pipeline", "playbook"],
        },
        team: {
          read: ["icp", "strategy", "competitors", "campaigns", "analytics", "learnings", "general", "pipeline", "signals", "playbook"],
          write: ["competitors", "campaigns", "analytics", "learnings", "general", "pipeline", "signals"],
        },
        view: {
          read: ["icp", "strategy", "brand", "competitors", "campaigns", "analytics", "learnings"],
          write: [],
        },
        demo: {
          read: ["icp", "strategy", "campaigns", "analytics", "brand", "competitors", "learnings", "general", "pipeline", "signals", "playbook"],
          write: [],
        },
      };

      if (method === "initialize") {
        return json({
          jsonrpc: "2.0", id,
          result: {
            protocolVersion: "2025-11-25",
            capabilities: { prompts: { listChanged: false }, resources: { listChanged: false }, tools: { listChanged: false } },
            serverInfo: { name: "growthkit-mcp", title: "GrowthKit Memory Assistant", version: "1.10.0" },
          },
        });
      }

      if (method === "initialized") {
        return new Response("", { status: 200, headers: CORS_HEADERS });
      }

      if (method === "ping") {
        return json({ jsonrpc: "2.0", id, result: {} });
      }

      // =========================================================
      // PROMPTS — Playbook System
      // =========================================================

      // Prompt-Metadaten (public-safe). Die eigentlichen Bodies liegen privat in der
      // Edge (n8n-embed action 'get_prompt') hinter einem growth/pro-Abo-Gate und
      // werden bei prompts/get live geladen.
      const PLAYBOOK_PROMPTS = {
        "onboarding": {
          name: "onboarding",
          title: "GrowthKit Onboarding \u2014 Set Up Your Marketing Memory",
          description: "1. Set up your marketing memory",
          arguments: [],
        },
        "icp-workshop": {
          name: "icp-workshop",
          title: "ICP Workshop \u2014 Define Your Ideal Customer",
          description: "2. Define or refine your ICP",
          arguments: [{ name: "mode", description: "Either create (start from scratch) or review (validate existing ICP). Default: auto-detect based on ICP chapter content.", required: false }],
        },
        "competitor-analysis": {
          name: "competitor-analysis",
          title: "Competitor Analysis \u2014 Research & Profile a Competitor",
          description: "3. Analyze a competitor",
          arguments: [{ name: "competitor_name", description: "Name of the competitor to analyze.", required: false }],
        },
        "campaign-brief": {
          name: "campaign-brief",
          title: "Campaign Brief \u2014 Data-Driven Campaign Planning",
          description: "4. Plan a data-driven campaign",
          arguments: [
            { name: "campaign_type", description: "Type of campaign: paid-ads, content, email, event, launch, social, or other.", required: false },
            { name: "goal", description: "Primary campaign goal: awareness, leads, pipeline, activation, retention.", required: false },
          ],
        },
        "content-brief": {
          name: "content-brief",
          title: "Content Brief \u2014 Create SEO/Thought Leadership Content",
          description: "5. Create a content brief",
          arguments: [
            { name: "content_type", description: "Type: blog-post, whitepaper, case-study, linkedin-post, newsletter, landing-page.", required: false },
            { name: "topic", description: "Topic or theme for the content.", required: false },
          ],
        },
        "weekly-review": {
          name: "weekly-review",
          title: "Weekly Review \u2014 Marketing Performance Check",
          description: "6. Weekly performance check-in",
          arguments: [],
        },
      };

      if (method === "prompts/list") {
        const roleFilter = {
          admin: () => true,
          team: (p) => ["onboarding", "campaign-brief", "content-brief", "weekly-review"].includes(p.name),
          view: () => false,
        };
        const filterFn = roleFilter[userRole] || (() => false); // demo/unbekannt → keine Prompts
        const promptList = Object.values(PLAYBOOK_PROMPTS)
          .filter(filterFn)
          .map(p => ({ name: p.name, title: p.title, description: p.description, arguments: p.arguments || [] }));
        // Omit nextCursor entirely (not null) — MCP spec treats it as an optional
        // string; strict parsers (Smithery) reject null. No pagination here.
        return json({ jsonrpc: "2.0", id, result: { prompts: promptList } });
      }

      if (method === "prompts/get") {
        // Defense-in-Depth: Demo sieht keine Prompts (prompts/list ist für Demo
        // ohnehin leer, aber ein direkter get soll auch nichts liefern).
        if (isDemo) {
          return json({ jsonrpc: "2.0", id, error: { code: -32000, message: "Prompts are not available in the GrowthKit demo." } });
        }

        const promptName = params.name;
        const prompt = PLAYBOOK_PROMPTS[promptName];
        if (!prompt) {
          return json({ jsonrpc: "2.0", id, error: { code: -32602, message: "Unknown prompt: " + promptName + ". Available: " + Object.keys(PLAYBOOK_PROMPTS).join(", ") } });
        }

        // Body privat aus der Edge holen (Abo-Gate dort: growth/pro bekommen die
        // Methodik, free einen Upgrade-Hinweis als Body — beides kommt als String).
        let bodyText;
        try {
          const { data, ok } = await callEdge(EDGE_EMBED_URL, {
            action: "get_prompt",
            user_token: userToken,
            prompt_name: promptName,
          });
          if (!ok || !data || typeof data.body !== "string") {
            return json({ jsonrpc: "2.0", id, error: { code: -32000, message: "Failed to load prompt body" } });
          }
          bodyText = data.body;
        } catch (e) {
          return json({ jsonrpc: "2.0", id, error: { code: -32000, message: "Prompt fetch error: " + e.message } });
        }

        // Platzhalter-Ersetzung bleibt im Worker (z. B. {{mode}}, {{competitor_name}}).
        if (params.arguments) {
          for (const [key, value] of Object.entries(params.arguments)) {
            bodyText = bodyText.replace(new RegExp("\\{\\{" + key + "\\}\\}", "g"), value);
          }
        }

        return json({
          jsonrpc: "2.0", id,
          result: {
            title: prompt.title,
            description: prompt.description,
            messages: [{ role: "user", content: { type: "text", text: bodyText } }],
          },
        });
      }

      // -------------------------------------------------------
      // tools/list
      // -------------------------------------------------------
      if (method === "tools/list") {
        const CHAPTERS_INSTRUCTION =
          "IMPORTANT \u2014 Chapter System: Every memory MUST be classified into exactly one chapter via metadata.chapter. " +
          "Available chapters: icp, strategy, campaigns, analytics, brand, competitors, learnings, general, pipeline, signals, playbook. " +
          "Always analyze the content and pick the most specific chapter. Use general only as a last resort.";

        const PLAYBOOK_INSTRUCTION =
          " PLAYBOOK SYSTEM: Available playbooks: icp-workshop, onboarding, campaign-brief, weekly-review, competitor-analysis, content-brief. " +
          "When the user asks to do any of these tasks, use prompts/get to load the full playbook and follow its steps.";

        const AUTO_TAG_INSTRUCTION =
          " AUTO-TAGGING: Before saving ANY memory, search the playbook chapter for 'tag-taxonomy' to load the current tag taxonomy. " +
          "Then add 3-7 relevant tags as a comma-separated string in metadata.tags " +
          "(e.g. metadata: { chapter: 'campaigns', tags: 'saas,series-a,dach,linkedin,demand-gen' }). " +
          "Pick the most specific tags from the taxonomy. You may add 1-2 free-form tags if needed. " +
          "For batch embeds, tag each item individually.";

        // Shared output schema for the ICE task tools (listTasks / getOpenTasks).
        // Nullable columns use ["type","null"] unions; unlisted columns (steps,
        // timestamps, etc.) pass through as permitted additional properties.
        const TASK_ITEM_SCHEMA = {
          type: "object",
          properties: {
            id:                   { type: ["string", "number"] },
            title:                { type: "string" },
            status:               { type: "string", description: "open | in_progress | done | dropped." },
            bucket:               { type: ["string", "null"], description: "now | next | later." },
            impact:               { type: ["integer", "null"] },
            confidence:           { type: ["number", "null"] },
            effort_constraint:    { type: ["integer", "null"] },
            effort_nonconstraint: { type: ["integer", "null"] },
            owner:                { type: ["string", "null"] },
            ice_score:            { type: ["number", "null"], description: "Computed ICE score (GENERATED column)." },
            detail:               { type: ["string", "null"] },
          },
          required: ["id", "title", "status"],
        };
        const TASK_LIST_OUTPUT_SCHEMA = {
          type: "object",
          properties: { tasks: { type: "array", description: "Tasks ranked by ICE (highest first).", items: TASK_ITEM_SCHEMA } },
          required: ["tasks"],
        };

        const allTools = [
          {
            name: "embedMemory",
            title: "Save Memory",
            description: "Store knowledge into long-term memory. Supports single items and batch embedding (max 50). " + CHAPTERS_INSTRUCTION + " BEFORE STORING: Search target chapter first to check for duplicates. QUALITY: 50-300 words, specific and factual, one concept per memory." + AUTO_TAG_INSTRUCTION + PLAYBOOK_INSTRUCTION,
            inputSchema: {
              type: "object",
              properties: {
                content: { type: "string", description: "Text content to store (for single embed)." },
                items: { type: "array", description: "Batch embed: array of {content, metadata}. Max 50. Each MUST include metadata.chapter.", items: { type: "object", required: ["content"], properties: { content: { type: "string" }, metadata: { type: "object", additionalProperties: { type: "string" } } } } },
                metadata: { type: "object", description: "REQUIRED: Must include chapter key.", additionalProperties: { type: "string" } },
              },
            },
          },
          {
            name: "searchMemory",
            title: "Search Memory",
            description: "Search long-term memory using semantic similarity. ALWAYS SEARCH BEFORE ANSWERING marketing/strategy questions. Use short, specific keywords as queries. Available chapters: icp, strategy, campaigns, analytics, brand, competitors, learnings, general, pipeline, signals, playbook. TAG FILTERING: Memories are auto-tagged. Use metadata_filter with tags key to filter (e.g. metadata_filter: { chapter: 'campaigns', tags: 'linkedin' }).",
            inputSchema: {
              type: "object",
              required: ["query"],
              properties: {
                query: { type: "string", description: "Search keywords — short and specific." },
                metadata_filter: { type: "object", description: "Filter by metadata. Use chapter to search within a specific chapter.", additionalProperties: { type: "string" } },
                match_threshold: { type: "number", description: "Min similarity (0-1). Default: 0.5." },
                limit: { type: "integer", description: "Max results. Default: 10." },
              },
            },
          },
          {
            name: "listMemories",
            title: "List Memories",
            description: "List stored memories with pagination. Filter by chapter using metadata_filter.chapter.",
            inputSchema: {
              type: "object",
              properties: {
                limit: { type: "integer", description: "Max results. Default: 50." },
                offset: { type: "integer", description: "Pagination offset. Default: 0." },
                metadata_filter: { type: "object", description: "Optional metadata filters. Use chapter to list within a specific chapter.", additionalProperties: { type: "string" } },
              },
            },
          },
          {
            name: "updateMemory",
            title: "Update Memory",
            description: "Update content or metadata of a stored memory. Use to enrich, fix, or reclassify. You MUST provide a change_reason explaining WHAT changed and WHY. The reason is stored in the version history audit log.",
            inputSchema: {
              type: "object",
              required: ["embedding_id", "change_reason"],
              properties: {
                embedding_id: { type: "string", description: "ID of the memory to update." },
                new_content: { type: "string", description: "Updated text content." },
                new_metadata: { type: "object", description: "Optional metadata to replace, e.g. chapter or tags.", additionalProperties: { type: "string" } },
                change_reason: { type: "string", description: "REQUIRED: Why this memory is being updated, e.g. 'Added Q2 metrics', 'Fixed company name', 'User requested update'. Stored in audit log." },
              },
            },
          },
          {
            name: "deleteMemories",
            title: "Delete Memories",
            description: "Delete memories by IDs. Always confirm with user first. You MUST provide a change_reason explaining WHY these memories should be deleted. The reason is stored in the version history audit log.",
            inputSchema: {
              type: "object",
              required: ["embedding_ids", "change_reason"],
              properties: {
                embedding_ids: { type: "array", description: "IDs of the memories to delete (from searchMemory/listMemories).", items: { type: "string" } },
                change_reason: { type: "string", description: "REQUIRED: Why these memories are being deleted, e.g. 'Outdated', 'Duplicate', 'User requested cleanup'. Stored in audit log." },
              },
            },
          },
          {
            name: "clearMemories",
            title: "Clear All Memories",
            description: "Delete ALL memories. Irreversible. Always ask for explicit confirmation. You MUST provide a change_reason.",
            inputSchema: {
              type: "object",
              required: ["change_reason"],
              properties: {
                change_reason: { type: "string", description: "REQUIRED: Why all memories should be cleared. Stored in audit log." },
              },
            },
          },
          {
            name: "countMemories",
            title: "Count Memories",
            description: "Count memories, optionally filtered by chapter via metadata_filter.chapter.",
            inputSchema: {
              type: "object",
              properties: { metadata_filter: { type: "object", description: "Optional metadata filters. Use chapter to count within a specific chapter.", additionalProperties: { type: "string" } } },
            },
            outputSchema: {
              type: "object",
              properties: {
                count: { type: "integer", description: "Number of matching memories." },
                chapter: { type: "string", description: "Chapter the count was filtered to, if any." },
              },
              required: ["count"],
            },
          },
          {
            name: "getChapterOverview",
            title: "Chapter Overview",
            description: "Get memory count per chapter. Use as FIRST STEP in new conversations or reviews.",
            inputSchema: { type: "object", properties: {} },
            outputSchema: {
              type: "object",
              properties: {
                chapters: {
                  type: "array",
                  description: "Per-chapter memory counts (readable chapters only).",
                  items: {
                    type: "object",
                    properties: {
                      chapter: { type: "string" },
                      count: { type: "integer" },
                    },
                    required: ["chapter", "count"],
                  },
                },
                total: { type: "integer", description: "Total memory count across readable chapters." },
              },
              required: ["chapters"],
            },
          },
          {
            name: "uploadDocument",
            title: "Upload Document",
            description: "Upload a file to GrowthKit document storage. Optionally extracts text and embeds insights.",
            inputSchema: {
              type: "object",
              required: ["file_base64", "filename", "mime_type"],
              properties: {
                file_base64: { type: "string", description: "Base64-encoded file content." },
                filename: { type: "string", description: "Filename with extension." },
                mime_type: { type: "string", description: "MIME type." },
                category: { type: "string", enum: ["battlecards", "reports", "uploads", "exports", "templates", "presentations"], description: "Optional storage category." },
                title: { type: "string", description: "Optional document title. Defaults to the filename." },
                description: { type: "string", description: "Optional short description of the document." },
                chapter: { type: "string", description: "Optional memory chapter to associate extracted insights with." },
                extract_insights: { type: "boolean", description: "If true, extract text and embed insights into memory. Default: false." },
              },
            },
          },
          {
            name: "listDocuments",
            title: "List Documents",
            description: "List stored documents with optional filtering by category or chapter.",
            inputSchema: {
              type: "object",
              properties: {
                category: { type: "string", description: "Optional: filter by storage category." },
                chapter: { type: "string", description: "Optional: filter by associated memory chapter." },
                limit: { type: "integer", description: "Max results. Default: 50." },
                offset: { type: "integer", description: "Pagination offset. Default: 0." },
              },
            },
          },
          {
            name: "getDocument",
            title: "Get Document",
            description: "Get a specific document with fresh download URL and linked insights.",
            inputSchema: {
              type: "object",
              required: ["document_id"],
              properties: { document_id: { type: "string", description: "ID of the document (from listDocuments)." } },
            },
          },
          {
            name: "deleteDocument",
            title: "Delete Document",
            description: "Delete a document and its associated insights.",
            inputSchema: {
              type: "object",
              required: ["document_id"],
              properties: { document_id: { type: "string", description: "ID of the document to delete (from listDocuments)." } },
            },
          },
          {
            name: "createReminder",
            title: "Create Reminder",
            description: "Schedule a reminder. Convert relative times to ISO 8601.",
            inputSchema: {
              type: "object",
              required: ["title", "remind_at"],
              properties: {
                title: { type: "string", description: "Short reminder title." },
                description: { type: "string", description: "Optional reminder details." },
                remind_at: { type: "string", description: "When to remind, ISO 8601 (convert relative times first)." },
                repeat: { type: "string", enum: ["none", "daily", "weekly", "monthly"], description: "Repeat interval: none | daily | weekly | monthly. Default: none." },
                channel: { type: "string", enum: ["email", "slack", "webhook"], description: "Delivery channel: email | slack | webhook." },
                channel_target: { type: "string", description: "Optional channel target, e.g. email address or webhook URL." },
                task_id: { type: "string", description: "Optional: link this reminder to a task (task UUID). Linked reminders are auto-cancelled when the task is marked done/dropped." },
              },
            },
          },
          {
            name: "listReminders",
            title: "List Reminders",
            description: "List reminders. Filter by status.",
            inputSchema: {
              type: "object",
              properties: {
                status: { type: "string", enum: ["pending", "sent", "cancelled", "all"], description: "Filter by status: pending | sent | cancelled | all. Default: pending." },
                limit: { type: "integer", description: "Max results. Default: 50." },
                task_id: { type: "string", description: "Optional: only reminders linked to this task." },
              },
            },
            outputSchema: {
              type: "object",
              properties: {
                reminders: {
                  type: "array",
                  description: "Matching reminders, ordered by remind_at ascending.",
                  items: {
                    type: "object",
                    properties: {
                      id: { type: ["string", "number"] },
                      title: { type: "string" },
                      remind_at: { type: "string", description: "ISO 8601 timestamp." },
                      status: { type: "string", description: "pending | sent | cancelled." },
                    },
                    required: ["id", "title", "remind_at", "status"],
                  },
                },
              },
              required: ["reminders"],
            },
          },
          {
            name: "cancelReminder",
            title: "Cancel Reminder",
            description: "Cancel a pending reminder by ID.",
            inputSchema: {
              type: "object",
              required: ["reminder_id"],
              properties: { reminder_id: { type: "string", description: "ID of the pending reminder to cancel (from listReminders)." } },
            },
          },
          // === NEW: Memory Versioning Tools ===
{
  name: "getHistory",
  title: "Memory Version History",
  description: "Get the version history of a specific memory. Shows all previous versions with timestamps and who made changes.",
  inputSchema: {
    type: "object",
    required: ["embedding_id"],
    properties: {
      embedding_id: { type: "string", description: "ID of the memory to get history for." },
    },
  },
},
{
  name: "restoreVersion",
  title: "Restore Memory Version",
  description: "Restore a memory to a previous version. Works for both existing and deleted memories. Use version_id from getHistory or listDeleted results.",
  inputSchema: {
    type: "object",
    required: ["version_id"],
    properties: {
      version_id: { type: "string", description: "The version ID (restore_id) to restore to. Get this from getHistory or listDeleted." },
    },
  },
},
{
  name: "listDeleted",
  title: "List Deleted Memories",
  description: "List recently deleted memories that can be restored. Shows content preview and deletion info.",
  inputSchema: {
    type: "object",
    properties: {
      limit: { type: "integer", description: "Max results. Default: 20." },
    },
  },
},
// === NEW: Team & Notification Tools ===
{
  name: "listTeam",
  title: "List Team Members",
  description: "List all team members (token holders) for your account. Shows display names, roles, and identifies which token is yours.",
  inputSchema: { type: "object", properties: {} },
},
{
  name: "sendNotification",
  title: "Send Notification",
  description: "Send a notification to a team member. First use listTeam to find the recipient. For 2-person teams, the recipient is auto-resolved.",
  inputSchema: {
    type: "object",
    required: ["message"],
    properties: {
      message: { type: "string", description: "The notification message to send." },
      to_prefix: { type: "string", description: "Recipient's token_prefix or display_name from listTeam." },
      context: { type: "object", description: "Optional context, e.g. {chapter: 'icp'}.", additionalProperties: { type: "string" } },
      broadcast: { type: "boolean", description: "If true, sends to ALL team members. Default: false." },
    },
  },
},
{
  name: "checkNotifications",
  title: "Check Notifications",
  description: "Check for unread notifications (direct messages and broadcasts).",
  inputSchema: { type: "object", properties: {} },
},
          // === CRM Tools (via n8n-proxy) ===
        {
          name: "crmSearchCompany",
          title: "CRM: Search Company",
          description: "Search CRM for a company by name. ALWAYS search before creating to avoid duplicates.",
          inputSchema: { type: "object", required: ["term"], properties: {
            term: { type: "string", description: "Company name or keyword to search for." },
            limit: { type: "integer", description: "Max results. Default: 10." },
          }},
        },
        {
          name: "crmGetCompany",
          title: "CRM: Get Company",
          description: "Get full company details by ID. Returns name, domain, industry, employees, address, CRM link.",
          inputSchema: { type: "object", required: ["id"], properties: {
            id: { type: "string", description: "Company ID from CRM." },
          }},
        },
        {
          name: "crmCreateCompany",
          title: "CRM: Create Company",
          description: "Create a new company. ALWAYS search first to avoid duplicates.",
          inputSchema: { type: "object", required: ["name"], properties: {
            name: { type: "string", description: "Company name." },
            address: { type: "string", description: "Company address." },
          }},
        },
        {
          name: "crmGetCompanyDeals",
          title: "CRM: Get Company Deals",
          description: "Get all deals linked to a company.",
          inputSchema: { type: "object", required: ["id"], properties: {
            id: { type: "string", description: "Company ID." },
          }},
        },
        {
          name: "crmGetCompanyContacts",
          title: "CRM: Get Company Contacts",
          description: "Get all contacts linked to a company.",
          inputSchema: { type: "object", required: ["id"], properties: {
            id: { type: "string", description: "Company ID." },
          }},
        },
        {
          name: "crmSearchContact",
          title: "CRM: Search Contact",
          description: "Search CRM for a contact by name.",
          inputSchema: { type: "object", required: ["term"], properties: {
            term: { type: "string", description: "Contact name or keyword." },
            limit: { type: "integer", description: "Max results. Default: 10." },
          }},
        },
        {
  name: "crmListCompanies",
  title: "CRM: List Companies",
  description: "List companies from CRM with structured filters. Use for segment queries like 'all pharma companies with 50-200 employees in DACH'. All filter fields optional. Returns companies with id, name, industry, employees, country, and pagination info. Unlike crmSearchCompany (which does fuzzy name search), this does precise structured filtering.",
  inputSchema: {
    type: "object",
    properties: {
      filter: {
        type: "object",
        description: "Filter object. All fields optional.",
        properties: {
          employees: {
            type: "object",
            properties: {
              min: { type: "integer", description: "Minimum employee count (inclusive)" },
              max: { type: "integer", description: "Maximum employee count (inclusive)" },
            },
          },
          industry: {
            type: "object",
            properties: {
              contains: { type: "string", description: "Substring match (case-insensitive)" },
              in: { type: "array", items: { type: "string" }, description: "Exact match on any value in list" },
            },
          },
          country: {
            type: "object",
            properties: {
              in: { type: "array", items: { type: "string" }, description: "ISO country codes, e.g. ['DE','AT','CH']" },
            },
          },
          city: {
            type: "object",
            properties: {
              in: { type: "array", items: { type: "string" } },
            },
          },
          name: {
            type: "object",
            properties: {
              contains: { type: "string" },
            },
          },
          has_deals: { type: "boolean" },
          limit: { type: "integer", description: "Max results (1-200). Default: 50" },
          offset: { type: "integer", description: "Pagination offset. Default: 0" },
          order_by: { type: "string", enum: ["name", "employees", "created_at", "updated_at"] },
          order_dir: { type: "string", enum: ["asc", "desc"] },
        },
      },
    },
  },
},
{
  name: "crmListPeople",
  title: "CRM: List People",
  description: "List people/contacts from CRM with structured filters. Use for segment queries like 'all CEOs in pipeline companies'. All filter fields optional.",
  inputSchema: {
    type: "object",
    properties: {
      filter: {
        type: "object",
        description: "Filter object. All fields optional.",
        properties: {
          job_title: {
            type: "object",
            properties: {
              contains: { type: "string" },
              in: { type: "array", items: { type: "string" } },
            },
          },
          seniority: {
            type: "object",
            properties: {
              in: { type: "array", items: { type: "string", enum: ["executive", "director", "manager", "senior", "individual"] } },
            },
          },
          company_id: { type: "string", description: "Filter to contacts of a specific company" },
          department: {
            type: "object",
            properties: {
              in: { type: "array", items: { type: "string" } },
            },
          },
          country: {
            type: "object",
            properties: {
              in: { type: "array", items: { type: "string" } },
            },
          },
          has_email: { type: "boolean" },
          limit: { type: "integer" },
          offset: { type: "integer" },
          order_by: { type: "string", enum: ["name", "created_at", "updated_at"] },
          order_dir: { type: "string", enum: ["asc", "desc"] },
        },
      },
    },
  },
},
        {
          name: "crmGetContact",
          title: "CRM: Get Contact",
          description: "Get full contact details by ID.",
          inputSchema: { type: "object", required: ["id"], properties: {
            id: { type: "string", description: "Contact ID." },
          }},
        },
        {
          name: "crmCreateContact",
          title: "CRM: Create Contact",
          description: "Create a new contact. ALWAYS pass company_id when the company exists.",
          inputSchema: { type: "object", required: ["name"], properties: {
            name: { type: "string", description: "Full name." },
            email: { type: "string", description: "Email address." },
            phone: { type: "string", description: "Phone number." },
            company_id: { type: "string", description: "Company ID. REQUIRED when company exists." },
          }},
        },
        {
          name: "crmGetPipelines",
          title: "CRM: Get Pipelines",
          description: "Get all pipelines with stages. ALWAYS call before creating deals to get valid stage_id.",
          inputSchema: { type: "object", properties: {} },
        },
        {
          name: "crmCreateDeal",
          title: "CRM: Create Deal",
          description: "Create a new deal. Requires title + stage_id. MUST call crmGetPipelines first.",
          inputSchema: { type: "object", required: ["title", "stage_id"], properties: {
            title: { type: "string", description: "Deal title." },
            stage_id: { type: "string", description: "Stage ID from crmGetPipelines." },
            value: { type: "number", description: "Deal value." },
            currency: { type: "string", description: "Currency code. Default: EUR." },
            company_id: { type: "string", description: "Company ID." },
            contact_id: { type: "string", description: "Contact ID." },
          }},
        },
        {
          name: "crmUpdateDeal",
          title: "CRM: Update Deal",
          description: "Update a deal. Use generic names: company_id, contact_id, expected_close.",
          inputSchema: { type: "object", required: ["id"], properties: {
            id: { type: "string", description: "Deal ID." },
            stage_id: { type: "string", description: "Optional new stage ID (from crmGetPipelines)." },
            value: { type: "number", description: "Optional new deal value." },
            title: { type: "string", description: "Optional new deal title." },
            expected_close: { type: "string", description: "Expected close date YYYY-MM-DD." },
          }},
        },
        {
          name: "crmGetDeal",
          title: "CRM: Get Deal",
          description: "Get full deal details by ID.",
          inputSchema: { type: "object", required: ["id"], properties: {
            id: { type: "string", description: "Deal ID." },
          }},
        },
        {
          name: "crmAddNote",
          title: "CRM: Add Note",
          description: "Add a note to a deal, company, or contact.",
          inputSchema: { type: "object", required: ["content"], properties: {
            content: { type: "string", description: "Note text — supports HTML." },
            deal_id: { type: "string", description: "Optional deal ID to attach the note to." },
            company_id: { type: "string", description: "Optional company ID to attach the note to." },
            contact_id: { type: "string", description: "Optional contact ID to attach the note to." },
          }},
        },
        {
          name: "crmCreateActivity",
          title: "CRM: Create Activity",
          description: "Create a follow-up task/call/meeting.",
          inputSchema: { type: "object", required: ["subject"], properties: {
            subject: { type: "string", description: "Activity subject." },
            type: { type: "string", enum: ["call", "meeting", "task", "email", "deadline"], description: "Activity type. Default: task." },
            deal_id: { type: "string", description: "Optional deal ID to link the activity to." },
            company_id: { type: "string", description: "Optional company ID to link the activity to." },
            contact_id: { type: "string", description: "Optional contact ID to link the activity to." },
            due_date: { type: "string", description: "Due date YYYY-MM-DD." },
            note: { type: "string", description: "Optional note/body for the activity." },
          }},
        },
        {
          name: "crmCheckConnection",
          title: "CRM: Check Connection",
          description: "Check if CRM is connected and which provider is active.",
          inputSchema: { type: "object", properties: {} },
          outputSchema: {
            type: "object",
            properties: {
              connected: { type: "boolean", description: "Whether a CRM provider is connected." },
              provider: { type: ["string", "null"], description: "Active CRM provider, if connected." },
            },
            required: ["connected"],
          },
        },
        // === Enrichment Tools (via n8n-proxy) ===
        {
          name: "enrichCompany",
          title: "Enrich Company",
          description: "Get company info by domain or name. Returns industry, employees, revenue, location, technologies.",
          inputSchema: { type: "object", properties: {
            domain: { type: "string", description: "Company domain e.g. seeburger.de" },
            company_name: { type: "string", description: "Company name (if domain unknown)." },
          }},
        },
        {
          name: "enrichPerson",
          title: "Enrich Person",
          description: "Get person profile from email or LinkedIn URL.",
          inputSchema: { type: "object", properties: {
            email: { type: "string", description: "Person's email address." },
            linkedin_url: { type: "string", description: "Full LinkedIn profile URL." },
            linkedin_handle: { type: "string", description: "LinkedIn handle/slug (without the full URL)." },
          }},
        },
        {
          name: "findContacts",
          title: "Find Contacts",
          description: "Find contacts at a company. Filter by seniority or department.",
          inputSchema: { type: "object", properties: {
            domain: { type: "string", description: "Company domain to find contacts at." },
            company: { type: "string", description: "Company name (if domain unknown)." },
            seniority: { type: "string", description: "junior, senior, or executive." },
            department: { type: "string", description: "sales, marketing, it, etc." },
            limit: { type: "integer", description: "Max results. Default: 10." },
          }},
        },
        {
          name: "findEmail",
          title: "Find Email",
          description: "Find one person's email by name + domain.",
          inputSchema: { type: "object", properties: {
            domain: { type: "string", description: "Company domain to search the email at." },
            company: { type: "string", description: "Company name (if domain unknown)." },
            first_name: { type: "string", description: "Person's first name." },
            last_name: { type: "string", description: "Person's last name." },
            full_name: { type: "string", description: "Full name (alternative to first_name + last_name)." },
          }},
        },
        {
          name: "verifyEmail",
          title: "Verify Email",
          description: "Check if an email is deliverable. Use before outreach.",
          inputSchema: { type: "object", required: ["email"], properties: {
            email: { type: "string", description: "Email address to verify for deliverability." },
          }},
        },
        // Lead Scoring Tools (Phase 1b)
        {
          name: "scoreLeads",
          title: "Lead Scoring: Run",
          description: "Trigger lead scoring against ICP for this user's CRM companies. Scores each (company, contact) pair on 4 dimensions (industry 35%, employees 25%, geo 20%, seniority 20%) with missing-data renormalization. Use mode='full' for all companies, 'delta' for new/changed since last run, 'company_ids' for specific IDs. Persists to lead_scores table; read results via getTopLeads. Returns counts and per-user summary. Requires Pro plan (active or trialing). Write-operation — scores are persisted to lead_scores table.",
          inputSchema: {
            type: "object",
            required: ["mode"],
            properties: {
              mode: {
                type: "string",
                enum: ["full", "delta", "company_ids"],
                description: "Scoring scope. 'full' scores all companies (slow for >1k). 'delta' scores only companies updated since last run or not yet scored (recommended for routine updates). 'company_ids' scores a specific list (requires company_ids).",
              },
              company_ids: {
                type: "array",
                items: { type: "string" },
                description: "CRM company IDs to score. Required and only used when mode='company_ids'. Max 100 recommended per call.",
              },
            },
          },
        },
        {
          name: "getTopLeads",
          title: "Lead Scoring: Top Leads",
          description: "Retrieve the highest-scoring leads from the CRM, ranked by ICP fit. Returns company details, contact (if any), 4-dimension score breakdown, and qualitative reasons like 'Industry X — strong match to ICP'. By default filters out leads with <50% data completeness to avoid false-positives from data-sparse ICP matches (e.g. leads where only the contact's seniority matched but industry/employees/country are unknown). Override via filters.min_completeness if you want incomplete leads too. Requires scoreLeads to have been run at least once. Requires Pro plan. Read-only — does not trigger new scoring. Call scoreLeads first if your CRM has new companies or ICP has changed (check icp_version_hash in the response to detect staleness).",
          inputSchema: {
            type: "object",
            properties: {
              limit: {
                type: "integer",
                description: "Number of leads to return. Default 10, max 100.",
                minimum: 1,
                maximum: 100,
              },
              min_score: {
                type: "integer",
                description: "Minimum score 0-100 to include. Default 60.",
                minimum: 0,
                maximum: 100,
              },
              filters: {
                type: "object",
                description: "Optional result filters.",
                properties: {
                  enrichment_recommended: {
                    type: "boolean",
                    description: "If true, return only leads flagged for enrichment. If false, only leads with sufficient data. Omit for both.",
                  },
                  min_completeness: {
                    type: "number",
                    description: "Minimum data completeness 0-1. Default 0.5 (filters ghost leads). Set to 0 to include data-sparse matches.",
                    minimum: 0,
                    maximum: 1,
                  },
                },
              },
            },
          },
        },
        {
          name: "email_compose",
          title: "Compose or Draft an Email",
          description: "Compose an email via the user's connected email provider (currently Gmail; Microsoft 365 coming in Phase B). DEFAULT mode is 'draft' — creates a real draft in Gmail that the user can review before sending. Only use mode='send' when the user explicitly confirms sending with keywords like 'sende', 'schick raus', 'verschicken', 'send it', 'raus damit'. On 'draft' success, response includes draft_url the user can click to open the draft in Gmail. On 'send' success, response includes a tracking_id (1×1 pixel auto-injected for open-tracking). The From address is resolved server-side (5-level precedence: explicit from > user-token integration > user-token default > account default > account email) — do NOT fabricate a From address. Optional crm_deal_id links the message to a deal for future activity writeback. Requires active email provider OAuth connection.",
          inputSchema: {
            type: "object",
            required: ["mode", "to", "subject"],
            properties: {
              mode: {
                type: "string",
                enum: ["draft", "send"],
                description: "Default: 'draft'. Use 'send' only on explicit user confirmation.",
              },
              provider: {
                type: "string",
                enum: ["auto", "google", "microsoft"],
                description: "Default: 'auto'. Backend resolves from user's active integration.",
              },
              to: {
                type: "string",
                description: "Recipient email address.",
              },
              subject: {
                type: "string",
                description: "Email subject line.",
              },
              body_html: {
                type: "string",
                description: "HTML email body with <p>, <br>, <strong>, <a href> tags as needed. For send mode, an open-tracking pixel is auto-injected.",
              },
              body_text: {
                type: "string",
                description: "Optional plain-text fallback. If only one of body_html/body_text is provided, the other is auto-generated.",
              },
              from: {
                type: "string",
                description: "Optional From address override. Must be an address the user has authorized.",
              },
              thread_id: {
                type: "string",
                description: "Optional Gmail thread ID for replies in-thread.",
              },
              in_reply_to: {
                type: "string",
                description: "Optional Message-ID of the message being replied to.",
              },
              crm_deal_id: {
                type: "string",
                description: "Optional CRM deal UUID if this email relates to a specific deal.",
              },
            },
          },
        },
        {
          name: "createCampaign",
          title: "Campaign: Create Briefing",
          description: "Create a new campaign briefing. Use after collecting the 7 required fields via the campaign-briefing-playbook (search 'campaign-briefing-playbook' in playbook chapter to load the methodology). Sets status='draft'. Returns the created campaign id. NEVER call this without first running the playbook conversation — every campaign needs a complete briefing.",
          inputSchema: {
            type: "object",
            required: ["name", "icp_snapshot", "persona_snapshot", "offer", "pain_hypothesis", "messaging_angle", "channels", "start_date", "success_metric"],
            properties: {
              name: { type: "string", description: "Short campaign label, 3-200 chars. Include strategic axis (e.g. 'Q2-DACH-Maschinenbau-EU-AI-Act')." },
              description: { type: "string", description: "Optional free-text summary of the campaign." },
              product_snapshot: { type: "object", description: "Frozen product info at creation time. Schema: { name, description, value_props[], differentiators[], pricing_hint }." },
              icp_snapshot: { type: "object", description: "Frozen ICP at creation time. May be a NARROWED variant of the user's global ICP." },
              persona_snapshot: { type: "object", description: "Frozen target persona for this campaign." },
              offer: { type: "string", description: "The concrete CTA, NOT the product name. E.g. 'Free 30-day pilot', not 'Buy GrowthKit'." },
              pain_hypothesis: { type: "string", description: "ONE sentence stating the specific pain this campaign assumes the persona has." },
              messaging_angle: { type: "string", description: "The hook in the first email/message. The news/trend/insight that earns the read." },
              channels: { type: "array", description: "Outreach channels for this campaign: email | linkedin | event | paid | cold_call | referral | webinar.", items: { type: "string", enum: ["email", "linkedin", "event", "paid", "cold_call", "referral", "webinar"] } },
              start_date: { type: "string", description: "ISO date YYYY-MM-DD." },
              end_date: { type: "string", description: "Optional ISO date YYYY-MM-DD. Null = open-ended." },
              success_metric: { type: "object", description: "{ type: 'replies'|'demos'|'sqls'|'pipeline_eur', target: number }" },
              briefing_source: { type: "string", enum: ["wizard", "upload", "manual"], description: "Default 'wizard'." },
              source_document_id: { type: "string", description: "Optional documents.id if briefing was parsed from upload." },
              notes: { type: "string", description: "Optional internal notes about the campaign." },
            },
          },
        },
        {
          name: "listCampaigns",
          title: "Campaign: List",
          description: "List campaigns for the current user, optionally filtered by status. Returns campaign metadata plus per-stage lead counts.",
          inputSchema: {
            type: "object",
            properties: {
              status: { type: "string", enum: ["draft", "active", "paused", "completed", "archived"], description: "Optional: filter by status: draft | active | paused | completed | archived." },
              limit: { type: "integer", description: "Default 25, max 100." },
            },
          },
        },
        {
          name: "getCampaign",
          title: "Campaign: Get",
          description: "Get a single campaign with full briefing details and lead-stage counts.",
          inputSchema: {
            type: "object",
            required: ["campaign_id"],
            properties: { campaign_id: { type: "string", description: "ID of the campaign (from listCampaigns)." } },
          },
        },
        {
          name: "updateCampaign",
          title: "Campaign: Update",
          description: "Update fields on an existing campaign. Pass only the fields to change.",
          inputSchema: {
            type: "object",
            required: ["campaign_id"],
            properties: {
              campaign_id: { type: "string", description: "ID of the campaign to update (from listCampaigns)." },
              name: { type: "string", description: "Short campaign label, 3-200 chars." },
              offer: { type: "string", description: "The concrete CTA, NOT the product name. E.g. 'Free 30-day pilot'." },
              pain_hypothesis: { type: "string", description: "ONE sentence stating the specific pain this campaign assumes the persona has." },
              messaging_angle: { type: "string", description: "The hook in the first email/message — the news/trend/insight that earns the read." },
              channels: { type: "array", description: "Outreach channels for this campaign.", items: { type: "string" } },
              start_date: { type: "string", description: "ISO date YYYY-MM-DD." },
              end_date: { type: "string", description: "Optional ISO date YYYY-MM-DD. Null = open-ended." },
              success_metric: { type: "object", description: "{ type: 'replies'|'demos'|'sqls'|'pipeline_eur', target: number }" },
              status: { type: "string", enum: ["draft", "active", "paused", "completed", "archived"], description: "Campaign status: draft | active | paused | completed | archived." },
              icp_snapshot: { type: "object", description: "Frozen ICP for this campaign. May be a narrowed variant of the global ICP." },
              persona_snapshot: { type: "object", description: "Frozen target persona for this campaign." },
              product_snapshot: { type: "object", description: "Frozen product info. Schema: { name, description, value_props[], differentiators[], pricing_hint }." },
              notes: { type: "string", description: "Optional internal notes about the campaign." },
            },
          },
        },
        {
          name: "addCampaignLeads",
          title: "Campaign: Add Leads",
          description: "Add one or more leads to a campaign. Standard fields (company_name, contact_email, etc.) go to typed columns. ANY OTHER FIELD you pass automatically gets stored in the metadata jsonb column — no schema migration needed for new fields. Examples of custom fields: booth_number, source_event, scanned_at, follow_up_priority, notes_from_call. Call getCampaignLeadFields first to discover what custom fields are already used in this campaign.",
          inputSchema: {
            type: "object",
            required: ["campaign_id", "leads"],
            properties: {
              campaign_id: { type: "string", description: "ID of the campaign (from listCampaigns)." },
              source: { type: "string", enum: ["manual", "apollo", "hunter", "enrichment", "mcp", "csv_upload"], description: "Default 'mcp'." },
              leads: {
                type: "array",
                description: "Array of lead objects. Standard fields go to columns; unknown keys go to metadata jsonb. Max 100 per call.",
                items: {
                  type: "object",
                  properties: {
                    company_name: { type: "string" },
                    company_domain: { type: "string" },
                    company_industry: { type: "string" },
                    company_country: { type: "string" },
                    company_employees: { type: "integer" },
                    contact_name: { type: "string" },
                    contact_email: { type: "string" },
                    contact_role: { type: "string" },
                    contact_seniority: { type: "string" },
                    contact_linkedin: { type: "string" },
                  },
                  additionalProperties: true,
                },
              },
            },
          },
        },
        {
          name: "getCampaignLeadFields",
          title: "Campaign: Discover Lead Fields",
          description: "Discover which fields are actually used in a campaign's leads. Returns standard columns with non-null values PLUS all metadata (custom) keys with usage counts and sample values. ALWAYS call this BEFORE asking the user about lead structure or before adding new custom fields — it tells you what's already established for this list.",
          inputSchema: {
            type: "object",
            required: ["campaign_id"],
            properties: { campaign_id: { type: "string", description: "ID of the campaign (from listCampaigns)." } },
          },
        },
        {
          name: "updateCampaignLead",
          title: "Campaign: Update Lead",
          description: "Update fields on an existing campaign lead. Pass lead_id (UUID from listCampaignLeads) and an updates object with only the fields to change. Use this to mark leads as rejected, manually correct enrichment data, or attach custom metadata. Setting lifecycle_stage='rejected' REQUIRES rejected_reason in the same call. The metadata field is shallow-merged into existing metadata jsonb — existing keys are preserved unless overwritten by the same key. Score/dim_*/icp_version_hash are NOT writable here (those come from scoreLeads). crm_external_id/crm_synced_at are NOT writable either (CRM-Sync owns those).",
          inputSchema: {
            type: "object",
            required: ["lead_id", "updates"],
            properties: {
              lead_id: { type: "string", description: "UUID of the campaign_lead to update" },
              updates: {
                type: "object",
                description: "Object with fields to change. metadata is shallow-merged.",
                properties: {
                  lifecycle_stage: { type: "string", enum: ["imported", "enriched", "scored", "crm_ready", "crm_synced", "rejected", "bounced"] },
                  rejected_reason: { type: "string", description: "REQUIRED when lifecycle_stage='rejected'" },
                  enrichment_status: { type: "string", enum: ["pending", "enriched", "failed", "skipped"] },
                  contact_name: { type: "string" },
                  contact_email: { type: "string" },
                  contact_role: { type: "string" },
                  contact_seniority: { type: "string" },
                  contact_linkedin: { type: "string" },
                  contact_phone: { type: "string" },
                  company_name: { type: "string" },
                  company_domain: { type: "string" },
                  company_industry: { type: "string" },
                  company_country: { type: "string" },
                  company_employees: { type: "integer" },
                  company_linkedin: { type: "string" },
                  metadata: { type: "object", description: "Shallow-merged into existing metadata. Pass {} to clear all keys." },
                },
              },
            },
          },
        },
        {
          name: "listCampaignLeads",
          title: "Campaign: List Leads",
          description: "List leads in a campaign, optionally filtered by lifecycle_stage or enrichment_status. Returns up to 100 per call.",
          inputSchema: {
            type: "object",
            required: ["campaign_id"],
            properties: {
              campaign_id: { type: "string", description: "ID of the campaign (from listCampaigns)." },
              lifecycle_stage: { type: "string", enum: ["imported", "enriched", "scored", "crm_ready", "crm_synced", "rejected", "bounced"], description: "Optional: filter by lifecycle stage." },
              enrichment_status: { type: "string", enum: ["pending", "enriched", "failed", "skipped"], description: "Optional: filter by enrichment status." },
              limit: { type: "integer", description: "Default 50, max 100." },
            },
          },
        },
        {
          name: "setWorkingMemory",
          title: "Working Memory: Set",
          description: "Store structured state for the current chat session. Use this to persist data that must survive history compression — wizard fields, suggestion lists, active entities. Three kinds: 'wizard' (multi-turn field collection), 'working_set' (ephemeral suggestion lists with TTL), 'pinned_entity' (durable context). Call this AFTER the user confirms a value, BEFORE moving to the next step. The state object replaces (not merges) — fetch first if you need to merge.",
          inputSchema: {
            type: "object",
            required: ["session_id", "kind", "key", "state"],
            properties: {
              session_id: {
                type: "string",
                description: "The current chat session_id. REQUIRED. Comes from the conversation context.",
              },
              kind: {
                type: "string",
                enum: ["wizard", "working_set", "pinned_entity"],
                description: "wizard = multi-turn field collection. working_set = ephemeral suggestion lists with TTL. pinned_entity = durable context across turns.",
              },
              key: {
                type: "string",
                description: "Logical identifier within a kind. Examples: 'campaign_briefing', 'lead_candidates', 'active_campaign'. Use snake_case.",
              },
              state: {
                type: "object",
                description: "The full state object to store. Replaces any previous state for this (kind, key). Schema is free-form but conventions: wizard = { fields, required, collected, current_step }; working_set = { items, context }; pinned_entity = { id, name, summary, ... }.",
              },
              ttl_turns: {
                type: "integer",
                description: "Optional TTL in user-turns. After this many turns, the record auto-expires. NULL/omit = permanent (typical for wizard and pinned_entity). Use 5 for working_set / suggestion lists.",
              },
              status: {
                type: "string",
                enum: ["active", "completed", "abandoned"],
                description: "Default 'active'. Set to 'completed' when a wizard finishes successfully (triggers completed_at timestamp).",
              },
            },
          },
        },
        {
          name: "getWorkingMemory",
          title: "Working Memory: Get",
          description: "Retrieve the current state for a (kind, key) in the current session. Returns null if not set. Use this when you need to merge into existing state or verify what's stored. NOTE: Active working memory entries are ALSO automatically injected into the system prompt by Build Messages — you usually don't need to call this manually. Only call when you need a specific record's full state on-demand.",
          inputSchema: {
            type: "object",
            required: ["session_id", "kind", "key"],
            properties: {
              session_id: {
                type: "string",
                description: "The current chat session_id. REQUIRED.",
              },
              kind: {
                type: "string",
                enum: ["wizard", "working_set", "pinned_entity"],
                description: "Which kind of state to retrieve: wizard | working_set | pinned_entity.",
              },
              key: {
                type: "string",
                description: "Logical identifier within the kind (same key used in setWorkingMemory).",
              },
            },
          },
        },
          {
            name: "createTask",
            title: "Create Task",
            description: "Create a prioritized task. Provide the four ICE inputs (impact, confidence, effort_constraint, effort_nonconstraint); the DB computes ice_score. Show the inputs to the user for confirmation before calling.",
            inputSchema: {
              type: "object",
              required: ["title"],
              properties: {
                title:  { type: "string", description: "Short task title." },
                detail: { type: "string", description: "Optional longer description of the task." },
                owner:  { type: "string", description: "Assignee (free text)" },
                bucket: { type: "string", enum: ["now", "next", "later"], description: "Time horizon: now | next | later." },
                impact:               { type: "integer", minimum: 1, maximum: 10, description: "ICE impact, 1-10 (higher = more impact)." },
                confidence:           { type: "number",  minimum: 0, maximum: 1, description: "ICE confidence, 0-1 (probability the impact materializes)." },
                effort_constraint:    { type: "integer", minimum: 1, maximum: 10, description: "Effort on the bottleneck lane (see workspace label_constraint)" },
                effort_nonconstraint: { type: "integer", minimum: 1, maximum: 10, description: "Effort on the non-bottleneck lane" },
                related_memory_id:    { type: "string", description: "Optional ID of a related memory to link." },
                steps: {
                  type: "array",
                  description: "Optional checklist of sub-steps.",
                  items: {
                    type: "object",
                    required: ["text"],
                    properties: {
                      text: { type: "string" },
                      done: { type: "boolean" },
                    },
                  },
                },
              },
            },
          },
          {
            name: "listTasks",
            title: "List Tasks",
            description: "List tasks in the workspace, ranked by ICE (highest first). Optional filters.",
            inputSchema: {
              type: "object",
              properties: {
                status: { type: "string", enum: ["open", "in_progress", "done", "dropped"], description: "Optional: filter by status: open | in_progress | done | dropped." },
                bucket: { type: "string", enum: ["now", "next", "later"], description: "Optional: filter by bucket: now | next | later." },
                owner:  { type: "string", description: "Optional: filter by assignee." },
                limit:  { type: "integer", description: "Max results. Default: 50." },
              },
            },
            outputSchema: TASK_LIST_OUTPUT_SCHEMA,
          },
          {
            name: "getOpenTasks",
            title: "Get Open Tasks",
            description: "Return the workspace's open/in-progress tasks ranked by ICE (highest priority first) plus the total open count. Call this at the START of any planning, prioritization, or 'what should I work on next' discussion to ground the conversation in current open tasks before advising.",
            inputSchema: {
              type: "object",
              properties: {
                limit: { type: "integer", description: "Max tasks to return. Default: 20." },
              },
            },
            outputSchema: TASK_LIST_OUTPUT_SCHEMA,
          },
          {
            name: "updateTask",
            title: "Update Task",
            description: "Update fields of a task. Partial update; status='done' sets done_at automatically. ice_score recomputes when impact/confidence/effort change.",
            inputSchema: {
              type: "object",
              required: ["id"],
              properties: {
                id:     { type: "string", description: "ID of the task to update (from listTasks)." },
                title:  { type: "string", description: "Optional new task title." },
                status: { type: "string", enum: ["open", "in_progress", "done", "dropped"], description: "New status: open | in_progress | done | dropped." },
                bucket: { type: "string", enum: ["now", "next", "later"], description: "Time horizon: now | next | later." },
                impact:               { type: "integer", minimum: 1, maximum: 10, description: "ICE impact, 1-10 (higher = more impact)." },
                confidence:           { type: "number",  minimum: 0, maximum: 1, description: "ICE confidence, 0-1 (probability the impact materializes)." },
                effort_constraint:    { type: "integer", minimum: 1, maximum: 10, description: "Effort on the bottleneck lane (see workspace label_constraint)." },
                effort_nonconstraint: { type: "integer", minimum: 1, maximum: 10, description: "Effort on the non-bottleneck lane." },
                owner:  { type: "string", description: "Assignee (free text)." },
                detail: { type: "string", description: "Optional longer description of the task." },
                steps: {
                  type: "array",
                  description: "Replace the task's checklist. Omit to leave unchanged.",
                  items: {
                    type: "object",
                    required: ["text"],
                    properties: {
                      id:   { type: "string" },
                      text: { type: "string" },
                      done: { type: "boolean" },
                    },
                  },
                },
              },
            },
          },
          {
            name: "setTaskWeights",
            title: "Set Task Weights",
            description: "Set the workspace effort weights (constraint vs non-constraint lane) and optional display labels. Re-stamps open tasks so their ICE re-ranks.",
            inputSchema: {
              type: "object",
              required: ["w_constraint", "w_nonconstraint"],
              properties: {
                w_constraint:        { type: "number", minimum: 0, description: "Weight for the constraint (bottleneck) effort lane in the ICE score." },
                w_nonconstraint:     { type: "number", minimum: 0, description: "Weight for the non-constraint effort lane in the ICE score." },
                label_constraint:    { type: "string", description: "Optional display label for the constraint lane (e.g. 'Engineering')." },
                label_nonconstraint: { type: "string", description: "Optional display label for the non-constraint lane (e.g. 'Design')." },
              },
            },
          },
          {
            name: "toggleStep",
            title: "Toggle Step",
            description: "Hakt einen Step eines Tasks ab/an. done weglassen = flippen.",
            inputSchema: {
              type: "object",
              required: ["id", "step_id"],
              properties: {
                id:      { type: "string", description: "Task UUID." },
                step_id: { type: "string", description: "ID of the step to toggle (from the task's steps)." },
                done:    { type: "boolean", description: "Omit to flip the current state." },
              },
            },
          },
        ];

        // Role-based tool filtering
        const toolRoleMap = {
          embedMemory: ["admin", "team"],
          searchMemory: ["admin", "team", "view"],
          listMemories: ["admin", "team", "view"],
          updateMemory: ["admin", "team"],
          deleteMemories: ["admin"],
          clearMemories: ["admin"],
          countMemories: ["admin", "team", "view"],
          getChapterOverview: ["admin", "team", "view"],
          uploadDocument: ["admin", "team"],
          listDocuments: ["admin", "team", "view"],
          getDocument: ["admin", "team", "view"],
          deleteDocument: ["admin"],
          createReminder: ["admin", "team"],
          listReminders: ["admin", "team", "view"],
          cancelReminder: ["admin", "team"],
          getHistory: ["admin", "team", "view"],
          restoreVersion: ["admin"],
          listDeleted: ["admin"],
          listTeam: ["admin", "team"],
          sendNotification: ["admin", "team"],
          checkNotifications: ["admin", "team", "view"],
          // CRM Tools
          crmSearchCompany: ["admin", "team"],
          crmGetCompany: ["admin", "team", "view"],
          crmCreateCompany: ["admin", "team"],
          crmGetCompanyDeals: ["admin", "team", "view"],
          crmGetCompanyContacts: ["admin", "team", "view"],
          crmSearchContact: ["admin", "team"],
          crmListCompanies: ["admin", "team", "view"],
          crmListPeople:    ["admin", "team", "view"],
          crmGetContact: ["admin", "team", "view"],
          crmCreateContact: ["admin", "team"],
          crmGetPipelines: ["admin", "team", "view"],
          crmCreateDeal: ["admin", "team"],
          crmUpdateDeal: ["admin", "team"],
          crmGetDeal: ["admin", "team", "view"],
          crmAddNote: ["admin", "team"],
          crmCreateActivity: ["admin", "team"],
          crmCheckConnection: ["admin", "team", "view"],
          // Enrichment Tools
          enrichCompany: ["admin", "team"],
          enrichPerson: ["admin", "team"],
          findContacts: ["admin", "team"],
          findEmail: ["admin", "team"],
          verifyEmail: ["admin", "team"],
          // Lead Scoring Tools (Phase 1b)
          scoreLeads:  ["admin", "team"],
          getTopLeads: ["admin", "team", "view"],
          email_compose: ["admin", "team"],
          // Campaign Tools
          createCampaign:        ["admin", "team"],
          listCampaigns:         ["admin", "team", "view"],
          getCampaign:           ["admin", "team", "view"],
          updateCampaign:        ["admin", "team"],
          addCampaignLeads:      ["admin", "team"],
          getCampaignLeadFields: ["admin", "team", "view"],
          updateCampaignLead:    ["admin", "team"],
          listCampaignLeads:     ["admin", "team", "view"],
          // Working Memory Tools — session-local, all roles read+write
          setWorkingMemory:      ["admin", "team", "view"],
          getWorkingMemory:      ["admin", "team", "view"],
          // Task Tools — reads for all roles, writes without view
          listTasks:      ["admin", "team", "view"],
          getOpenTasks:   ["admin", "team", "view"],
          createTask:     ["admin", "team"],
          updateTask:     ["admin", "team"],
          setTaskWeights: ["admin", "team"],
          toggleStep:     ["admin", "team"],
        };

        // Tool annotations (MCP readOnlyHint/destructiveHint) for registry/client
        // labeling and Claude Connectors directory submission.
        const READ_ONLY_TOOLS = new Set([
          "searchMemory", "listMemories", "countMemories", "getChapterOverview",
          "listDocuments", "getDocument", "listReminders", "getHistory", "listDeleted",
          "listTeam", "checkNotifications",
          "crmSearchCompany", "crmGetCompany", "crmGetCompanyDeals", "crmGetCompanyContacts",
          "crmSearchContact", "crmListCompanies", "crmListPeople", "crmGetContact",
          "crmGetPipelines", "crmGetDeal", "crmCheckConnection",
          "enrichCompany", "enrichPerson", "findContacts", "findEmail", "verifyEmail",
          "getTopLeads", "listCampaigns", "getCampaign", "getCampaignLeadFields", "listCampaignLeads",
          "getWorkingMemory", "listTasks", "getOpenTasks",
        ]);
        const DESTRUCTIVE_TOOLS = new Set(["deleteMemories", "clearMemories", "deleteDocument"]);
        const annotate = (t) => ({
          ...t,
          annotations: READ_ONLY_TOOLS.has(t.name)
            ? { readOnlyHint: true }
            : { readOnlyHint: false, destructiveHint: DESTRUCTIVE_TOOLS.has(t.name) },
        });

        // Unauthenticated discovery (no token) returns the FULL catalog so
        // registries can show the complete capability set; execution stays gated.
        // Authenticated calls keep the existing role-based filtering untouched.
        const baseTools = !userToken
          ? allTools
          : userRole === "demo"
            ? allTools.filter(t => DEMO_TOOLS.has(t.name))
            : allTools.filter(t => (toolRoleMap[t.name] || []).includes(userRole));
        const filteredTools = baseTools.map(annotate);
        return json({ jsonrpc: "2.0", id, result: { tools: filteredTools } });
      }

      // -------------------------------------------------------
      // tools/call — DIRECT EDGE FUNCTION CALLS
      // -------------------------------------------------------
      if (method === "tools/call") {
        const { name, arguments: args = {} } = params;

        // Permission guard
        const toolPermissions = {
          embedMemory: ["admin", "team"], searchMemory: ["admin", "team", "view"],
          listMemories: ["admin", "team", "view"], updateMemory: ["admin", "team"],
          deleteMemories: ["admin"], clearMemories: ["admin"],
          countMemories: ["admin", "team", "view"], getChapterOverview: ["admin", "team", "view"],
          uploadDocument: ["admin", "team"], listDocuments: ["admin", "team", "view"],
          getDocument: ["admin", "team", "view"], deleteDocument: ["admin"],
          createReminder: ["admin", "team"], listReminders: ["admin", "team", "view"],
          cancelReminder: ["admin", "team"],
          getHistory: ["admin", "team", "view"],
          restoreVersion: ["admin"],
          listDeleted: ["admin"],
          listTeam: ["admin", "team"],
          sendNotification: ["admin", "team"],
          checkNotifications: ["admin", "team", "view"],
          crmSearchCompany: ["admin", "team"],
          crmGetCompany: ["admin", "team", "view"],
          crmCreateCompany: ["admin", "team"],
          crmGetCompanyDeals: ["admin", "team", "view"],
          crmGetCompanyContacts: ["admin", "team", "view"],
          crmSearchContact: ["admin", "team"],
          crmListCompanies: ["admin", "team", "view"],
          crmListPeople:    ["admin", "team", "view"],
          crmGetContact: ["admin", "team", "view"],
          crmCreateContact: ["admin", "team"],
          crmGetPipelines: ["admin", "team", "view"],
          crmCreateDeal: ["admin", "team"],
          crmUpdateDeal: ["admin", "team"],
          crmGetDeal: ["admin", "team", "view"],
          crmAddNote: ["admin", "team"],
          crmCreateActivity: ["admin", "team"],
          crmCheckConnection: ["admin", "team", "view"],
          enrichCompany: ["admin", "team"],
          enrichPerson: ["admin", "team"],
          findContacts: ["admin", "team"],
          findEmail: ["admin", "team"],
          verifyEmail: ["admin", "team"],
          // Lead Scoring Tools (Phase 1b) — mirrors toolRoleMap; keep in sync.
          scoreLeads:  ["admin", "team"],
          getTopLeads: ["admin", "team", "view"],
          email_compose: ["admin", "team"],
          // Campaign Tools
          createCampaign:        ["admin", "team"],
          listCampaigns:         ["admin", "team", "view"],
          getCampaign:           ["admin", "team", "view"],
          updateCampaign:        ["admin", "team"],
          addCampaignLeads:      ["admin", "team"],
          getCampaignLeadFields: ["admin", "team", "view"],
          updateCampaignLead:    ["admin", "team"],
          listCampaignLeads:     ["admin", "team", "view"],
          // Working Memory Tools — session-local, all roles read+write
          setWorkingMemory:      ["admin", "team", "view"],
          getWorkingMemory:      ["admin", "team", "view"],
          // Task Tools — reads for all roles, writes without view
          listTasks:      ["admin", "team", "view"],
          getOpenTasks:   ["admin", "team", "view"],
          createTask:     ["admin", "team"],
          updateTask:     ["admin", "team"],
          setTaskWeights: ["admin", "team"],
          toggleStep:     ["admin", "team"],
        };

        if (userRole === "demo") {
          if (!DEMO_TOOLS.has(name)) {
            return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "This tool isn't available in the GrowthKit demo. Sign up free at https://app.growthkit.tools to use it with your own data." }], isError: true } });
          }
          // demo + tool in allowlist → erlaubt; role-basierte toolPermissions-Prüfung überspringen.
        } else if (toolPermissions[name] && !toolPermissions[name].includes(userRole)) {
          return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "Permission denied: role " + userRole + " cannot use " + name }], isError: true } });
        }

        // Demo-Rate-Limit (nur Demo-Sessions, IP-basiert, fail-open)
        if (userRole === "demo") {
          const rl = await checkDemoRateLimit(env, request);
          if (!rl.allowed) {
            return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "The GrowthKit demo is rate-limited to keep it available for everyone. Please wait a minute and try again — or see https://growthkit.tools/en/pricing to get your own unthrottled workspace." }], isError: true } });
          }
        }

        // Chapter write guard
        if (name === "embedMemory" || name === "updateMemory") {
          const targetChapter = (args.metadata && args.metadata.chapter) || (args.new_metadata && args.new_metadata.chapter) || "general";
          if (!chapterPerms[userRole].write.includes(targetChapter)) {
            return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "Permission denied: cannot write to " + targetChapter + " chapter." }], isError: true } });
          }
          if (name === "embedMemory" && args.items && Array.isArray(args.items)) {
            const blocked = args.items.map(i => (i.metadata && i.metadata.chapter) || "general").filter(ch => !chapterPerms[userRole].write.includes(ch));
            if (blocked.length > 0) {
              return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "Permission denied: cannot write to chapters: " + [...new Set(blocked)].join(", ") }], isError: true } });
            }
          }
        }

        // Chapter read guard
        if (name === "searchMemory" || name === "listMemories" || name === "countMemories") {
          const ch = args.metadata_filter && args.metadata_filter.chapter;
          if (ch && !chapterPerms[userRole].read.includes(ch)) {
            return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "Permission denied: cannot read " + ch + " chapter." }], isError: true } });
          }
        }

        // Demo-CTA: rotate a soft pricing line into the next successful tool
        // result (appended in json(); never on isError, never a hard block).
        if (isDemo) {
          pendingDemoCta = await maybeDemoCta(env, token, name, demoClient, demoLang);
        }

        // === getChapterOverview — multiple count calls ===
if (name === "getChapterOverview") {
  try {
    const { data, ok } = await callEdge(EDGE_EMBED_URL, { action: "overview", user_token: userToken });
    if (ok && data.success) {
      const readableChapters = chapterPerms[userRole].read;
      const entries = Object.entries(data.chapters).filter(([ch]) => readableChapters.includes(ch));
      const lines = entries.map(([ch, count]) => ch + ": " + count + " memories");
      const structuredContent = {
        chapters: entries.map(([ch, count]) => ({ chapter: ch, count: Number(count) || 0 })),
        total: Number(data.total) || 0,
      };
      return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "\ud83d\udcda Chapter Overview\n" + "\u2500".repeat(30) + "\n" + lines.join("\n") + "\n" + "\u2500".repeat(30) + "\nTotal: " + data.total + " memories" }], structuredContent } });
    }
  } catch (e) { console.error("Overview RPC failed, falling back:", e); }

  // Fallback: individual count calls
  const chapters = ["icp", "strategy", "campaigns", "analytics", "brand", "competitors", "learnings", "general", "pipeline", "signals", "playbook"].filter(ch => chapterPerms[userRole].read.includes(ch));
  const counts = {};
  for (const ch of chapters) {
    try {
      const { data } = await callEdge(EDGE_EMBED_URL, { action: "count", user_token: userToken, metadata_filter: { chapter: ch } });
      counts[ch] = data?.count ?? 0;
    } catch (e) { counts[ch] = "error"; }
  }
  let total = 0;
  try {
    const { data } = await callEdge(EDGE_EMBED_URL, { action: "count", user_token: userToken });
    total = data?.count ?? 0;
  } catch (e) { total = "error"; }
  const overview = chapters.map(ch => ch + ": " + counts[ch] + " memories").join("\n");
  const structuredContent = {
    chapters: chapters.map(ch => ({ chapter: ch, count: typeof counts[ch] === "number" ? counts[ch] : 0 })),
    total: typeof total === "number" ? total : 0,
  };
  return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "\ud83d\udcda Chapter Overview\n" + "\u2500".repeat(30) + "\n" + overview + "\n" + "\u2500".repeat(30) + "\nTotal: " + total + " memories" }], structuredContent } });
}

        // === Reminders — direct Supabase REST ===
        if (name === "createReminder") {
          const userId = await resolveUserId(userToken);
          if (!userId) {
            return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "Failed: could not resolve user for token." }], isError: true } });
          }
          const tokenHash = await sha256Hex(userToken);
          const reminder = {
            user_id: userId,
            created_by_token_hash: tokenHash,
            title: args.title,
            description: args.description || null,
            remind_at: args.remind_at,
            repeat: args.repeat || "none",
            channel: args.channel || "email",
            channel_target: args.channel_target || null,
            metadata: args.metadata || {},
            task_id: args.task_id ?? null,
          };
          const res = await fetch(`${env.SUPABASE_URL}/rest/v1/reminders`, { method: "POST", headers: sbHeaders(env, { "Content-Type": "application/json", Prefer: "return=representation" }), body: JSON.stringify(reminder) });
          const data = await res.json();
          return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: res.ok ? `Reminder created: "${args.title}" for ${args.remind_at}${args.task_id ? ` (task ${args.task_id})` : ""} (ID: ${data[0]?.id})` : `Failed: ${JSON.stringify(data)}` }], isError: !res.ok } });
        }
        if (name === "listReminders") {
          const userId = await resolveUserId(userToken);
          if (!userId) {
            return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "Failed: could not resolve user for token." }], isError: true } });
          }
          const status = args.status || "pending";
          let query = `${env.SUPABASE_URL}/rest/v1/reminders?user_id=eq.${userId}&order=remind_at.asc&limit=${args.limit || 20}`;
          if (status !== "all") query += `&status=eq.${status}`;
          if (args.task_id) query += `&task_id=eq.${args.task_id}`;
          const res = await fetch(query, { headers: sbHeaders(env) });
          const data = await res.json();
          const result = { content: [{ type: "text", text: res.ok ? JSON.stringify(data) : "Failed to list reminders" }], isError: !res.ok };
          if (res.ok) result.structuredContent = { reminders: Array.isArray(data) ? data : [] };
          return json({ jsonrpc: "2.0", id, result });
        }
        if (name === "cancelReminder") {
          const userId = await resolveUserId(userToken);
          if (!userId) {
            return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "Failed: could not resolve user for token." }], isError: true } });
          }
          const res = await fetch(`${env.SUPABASE_URL}/rest/v1/reminders?id=eq.${args.reminder_id}&user_id=eq.${userId}`, { method: "PATCH", headers: sbHeaders(env, { "Content-Type": "application/json", Prefer: "return=minimal" }), body: JSON.stringify({ status: "cancelled" }) });
          return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: res.ok ? `Reminder ${args.reminder_id} cancelled.` : "Failed to cancel." }], isError: !res.ok } });
        }

        // === Task Tools — direct PostgREST RPC (service_role); RPC hashes p_token ===
        // Normalize task RPC output (array OR { tasks } OR { items }) to an array so
        // structuredContent always matches the { tasks: [...] } output schema.
        const asTaskArray = (d) =>
          Array.isArray(d) ? d
          : Array.isArray(d?.tasks) ? d.tasks
          : Array.isArray(d?.items) ? d.items
          : [];
        if (name === "createTask") {
          const { data, ok } = await callRpc("gk_create_task", {
            p_token: userToken,
            p_title: args.title,
            p_detail: args.detail ?? null,
            p_owner: args.owner ?? null,
            p_bucket: args.bucket ?? null,
            p_impact: args.impact ?? null,
            p_confidence: args.confidence ?? null,
            p_effort_constraint: args.effort_constraint ?? null,
            p_effort_nonconstraint: args.effort_nonconstraint ?? null,
            p_related_memory_id: args.related_memory_id ?? null,
            p_steps: args.steps ?? [],
          });
          return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(data) }], isError: !ok } });
        }
        if (name === "listTasks") {
          const { data, ok } = await callRpc("gk_list_tasks", {
            p_token: userToken,
            p_status: args.status ?? null,
            p_bucket: args.bucket ?? null,
            p_owner: args.owner ?? null,
            p_limit: args.limit ?? 50,
          });
          const result = { content: [{ type: "text", text: JSON.stringify(data) }], isError: !ok };
          if (ok) result.structuredContent = { tasks: asTaskArray(data) };
          return json({ jsonrpc: "2.0", id, result });
        }
        if (name === "getOpenTasks") {
          const { data, ok } = await callRpc("gk_get_open_tasks", {
            p_token: userToken,
            p_limit: args.limit ?? 10,
          });
          const result = { content: [{ type: "text", text: JSON.stringify(data) }], isError: !ok };
          if (ok) {
            const sc = { tasks: asTaskArray(data) };
            if (data && !Array.isArray(data) && typeof data.total_open === "number") sc.total_open = data.total_open;
            result.structuredContent = sc;
          }
          return json({ jsonrpc: "2.0", id, result });
        }
        if (name === "updateTask") {
          const { data, ok } = await callRpc("gk_update_task", {
            p_token: userToken,
            p_id: args.id,
            p_status: args.status ?? null,
            p_bucket: args.bucket ?? null,
            p_impact: args.impact ?? null,
            p_confidence: args.confidence ?? null,
            p_effort_constraint: args.effort_constraint ?? null,
            p_effort_nonconstraint: args.effort_nonconstraint ?? null,
            p_owner: args.owner ?? null,
            p_detail: args.detail ?? null,
            p_title: args.title ?? null,
            p_steps: args.steps ?? null,
          });
          return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(data) }], isError: !ok } });
        }
        if (name === "setTaskWeights") {
          const { data, ok } = await callRpc("gk_set_task_weights", {
            p_token: userToken,
            p_w_constraint: args.w_constraint,
            p_w_nonconstraint: args.w_nonconstraint,
            p_label_constraint: args.label_constraint ?? null,
            p_label_nonconstraint: args.label_nonconstraint ?? null,
          });
          return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(data) }], isError: !ok } });
        }
        if (name === "toggleStep") {
          const { data, ok } = await callRpc("gk_toggle_step", {
            p_token: userToken,
            p_id: args.id,
            p_step_id: args.step_id,
            p_done: args.done ?? null,
          });
          return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(data) }], isError: !ok } });
        }

        // === DIRECT EDGE FUNCTION CALLS ===

        // === Campaign Tools — via n8n-embed (consistent with other tools) ===
        // Each tool maps to an n8n-embed action. Token resolution and ownership
        // checks happen inside the Edge Function — symmetrical to n8n-workflow.

        if (name === "addCampaignLeads") {
          // Special handling: leads array contains objects with potentially custom fields.
          // n8n-embed's add_campaign_leads action handles column/metadata splitting.
          const payload = {
            user_token: userToken,
            action: "add_campaign_leads",
            campaign_id: args.campaign_id,
            leads: args.leads,
            source: args.source || "mcp",
          };
          try {
            const { data, ok: edgeOk } = await callEdge(EDGE_EMBED_URL, payload);
            return json({
              jsonrpc: "2.0",
              id,
              result: {
                content: [{ type: "text", text: JSON.stringify(data) }],
                isError: !edgeOk,
              },
            });
          } catch (e) {
            return json({ jsonrpc: "2.0", id, error: { code: -32000, message: "addCampaignLeads error: " + e.message } });
          }
        }

        // === CRM Tools → n8n-proxy ===
        const crmActions = {
          crmSearchCompany: "search_company",
          crmGetCompany: "get_company",
          crmCreateCompany: "create_company",
          crmGetCompanyDeals: "get_company_deals",
          crmGetCompanyContacts: "get_company_contacts",
          crmSearchContact: "search_contact",
          crmListCompanies: "list_companies",
          crmListPeople:    "list_people",
          crmGetContact: "get_contact",
          crmCreateContact: "create_contact",
          crmGetPipelines: "get_pipelines",
          crmCreateDeal: "create_deal",
          crmUpdateDeal: "update_deal",
          crmGetDeal: "get_deal",
          crmAddNote: "add_note",
          crmCreateActivity: "create_activity",
          crmCheckConnection: "check_connection",
        };

        if (crmActions[name]) {
          const crmPayload = {
            user_token: userToken,
            provider: "crm",
            action: crmActions[name],
            params: { ...args },
          };
          // Rename 'term' to match n8n-proxy expectations
          if (args.term) crmPayload.params.term = args.term;
          if (args.id) crmPayload.params.id = args.id;

          try {
            const { data, ok } = await callEdge(EDGE_PROXY_URL, crmPayload);
            const result = { content: [{ type: "text", text: JSON.stringify(data) }], isError: !ok };
            if (ok && name === "crmCheckConnection") {
              const base = (data && typeof data === "object" && !Array.isArray(data)) ? data : {};
              const connected = Boolean(
                base.connected ?? base.success ??
                (typeof base.status === "string" && /connect|^ok$|active/i.test(base.status))
              );
              result.structuredContent = { ...base, connected };
            }
            return json({ jsonrpc: "2.0", id, result });
          } catch (e) {
            return json({ jsonrpc: "2.0", id, error: { code: -32000, message: "CRM error: " + e.message } });
          }
        }

        // === Enrichment Tools → n8n-proxy ===
        const enrichActions = {
          enrichCompany: "enrich_company",
          enrichPerson: "enrich_person",
          findContacts: "find_contacts",
          findEmail: "find_email",
          verifyEmail: "verify_email",
        };

        if (enrichActions[name]) {
          const enrichPayload = {
            user_token: userToken,
            provider: "enrichment",
            action: enrichActions[name],
            params: { ...args },
          };

          try {
            const { data, ok } = await callEdge(EDGE_PROXY_URL, enrichPayload);
            return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(data) }], isError: !ok } });
          } catch (e) {
            return json({ jsonrpc: "2.0", id, error: { code: -32000, message: "Enrichment error: " + e.message } });
          }
        }

        // ── Email Compose (Phase A: Gmail; Phase B: + Microsoft 365) ──
        // Uses MCP_TO_EDGE_SECRET, not N8N_AUTH_TOKEN. Payload mirrors Edge Function
        // §6.1 contract: { user_token, mode, provider, to, subject, body_html, ... }.
        if (name === "email_compose") {
          // Minimal validation — Edge Function does the authoritative check
          if (!args.mode || !args.to || !args.subject) {
            return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "Missing required field: mode, to, and subject are all required." }], isError: true } });
          }
          if (!args.body_html && !args.body_text) {
            return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "Missing body: provide at least one of body_html or body_text." }], isError: true } });
          }

          const body = {
            user_token: userToken,
            mode: args.mode,
            provider: args.provider || "auto",
            to: args.to,
            subject: args.subject,
          };
          if (args.body_html) body.body_html = args.body_html;
          if (args.body_text) body.body_text = args.body_text;
          if (args.from) body.from = args.from;
          if (args.thread_id) body.thread_id = args.thread_id;
          if (args.in_reply_to) body.in_reply_to = args.in_reply_to;
          if (args.crm_deal_id) body.crm_deal_id = args.crm_deal_id;

          try {
            const res = await fetch(EDGE_EMAIL_COMPOSE_URL, {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
                "Authorization": `Bearer ${env.MCP_TO_EDGE_SECRET}`,
              },
              body: JSON.stringify(body),
            });
            const data = await res.json();

            if (!res.ok) {
              const errCode = data?.error?.code || res.statusText;
              const errMsg = data?.error?.message || "Unknown error";

              // Special handling: scope_insufficient → user-facing reauth hint
              if (errCode === "scope_insufficient") {
                return json({
                  jsonrpc: "2.0",
                  id,
                  result: {
                    content: [{
                      type: "text",
                      text: "Draft mode requires additional Gmail permissions. Please reconnect your Gmail account: " + (data?.error?.reauth_url || "https://app.growthkit.tools/settings/integrations"),
                    }],
                    isError: true,
                  },
                });
              }

              return json({
                jsonrpc: "2.0",
                id,
                result: {
                  content: [{ type: "text", text: `Email compose failed (${errCode}): ${errMsg}` }],
                  isError: true,
                },
              });
            }

            // Success — format response based on mode
            let text;
            if (data.status === "drafted") {
              text = `Draft created.\nOpen in Gmail: ${data.draft_url}\nDraft ID: ${data.draft_id}\nProvider: ${data.provider}`;
            } else if (data.status === "sent") {
              text = `Email sent.\nMessage ID: ${data.message_id || "—"}\nTracking ID: ${data.tracking_id || "—"}\nProvider: ${data.provider}\nTo: ${args.to}`;
            } else {
              // Fallback — unexpected response shape
              text = JSON.stringify(data);
            }

            return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text }] } });
          } catch (e) {
            return json({ jsonrpc: "2.0", id, error: { code: -32000, message: "Email compose error: " + e.message } });
          }
        }

        // ── Lead Scoring (Phase 1b) — dedicated dispatch: payload shape differs
        //    from crmActions/enrichActions/toolConfig (no `provider`/`action`
        //    wrapper; Edge Function consumes flat body).
        if (name === "scoreLeads" || name === "getTopLeads") {
          const url = name === "scoreLeads" ? EDGE_SCORE_LEADS_URL : EDGE_GET_TOP_LEADS_URL;
          const payload = { user_token: userToken, ...args };
          // Ghost-lead default for getTopLeads — override-safe: user can pass
          // filters:{min_completeness:0} to include data-sparse matches.
          if (name === "getTopLeads") {
            payload.filters = payload.filters || {};
            if (payload.filters.min_completeness === undefined) {
              payload.filters.min_completeness = 0.5;
            }
          }
          try {
            const { data, ok } = await callEdge(url, payload);
            return json({
              jsonrpc: "2.0",
              id,
              result: {
                content: [{ type: "text", text: JSON.stringify(data) }],
                isError: !ok,
              },
            });
          } catch (e) {
            return json({
              jsonrpc: "2.0",
              id,
              error: { code: -32000, message: "Lead scoring error: " + e.message },
            });
          }
        }

        // Map tool names to Edge Function actions and URLs
        const toolConfig = {
          // Memory tools → n8n-embed
          embedMemory:    { url: EDGE_EMBED_URL, action: "embed" },
          listMemories:   { url: EDGE_EMBED_URL, action: "list" },
          updateMemory:   { url: EDGE_EMBED_URL, action: "update" },
          deleteMemories:  { url: EDGE_EMBED_URL, action: "delete" },
          clearMemories:   { url: EDGE_EMBED_URL, action: "clear" },
          countMemories:   { url: EDGE_EMBED_URL, action: "count" },
          // Search → n8n-search
          searchMemory:    { url: EDGE_SEARCH_URL, action: "search" },
          // Document tools → n8n-embed
          uploadDocument:  { url: EDGE_EMBED_URL, action: "upload_document" },
          listDocuments:   { url: EDGE_EMBED_URL, action: "list_documents" },
          getDocument:     { url: EDGE_EMBED_URL, action: "get_document" },
          deleteDocument:  { url: EDGE_EMBED_URL, action: "delete_document" },
          // Versioning
          getHistory:         { url: EDGE_EMBED_URL, action: "get_history" },
          restoreVersion:     { url: EDGE_EMBED_URL, action: "restore_version" },
          listDeleted:        { url: EDGE_EMBED_URL, action: "list_deleted" },
          // Team & Notifications
          listTeam:           { url: EDGE_EMBED_URL, action: "list_team" },
          sendNotification:   { url: EDGE_EMBED_URL, action: "send_notification" },
          checkNotifications: { url: EDGE_EMBED_URL, action: "check_notifications" },
          // Campaign tools → n8n-embed
          createCampaign:        { url: EDGE_EMBED_URL, action: "create_campaign" },
          listCampaigns:         { url: EDGE_EMBED_URL, action: "list_campaigns" },
          getCampaign:           { url: EDGE_EMBED_URL, action: "get_campaign" },
          updateCampaign:        { url: EDGE_EMBED_URL, action: "update_campaign" },
          listCampaignLeads:     { url: EDGE_EMBED_URL, action: "list_campaign_leads" },
          getCampaignLeadFields: { url: EDGE_EMBED_URL, action: "get_campaign_lead_fields" },
          updateCampaignLead:    { url: EDGE_EMBED_URL, action: "update_campaign_lead" },
          // Working Memory tools → n8n-embed (clear / list_active not exposed)
          setWorkingMemory:      { url: EDGE_EMBED_URL, action: "working_memory_set" },
          getWorkingMemory:      { url: EDGE_EMBED_URL, action: "working_memory_get" },
        };

        const config = toolConfig[name];
        if (!config) {
          return json({ jsonrpc: "2.0", id, error: { code: -32601, message: "Unknown tool: " + name } });
        }

        // Build payload for Edge Function
        const payload = { user_token: userToken, action: config.action };

        if (name === "embedMemory") {
          // Defensive guard against the historical metadata mis-serialization signature:
          // a <metadata> tag, or a bare {"chapter":"..."} JSON fragment appended to the END
          // of the content instead of being passed in the metadata field. Such writes used
          // to silently fall back to the "general" chapter; now they fail loudly.
          const hasTrailingMetadataArtifact = (text) => {
            if (typeof text !== "string" || !text) return false;
            const tail = text.trimEnd();
            // (a) literal <metadata> tag — never part of legitimate memory content
            if (/<metadata\b/i.test(tail)) return true;
            // (b) bare {"chapter": "..."} JSON object at the very end of the content
            if (/\{\s*"chapter"\s*:\s*"[^"]*"[^{}]*\}\s*$/.test(tail)) return true;
            return false;
          };
          if (args.items && Array.isArray(args.items)) {
            const badIdx = args.items.findIndex(it => hasTrailingMetadataArtifact(it && it.content));
            if (badIdx !== -1) {
              return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: `Rejected: items[${badIdx}].content ends with an embedded <metadata>/{"chapter":...} fragment. The chapter must be passed in the metadata field, not serialized into the content. Fix the content and retry.` }], isError: true } });
            }
          } else if (hasTrailingMetadataArtifact(args.content)) {
            return json({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: `Rejected: content ends with an embedded <metadata>/{"chapter":...} fragment. The chapter must be passed in the metadata field, not serialized into the content. Fix the content and retry.` }], isError: true } });
          }

          if (args.metadata && !args.metadata.chapter) args.metadata.chapter = "general";
          if (!args.metadata && args.content) args.metadata = { chapter: "general" };
          if (args.items && Array.isArray(args.items)) {
            args.items = args.items.map(item => ({ ...item, metadata: { chapter: "general", ...(item.metadata || {}) } }));
            payload.items = args.items;
          } else {
            payload.content = args.content;
            payload.metadata = args.metadata;
          }
        } else if (name === "searchMemory") {
          payload.query = args.query;
          payload.match_threshold = args.match_threshold || 0.5;
          payload.match_count = args.limit || 10;
          if (args.metadata_filter) payload.metadata_filter = args.metadata_filter;
        } else if (name === "listMemories") {
          payload.limit = args.limit || 50;
          payload.offset = args.offset || 0;
          if (args.metadata_filter) payload.metadata_filter = args.metadata_filter;
        } else if (name === "updateMemory") {
          payload.embedding_id = args.embedding_id;
          if (args.new_content) payload.new_content = args.new_content;
          if (args.new_metadata) payload.new_metadata = args.new_metadata;
          payload.change_reason = args.change_reason || "Updated via MCP";
        } else if (name === "deleteMemories") {
          payload.embedding_ids = args.embedding_ids;
          payload.change_reason = args.change_reason || "Deleted via MCP";
        } else if (name === "countMemories") {
          if (args.metadata_filter) payload.metadata_filter = args.metadata_filter;
        } else if (name === "uploadDocument") {
          payload.file_base64 = args.file_base64;
          payload.filename = args.filename;
          payload.mime_type = args.mime_type;
          payload.category = args.category || "uploads";
          payload.title = args.title || null;
          payload.description = args.description || null;
          payload.chapter = args.chapter || "general";
          payload.extract_insights = args.extract_insights || false;
        } else if (name === "listDocuments") {
          if (args.category) payload.category = args.category;
          if (args.chapter) payload.chapter = args.chapter;
          if (args.limit) payload.limit = args.limit;
          if (args.offset) payload.offset = args.offset;
        } else if (name === "getDocument") {
          payload.document_id = args.document_id;
        } else if (name === "deleteDocument") {
          payload.document_id = args.document_id;
        }
        // Versioning payloads
        else if (name === "getHistory") {
          payload.embedding_id = args.embedding_id;
        } else if (name === "restoreVersion") {
          payload.version_id = args.version_id;
        } else if (name === "listDeleted") {
          if (args.limit) payload.limit = args.limit;
        }
        // Team & Notification payloads
        else if (name === "listTeam") {
          // No extra params
        } else if (name === "sendNotification") {
          payload.message = args.message;
          if (args.to_prefix) payload.to_prefix = args.to_prefix;
          if (args.context) payload.context = args.context;
          if (args.broadcast) payload.broadcast = args.broadcast;
        } else if (name === "checkNotifications") {
          // No extra params
        } else if (name === "clearMemories") {
          payload.change_reason = args.change_reason || "Cleared all memories via MCP";
          payload.confirm_clear = true;
        }
        // Campaign payloads
        else if (name === "createCampaign") {
          // Forward all known fields; n8n-embed validates required fields
          const fields = ["name", "description", "product_snapshot", "icp_snapshot",
                          "persona_snapshot", "offer", "pain_hypothesis", "messaging_angle",
                          "channels", "start_date", "end_date", "success_metric",
                          "briefing_source", "source_document_id", "notes"];
          for (const f of fields) if (args[f] !== undefined) payload[f] = args[f];
        } else if (name === "listCampaigns") {
          if (args.status) payload.status = args.status;
          if (args.limit) payload.limit = args.limit;
        } else if (name === "getCampaign") {
          payload.campaign_id = args.campaign_id;
        } else if (name === "updateCampaign") {
          payload.campaign_id = args.campaign_id;
          const fields = ["name", "description", "offer", "pain_hypothesis", "messaging_angle",
                          "channels", "start_date", "end_date", "success_metric", "status",
                          "icp_snapshot", "persona_snapshot", "product_snapshot", "notes"];
          for (const f of fields) if (args[f] !== undefined) payload[f] = args[f];
        } else if (name === "listCampaignLeads") {
          payload.campaign_id = args.campaign_id;
          if (args.lifecycle_stage) payload.lifecycle_stage = args.lifecycle_stage;
          if (args.enrichment_status) payload.enrichment_status = args.enrichment_status;
          if (args.limit) payload.limit = args.limit;
        } else if (name === "getCampaignLeadFields") {
          payload.campaign_id = args.campaign_id;
        }
        else if (name === "updateCampaignLead") {
          payload.lead_id = args.lead_id;
          payload.updates = args.updates;
        }
        // Working Memory payloads
        else if (name === "setWorkingMemory") {
          payload.session_id = args.session_id;
          payload.kind = args.kind;
          payload.key = args.key;
          payload.state = args.state;
          payload.ttl_turns = args.ttl_turns ?? null;
          payload.status = args.status ?? "active";
        } else if (name === "getWorkingMemory") {
          payload.session_id = args.session_id;
          payload.kind = args.kind;
          payload.key = args.key;
        }

        console.log("EDGE DIRECT ->", config.action, name);

        try {
          const { data, ok } = await callEdge(config.url, payload);
          const result = { content: [{ type: "text", text: JSON.stringify(data) }], isError: !ok };
          if (ok && name === "countMemories") {
            const sc = { count: Number(data?.count ?? 0) };
            const ch = args.metadata_filter && args.metadata_filter.chapter;
            if (ch) sc.chapter = ch;
            result.structuredContent = sc;
          }
          return json({ jsonrpc: "2.0", id, result });
        } catch (e) {
          console.error("Edge function error:", e);
          return json({ jsonrpc: "2.0", id, error: { code: -32000, message: "Backend error: " + e.message } });
        }
      }

      // =========================================================
      // RESOURCES — Company Context (loaded automatically by MCP clients)
      // =========================================================
      if (method === "resources/list") {
        return json({ jsonrpc: "2.0", id, result: { resources: [
          {
            uri: "growthkit://company/icp",
            name: "Ideal Customer Profile",
            description: "Current ICP definition, buyer personas, target segments, and firmographic criteria.",
            mimeType: "text/plain",
          },
          {
            uri: "growthkit://company/brand-voice",
            name: "Brand Voice & Messaging",
            description: "Brand voice guidelines, tone of voice, CEO messaging strategy, and key messages.",
            mimeType: "text/plain",
          },
          {
            uri: "growthkit://company/positioning",
            name: "Positioning & Strategy",
            description: "Current market positioning, pricing tiers, go-to-market strategy, and competitive differentiation.",
            mimeType: "text/plain",
          },
          {
            uri: "growthkit://company/signals",
            name: "Intent Signals",
            description: "Recent intent signals, lead engagement data, and buying behavior indicators.",
            mimeType: "text/plain",
          },
          {
            uri: "growthkit://company/analytics",
            name: "Sales Analytics & KPIs",
            description: "Current sales KPIs, win rate, pipeline coverage, deal size benchmarks, and performance trends.",
            mimeType: "text/plain",
          },
          {
            uri: "growthkit://system/chapters",
            name: "Memory Chapter Overview",
            description: "Overview of all memory chapters with content counts — shows what knowledge is stored.",
            mimeType: "text/plain",
          },
        ] } });
      }

      if (method === "resources/read") {
        const uri = params?.uri;
        if (!uri) {
          return json({ jsonrpc: "2.0", id, error: { code: -32602, message: "uri parameter is required" } });
        }

        try {
          let content = "";

          if (uri === "growthkit://company/icp") {
            const { data } = await callEdge(EDGE_SEARCH_URL, {
              query: "ideal customer profile buyer persona target audience segment",
              user_token: userToken,
              match_threshold: 0.25,
              match_count: 5,
              metadata_filter: { chapter: "icp" },
              rerank: true,
              rerank_top_k: 3,
            });
            content = formatResourceContent("Ideal Customer Profile", data);
          }

          else if (uri === "growthkit://company/brand-voice") {
            const { data } = await callEdge(EDGE_SEARCH_URL, {
              query: "brand voice tone messaging guidelines key messages",
              user_token: userToken,
              match_threshold: 0.25,
              match_count: 5,
              metadata_filter: { chapter: "brand" },
              rerank: true,
              rerank_top_k: 3,
            });
            content = formatResourceContent("Brand Voice & Messaging", data);
          }

          else if (uri === "growthkit://company/positioning") {
            const { data } = await callEdge(EDGE_SEARCH_URL, {
              query: "positioning pricing go-to-market differentiation strategy",
              user_token: userToken,
              match_threshold: 0.25,
              match_count: 8,
              metadata_filter: { chapter: "strategy" },
              rerank: true,
              rerank_top_k: 3,
            });
            content = formatResourceContent("Positioning & Strategy", data);
          }

          else if (uri === "growthkit://company/signals") {
            const { data } = await callEdge(EDGE_SEARCH_URL, {
              query: "intent signals engagement pricing page demo request buying behavior",
              user_token: userToken,
              match_threshold: 0.25,
              match_count: 8,
              metadata_filter: { chapter: "signals" },
              rerank: true,
              rerank_top_k: 5,
            });
            content = formatResourceContent("Intent Signals & Engagement", data);
          }

          else if (uri === "growthkit://company/analytics") {
            const { data } = await callEdge(EDGE_SEARCH_URL, {
              query: "sales KPIs win rate pipeline coverage deal size forecast benchmarks",
              user_token: userToken,
              match_threshold: 0.25,
              match_count: 8,
              metadata_filter: { chapter: "analytics" },
              rerank: true,
              rerank_top_k: 5,
            });
            content = formatResourceContent("Sales Analytics & KPIs", data);
          }

          else if (uri === "growthkit://system/chapters") {
            const { data } = await callEdge(EDGE_EMBED_URL, {
              action: "overview",
              user_token: userToken,
            });
            content = formatChapterOverview(data);
          }

          else {
            return json({ jsonrpc: "2.0", id, error: { code: -32602, message: "Unknown resource URI: " + uri } });
          }

          return json({ jsonrpc: "2.0", id, result: { contents: [{ uri, mimeType: "text/plain", text: content }] } });

        } catch (err) {
          console.error("Resource read error:", err);
          return json({ jsonrpc: "2.0", id, error: { code: -32603, message: "Failed to read resource" } });
        }
      }

      return json({ jsonrpc: "2.0", id, error: { code: -32601, message: "Method not found" } });
    }

    // =========================================================
    // OAuth Discovery
    // =========================================================
    if (url.pathname === "/.well-known/oauth-authorization-server" || url.pathname === "/.well-known/openid-configuration") {
      return json({
        issuer: BASE_URL,
        authorization_endpoint: BASE_URL + "/authorize",
        token_endpoint: BASE_URL + "/token",
        registration_endpoint: BASE_URL + "/register",
        response_types_supported: ["code"],
        response_modes_supported: ["query"],
        grant_types_supported: ["authorization_code", "refresh_token"],
        code_challenge_methods_supported: ["S256", "plain"],
        scopes_supported: ["mcp:read", "mcp:write"],
        token_endpoint_auth_methods_supported: ["none", "client_secret_post", "client_secret_basic"],
        service_documentation: "https://modelcontextprotocol.io",
        authorization_response_iss_parameter_supported: true,
      });
    }

    if (url.pathname === "/.well-known/oauth-protected-resource") {
      return json({
        resource: BASE_URL,
        authorization_servers: [BASE_URL],
        bearer_methods_supported: ["header"],
        scopes_supported: ["mcp:read", "mcp:write"],
      });
    }

    // =========================================================
    // Dynamic Client Registration
    // =========================================================
    if (request.method === "POST" && url.pathname === "/register") {
      const body = await request.json();
      const { redirect_uris, grant_types, response_types, client_name, scope, token_endpoint_auth_method } = body;
      const client_id = crypto.randomUUID();
      const client_secret = token_endpoint_auth_method === "none" ? undefined : crypto.randomUUID();
      const clientData = {
        client_id, client_secret: client_secret || null,
        redirect_uris: redirect_uris || [], grant_types: grant_types || ["authorization_code"],
        response_types: response_types || ["code"], scope: scope || "mcp:read mcp:write",
        token_endpoint_auth_method: token_endpoint_auth_method || "client_secret_basic",
        client_name: client_name || "MCP Client",
      };
      const insertResponse = await fetch(`${env.SUPABASE_URL}/rest/v1/oauth_clients`, {
        method: "POST",
        headers: sbHeaders(env, { "Content-Type": "application/json", Prefer: "return=minimal" }),
        body: JSON.stringify(clientData),
      });
      if (!insertResponse.ok) { return json({ error: "server_error" }, 500); }
      return json({ client_id, client_secret, client_id_issued_at: Math.floor(Date.now() / 1000), grant_types: clientData.grant_types, redirect_uris: clientData.redirect_uris, response_types: clientData.response_types, scope: clientData.scope, token_endpoint_auth_method: clientData.token_endpoint_auth_method, client_name: clientData.client_name }, 201);
    }

    // =========================================================
    // OAuth Authorize GET
    // =========================================================
    if (request.method === "GET" && url.pathname === "/authorize") {
      const params = Object.fromEntries(url.searchParams.entries());
      const mcpClient = detectMcpClient(url.searchParams.get("redirect_uri"));
      const clientLabel = MCP_CLIENT_LABELS[mcpClient] || "your AI client";
      const lang = (request.headers.get("accept-language") || "").toLowerCase().startsWith("de") ? "de" : "en";
      const pricingUrl = `https://growthkit.tools/${lang}/pricing?utm_source=${encodeURIComponent(mcpClient)}&utm_medium=mcp_oauth&utm_campaign=authorize_screen`;
      console.log(`[authorize] client=${mcpClient} lang=${lang} redirect_uri=${url.searchParams.get("redirect_uri") || ""}`);
      return new Response(
        `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Connect to GrowthKit</title><link rel="icon" type="image/svg+xml" href="/favicon.svg"><style>@font-face{font-family:'Inter';font-weight:400;font-display:swap;src:url('https://growthkit.tools/fonts/inter-400-latin.woff2') format('woff2')}@font-face{font-family:'Inter';font-weight:500;font-display:swap;src:url('https://growthkit.tools/fonts/inter-500-latin.woff2') format('woff2')}@font-face{font-family:'Inter';font-weight:600;font-display:swap;src:url('https://growthkit.tools/fonts/inter-600-latin.woff2') format('woff2')}@font-face{font-family:'Montserrat';font-weight:700;font-display:swap;src:url('https://growthkit.tools/fonts/montserrat-700-latin.woff2') format('woff2')}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:24px;font-family:'Inter',system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:hsl(270 40% 97%)}.card{width:100%;max-width:382px;background:#fff;border:1px solid #E6E1ED;border-radius:16px;padding:30px 28px}.brand{display:flex;align-items:center;gap:11px;margin-bottom:18px}.brand img{width:42px;height:42px;border-radius:11px;display:block}.brand span{font-family:'Montserrat',system-ui,sans-serif;font-weight:700;font-size:25px;letter-spacing:-0.02em;color:hsl(270 53% 12%)}.sub{font-size:14px;color:hsl(280 46% 17%);margin:0 0 22px;line-height:1.4}.lbl{font-size:13px;font-weight:500;color:hsl(280 46% 17%);margin-bottom:7px}input[name=user_token]{width:100%;height:44px;border:1px solid #DED7E8;border-radius:8px;padding:0 13px;font-size:14px;font-family:inherit;color:hsl(270 53% 12%);outline:none;margin-bottom:16px}input[name=user_token]:focus{border-color:hsl(79 100% 50%);box-shadow:0 0 0 3px hsl(79 100% 50% / .25)}button{width:100%;height:46px;border-radius:8px;font-size:15px;cursor:pointer;font-family:'Montserrat',system-ui,sans-serif;font-weight:700}.btn-primary{background:hsl(79 100% 50%);color:hsl(270 53% 12%);border:none;margin-bottom:10px}.btn-demo{background:#fff;color:hsl(280 46% 17%);border:1px solid #DED7E8;font-family:'Inter',sans-serif;font-weight:600}.hint{font-size:12px;color:#8B8398;text-align:center;line-height:1.55;margin:18px 6px 0}.signup{font-size:13px;color:hsl(280 46% 17%);text-align:center;margin:14px 0 0;border-top:1px solid #EFEBF4;padding-top:14px}.signup a{color:hsl(270 53% 12%);font-weight:600;text-decoration:none}#errorMsg{display:none;color:hsl(0 84% 45%);font-size:13px;margin-bottom:10px}</style></head><body><div class="card"><div class="brand"><img src="/favicon.svg" alt="GrowthKit"><span>GrowthKit</span></div><p class="sub">Connect ${clientLabel} to GrowthKit MCP</p><form id="authForm" method="POST" action="/authorize">${Object.entries(params).map(([k, v]) => `<input type="hidden" name="${k}" value="${v.replace(/"/g, "&quot;")}" />`).join("")}<div class="lbl">Your GrowthKit token</div><input id="user_token" name="user_token" placeholder="gk_…" autocomplete="off"><div id="errorMsg">Please enter a valid token (starts with gk_).</div><button type="submit" class="btn-primary">Authorize</button><button type="submit" name="demo" value="1" formnovalidate class="btn-demo">Try the demo (no token)</button></form><p class="hint">Your token identifies your GrowthKit workspace. The demo connects a read-only sample workspace — no signup needed.</p><p class="signup">New to GrowthKit? <a href="${pricingUrl}">See plans &amp; pricing &rarr;</a></p></div><script>document.getElementById("authForm").addEventListener("submit",function(e){if(e.submitter&&e.submitter.name==="demo")return;var t=document.getElementById("user_token").value.trim();if(!t.startsWith("gk_")){e.preventDefault();document.getElementById("errorMsg").style.display="block"}});</script></body></html>`,
        { headers: { "Content-Type": "text/html", ...CORS_HEADERS } }
      );
    }

    // =========================================================
    // OAuth Authorize POST
    // =========================================================
    if (request.method === "POST" && url.pathname === "/authorize") {
      const formData = await request.text();
      const body = Object.fromEntries(new URLSearchParams(formData));
      const { response_type, client_id, redirect_uri, state, scope, code_challenge, code_challenge_method, user_token } = body;
      const isDemo = body.demo === "1" || body.demo === 1;

      if (response_type !== "code") return json({ error: "unsupported_response_type" }, 400);
      if (!client_id || !redirect_uri) return json({ error: "invalid_request" }, 400);

      // Resolve the effective gk_ token. For the demo path it comes from the
      // server-side secret and is NEVER echoed to the browser.
      let effectiveUserToken;
      if (isDemo) {
        effectiveUserToken = env.DEMO_USER_TOKEN;
        if (!effectiveUserToken) return new Response("<html><body><p>Demo is temporarily unavailable.</p></body></html>", { status: 503, headers: { "Content-Type": "text/html" } });
        } else {
        if (!user_token || !user_token.startsWith("gk_")) {
          const retryUrl = new URL(BASE_URL + "/authorize");
          for (const [k, v] of Object.entries(body)) { if (k !== "user_token") retryUrl.searchParams.set(k, v); }
          return new Response(`<html><body><p>Invalid token. <a href="${retryUrl}">Try again</a>.</p></body></html>`, { status: 400, headers: { "Content-Type": "text/html" } });
        }
        effectiveUserToken = user_token;
        try {
          const validationResponse = await fetch(EDGE_EMBED_URL, {
            method: "POST",
            headers: { "Content-Type": "application/json", Authorization: `Bearer ${env.N8N_AUTH_TOKEN}` },
            body: JSON.stringify({ action: "validate_token", user_token }),
          });
          if (!validationResponse.ok) return new Response("<html><body><p>Token validation failed.</p></body></html>", { status: 401, headers: { "Content-Type": "text/html" } });
          const validationData = await validationResponse.json();
          if (!validationData.valid) return new Response("<html><body><p>Invalid token.</p></body></html>", { status: 401, headers: { "Content-Type": "text/html" } });
        } catch (e) {
          console.error("Token validation error:", e);
        }
      }

      if (scope) {
        const scopes = scope.split(" ");
        if (!scopes.every(s => ["mcp:read", "mcp:write"].includes(s))) return json({ error: "invalid_scope" }, 400);
      }
      if (code_challenge_method && code_challenge_method !== "S256" && code_challenge_method !== "plain") return json({ error: "invalid_request" }, 400);

      // Client/Lang server-side ableiten (POST-Scope hat kein url-Objekt).
      const postClient = detectMcpClient(redirect_uri);
      const postLang = (request.headers.get("accept-language") || "").toLowerCase().startsWith("de") ? "de" : "en";

      const code = crypto.randomUUID();
      await fetch(`${env.SUPABASE_URL}/rest/v1/oauth_codes`, {
        method: "POST",
        headers: sbHeaders(env, { "Content-Type": "application/json", Prefer: "return=minimal" }),
        body: JSON.stringify({ code, client_id, redirect_uri, scope: isDemo ? "mcp:read" : (scope || "mcp:read mcp:write"), code_challenge: code_challenge || null, code_challenge_method: code_challenge_method || null, user_token: effectiveUserToken, expires_at: Date.now() + 10 * 60 * 1000, is_demo: isDemo, mcp_client: postClient, lang: postLang }),
      });

      const redirectUrl = new URL(redirect_uri);
      redirectUrl.searchParams.set("code", code);
      if (state) redirectUrl.searchParams.set("state", state);
      redirectUrl.searchParams.set("iss", BASE_URL);
      return Response.redirect(redirectUrl.toString(), 302);
    }

    // =========================================================
    // OAuth Token Endpoint
    // =========================================================
    if (request.method === "POST" && url.pathname === "/token") {
      let body = {};
      const contentType = request.headers.get("content-type") || "";
      if (contentType.includes("application/json")) { body = await request.json(); }
      else if (contentType.includes("application/x-www-form-urlencoded")) { body = Object.fromEntries(new URLSearchParams(await request.text())); }

      let clientIdFromAuth = null;
      const authHeader = request.headers.get("authorization");
      if (authHeader && authHeader.startsWith("Basic ")) {
        try {
          const decoded = atob(authHeader.replace("Basic ", ""));
          const [iid] = decoded.split(":");
          clientIdFromAuth = decodeURIComponent(iid);
        } catch (e) {}
      }

      const grant_type = body.grant_type;
      const client_id = clientIdFromAuth || body.client_id;

      if (grant_type === "authorization_code") {
        const code = body.code;
        const code_verifier = body.code_verifier;
        if (!code || !client_id) return json({ error: "invalid_request" }, 400);

        const codeResponse = await fetch(`${env.SUPABASE_URL}/rest/v1/oauth_codes?code=eq.${code}`, {
          headers: sbHeaders(env),
        });
        if (!codeResponse.ok) return json({ error: "server_error" }, 500);
        const rows = await codeResponse.json();
        if (!rows.length) return json({ error: "invalid_grant" }, 400);
        const stored = rows[0];
        if (Number(stored.expires_at) < Date.now()) return json({ error: "invalid_grant" }, 400);
        if (body.redirect_uri && stored.redirect_uri !== body.redirect_uri) return json({ error: "invalid_grant" }, 400);

        if (stored.code_challenge && code_verifier) {
          let computed;
          if (stored.code_challenge_method === "S256") {
            const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(code_verifier));
            computed = btoa(String.fromCharCode(...new Uint8Array(digest))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
          } else { computed = code_verifier; }
          if (computed !== stored.code_challenge) return json({ error: "invalid_grant" }, 400);
        }

        await fetch(`${env.SUPABASE_URL}/rest/v1/oauth_codes?code=eq.${code}`, {
          method: "DELETE", headers: sbHeaders(env),
        });

        const access_token = crypto.randomUUID();
        const refresh_token = crypto.randomUUID();
        const tokenScope = stored.scope || "mcp:read mcp:write";

        await fetch(`${env.SUPABASE_URL}/rest/v1/oauth_tokens`, {
          method: "POST",
          headers: sbHeaders(env, { "Content-Type": "application/json", Prefer: "return=minimal" }),
          body: JSON.stringify({ access_token, refresh_token, client_id, scope: tokenScope, user_token: stored.user_token, expires_at: Date.now() + 3600 * 1000, refresh_expires_at: Date.now() + 14 * 24 * 3600 * 1000, is_demo: stored.is_demo === true, mcp_client: stored.mcp_client || null, lang: stored.lang || null }),
        });

        return json({ access_token, token_type: "Bearer", expires_in: 3600, refresh_token, scope: tokenScope });
      }

      if (grant_type === "refresh_token") {
        const refresh_token = body.refresh_token;
        if (!refresh_token) return json({ error: "invalid_request" }, 400);

        const tokenResponse = await fetch(`${env.SUPABASE_URL}/rest/v1/oauth_tokens?refresh_token=eq.${refresh_token}`, {
          headers: sbHeaders(env),
        });
        if (!tokenResponse.ok) return json({ error: "server_error" }, 500);
        const tokenRows = await tokenResponse.json();
        if (!tokenRows.length) return json({ error: "invalid_grant" }, 400);
        const storedToken = tokenRows[0];
        if (Number(storedToken.refresh_expires_at) < Date.now()) return json({ error: "invalid_grant" }, 400);

        const new_access_token = crypto.randomUUID();
        await fetch(`${env.SUPABASE_URL}/rest/v1/oauth_tokens?refresh_token=eq.${refresh_token}`, {
          method: "PATCH",
          headers: sbHeaders(env, { "Content-Type": "application/json", Prefer: "return=minimal" }),
          body: JSON.stringify({ access_token: new_access_token, expires_at: Date.now() + 3600 * 1000 }),
        });

        return json({ access_token: new_access_token, token_type: "Bearer", expires_in: 3600, scope: storedToken.scope || "mcp:read mcp:write" });
      }

      return json({ error: "unsupported_grant_type" }, 400);
    }

    return json({ error: "not_found" }, 404);
  },
};
