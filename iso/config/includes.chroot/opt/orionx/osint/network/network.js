/* Orion-X "This network" page (#93). @decision DEC-PHASE12-043, DEC-PHASE13-046
 *
 * Renders /api/network.json and computes nothing of its own: every number,
 * every state word and the two headline lines come from
 * scripts/awareness/network_picture.py, the module the Cockpit's NETWORK panel
 * reads too. Honest obligations this file keeps:
 *   1. Every count is shown with its window and the label the API carries
 *      ("observed by this deck"). The page never claims an inventory of the segment.
 *   2. No geolocation. There is no map, no flag, no country column.
 *   3. A row the engine marks "unknown" is drawn as unknown and names the log
 *      it needed; it is never drawn as zero.
 *   4. Everything from the API is written with textContent. DNS names, DHCP
 *      hostnames and SSDP user agents are attacker-chosen strings.
 *   5. (#94, DEC-PHASE13-047) The operator-initiated section transmits only
 *      from a button's click handler. Gateway values carry "reported by the
 *      gateway, not measured"; a refused upstream probe shows the refusal.
 */
"use strict";

var POLL_MS = 10000;
var PAUSED = false;
var PIC = null;

function $(id){ return document.getElementById(id); }
function el(tag, cls, text){
  var n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined && text !== null) n.textContent = String(text);
  return n;
}
function clear(n){ while (n.firstChild) n.removeChild(n.firstChild); }
function fmtTs(ts){
  if (!ts) return "—";
  var d = new Date(ts * 1000);
  return d.toLocaleTimeString();
}
function fmtBytes(n){
  if (n === null || n === undefined) return "—";
  var u = ["B","KiB","MiB","GiB","TiB"], i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return (i === 0 ? n : n.toFixed(1)) + " " + u[i];
}

function banner(kind, title, body, remedy){
  var b = el("div", "banner " + kind);
  b.appendChild(el("h3", null, title));
  if (body) b.appendChild(el("p", null, body));
  if (remedy) b.appendChild(el("code", "remedy", remedy));
  return b;
}

function setDot(id, level){ $(id).className = "dot" + (level ? " " + level : ""); }

function renderStrip(p){
  $("v-hosts").textContent = p.summary.hosts + (p.summary.lower_bound ? "+" : "") + " · " + p.summary.window;
  setDot("d-hosts", "go");
  var z = p.zeek || {};
  $("v-zeek").textContent = z.state === "ok" ? ("ok · " + (z.logs || []).join(",")) : (z.state || "unknown");
  setDot("d-zeek", z.state === "ok" ? "go" : (z.state === "unreadable" ? "stop" : "warn"));
  var o = p.oui || {};
  $("v-oui").textContent = o.source ? (o.entries + " prefixes") : "none";
  setDot("d-oui", o.source ? "go" : "warn");
}

function renderBanners(p){
  var box = $("banners"); clear(box);
  var z = p.zeek || {};
  if (z.state !== "ok") {
    var rows = (p.degraded || []).map(function(k){ return k.replace("sightings.", ""); });
    box.appendChild(banner(
      z.state === "unreadable" ? "stop" : "warn",
      "Zeek is " + (z.state || "unavailable") + " — this picture is neighbour-table and OUI only",
      "Degraded rows (shown as unknown, not as zero): " + (rows.length ? rows.join(", ") : "none") +
      ". " + (z.reason || ""),
      z.state === "unreadable" ? "sudo orionx-osint   # or read the Zeek log directory as a user that can"
                               : "sudo /opt/orionx/optional/install-zeek.sh   # or raise the posture to Tier 1"));
  } else if (p.degraded && p.degraded.length) {
    box.appendChild(banner("warn", "Some Zeek logs are not present",
      "Rows marked unknown needed: " + p.degraded.join(", ") + ". " + (z.reason || ""), ""));
  }
  if (p.bounded && p.bounded.lower_bound) {
    box.appendChild(banner("info", "Counts are a lower bound",
      (p.reasons || []).filter(function(r){ return r.indexOf("lower bound") >= 0; }).join(" "), ""));
  }
  if (!(p.oui && p.oui.source)) {
    box.appendChild(banner("info", "No OUI registry readable — vendor column empty",
      (p.oui && p.oui.reason) || "", "sudo apt install ieee-data"));
  }
}

function card(title, big, note, label, dim){
  var c = el("div", "card");
  c.appendChild(el("h3", null, title));
  c.appendChild(el("div", "big" + (dim ? " dim" : ""), big));
  if (note) c.appendChild(el("p", null, note));
  if (label) c.appendChild(el("span", "label", label));
  return c;
}

function renderHeadline(p){
  var s = p.summary;
  $("headline-lede").textContent = s.headline + " — " + s.split_line;
  var box = $("cards"); clear(box);
  var h = p.hosts || {};
  box.appendChild(card("Active hosts", s.hosts + (s.lower_bound ? " (at least)" : ""),
    h.from_neigh + " from the neighbour table" + (h.sources && h.sources.indexOf("conn.log") >= 0 ?
      (", " + h.zeek_only + " only in Zeek conn.log (" + s.window + ")") : "; Zeek conn.log not available") +
    ". " + (h.neigh_note || ""), s.label));
  var sp = p.split || {};
  if (sp.available) {
    var c = card("Local vs internet", Math.round(sp.local_pct) + "% / " + Math.round(sp.internet_pct) + "%",
      "by " + sp.basis + " over " + sp.conns + " connections in Zeek conn.log, " + s.window + ". local: " +
      fmtBytes(sp.local.bytes) + " in " + sp.local.conns + " conns; internet: " + fmtBytes(sp.internet.bytes) +
      " in " + sp.internet.conns + " conns. RFC 1918 classification, not location.", s.label);
    var bar = el("div", "bar");
    var a = el("span", "local"); a.style.width = sp.local_pct + "%";
    var b = el("span", "inet"); b.style.width = sp.internet_pct + "%";
    bar.appendChild(a); bar.appendChild(b);
    c.insertBefore(bar, c.children[2]);
    box.appendChild(c);
  } else {
    box.appendChild(card("Local vs internet", "unknown", (sp.reason || "needs Zeek conn.log") +
      " — not shown as 0/0.", s.label, true));
  }
  var z = p.zeek || {};
  box.appendChild(card("Zeek", z.state || "unknown",
    z.state === "ok" ? ("reading " + (z.logs || []).join(", ") + " in " + (z.sources || [z.dir]).join(", ") +
      (z.reason ? ". " + z.reason : "")) : (z.reason || ""), "sensor state", z.state !== "ok"));
  var b2 = p.bounded || {};
  box.appendChild(card("Engine", (b2.elapsed_ms || 0) + " ms",
    "budget " + b2.budget_seconds + " s; host cap " + (b2.caps ? b2.caps.hosts : "—") +
    "; log tails capped per file. The Cockpit draws the same headline every 5 s.", "bounded, read-only", true));
}

function renderSightings(p){
  var box = $("sightings"); clear(box);
  var S = p.sightings || {};
  var order = ["wpad", "netbios", "llmnr", "mdns", "ldap", "dhcp", "ssdp", "iot"];
  var t = el("table");
  var th = el("tr");
  ["Class", "State", "Count", "Hosts", "Seen", "Source", "Why it matters"].forEach(function(h){ th.appendChild(el("th", null, h)); });
  t.appendChild(th);
  order.forEach(function(k){
    var s = S[k]; if (!s) return;
    var tr = el("tr", s.state === "unknown" ? "degraded" : null);
    tr.appendChild(el("td", null, s.label || k));
    var st = el("td"); st.appendChild(el("span", "state " + s.state, s.state)); tr.appendChild(st);
    tr.appendChild(el("td", "mono", s.state === "unknown" ? "—" : s.count));
    var hosts = el("td", "mono");
    if (s.state === "unknown") hosts.appendChild(el("span", "faint", "needs Zeek " + (s.needs || []).join(" or ")));
    else {
      hosts.textContent = (s.hosts || []).join(", ") + (s.hosts_truncated ? " …" : "");
      if (s.samples && s.samples.length) {
        hosts.appendChild(el("br"));
        hosts.appendChild(el("span", "faint", s.samples.join(" · ")));
      }
      if (s.servers && s.servers.length) {
        hosts.appendChild(el("br"));
        hosts.appendChild(el("span", "faint", "server(s): " + s.servers.join(", ")));
      }
    }
    tr.appendChild(hosts);
    tr.appendChild(el("td", "mono", s.state === "present" ? fmtTs(s.last_ts) : (s.state === "absent" ? "none in " + p.summary.window : "—")));
    tr.appendChild(el("td", "mono", (s.sources || []).join(", ") || "—"));
    tr.appendChild(el("td", null, (s.detail || "") + (s.heuristic ? " [heuristic]" : "")));
    t.appendChild(tr);
  });
  box.appendChild(t);
}

function renderArp(p){
  var box = $("arp"); clear(box);
  var rows = (p.arp && p.arp.rows) || [];
  if (!rows.length) {
    box.appendChild(el("div", "empty", "No neighbour entries with a hardware address. " +
      ((p.reasons || []).filter(function(r){ return r.indexOf("ip neigh") === 0; }).join(" ") || "")));
    return;
  }
  var t = el("table");
  var th = el("tr");
  ["Address", "MAC", "Vendor (OUI)", "State", "Interface", "Notes"].forEach(function(h){ th.appendChild(el("th", null, h)); });
  t.appendChild(th);
  rows.forEach(function(r){
    var tr = el("tr");
    tr.appendChild(el("td", "mono", r.ip));
    tr.appendChild(el("td", "mono", r.mac));
    var v = el("td", null, r.vendor || "");
    if (!r.vendor) v.appendChild(el("span", "faint", r.vendor_note || "—"));
    tr.appendChild(v);
    tr.appendChild(el("td", "mono", (r.state || "—") + (r.live ? "" : " (not live)")));
    tr.appendChild(el("td", "mono", r.dev || "—"));
    tr.appendChild(el("td", null, [r.router ? "router flag" : "", r.random_mac ? "randomised address" : ""].filter(Boolean).join(", ")));
    t.appendChild(tr);
  });
  box.appendChild(t);
  if (p.arp.truncated) box.appendChild(el("div", "empty", "Showing the first " + rows.length + " of " + p.arp.count + " entries."));
}

/* #94 / DEC-PHASE13-047: the operator-initiated section. p.active carries the
 * IDLE entries from the engine; a button POSTs to the entry's endpoint and the
 * answer (same shape: {id, label, state, gated_by, result, refusal?}) replaces
 * the idle entry until the page is reloaded. Nothing here runs on load or on
 * the poll timer: the button's click handler below is the only caller of
 * the run function. */
var ACTIVE_RESULTS = {};
var ACTIVE_RUNNING = {};

function dl(pairs, claim){
  var d = el("dl");
  pairs.forEach(function(kv){
    if (kv[1] === null || kv[1] === undefined || kv[1] === "") return;
    d.appendChild(el("dt", null, kv[0]));
    var dd = el("dd", null, kv[1]);
    if (claim) { dd.appendChild(el("br")); dd.appendChild(el("span", "claim", claim)); }
    d.appendChild(dd);
  });
  return d;
}
function list(items){
  var ul = el("ul");
  (items || []).forEach(function(s){ ul.appendChild(el("li", null, s)); });
  return ul;
}
function refusalBanner(r){
  // GODSEYE-style: what is off, why it matters, what still works, the remedy.
  var b = el("div", "banner stop");
  b.appendChild(el("h3", null, r.headline || "Refused"));
  b.appendChild(el("p", "claim", (r.label || "") + " · refused by orionx-osint · " + (r.state || "")));
  if (r.what) b.appendChild(el("p", null, "What was not sent: " + r.what));
  if (r.so_what) b.appendChild(el("p", null, "Why: " + r.so_what));
  if (r.still_works) b.appendChild(el("p", null, "Still works: " + r.still_works));
  if (r.remedy) b.appendChild(el("code", "remedy", r.remedy));
  return b;
}

function renderGatewayResult(c, it){
  var r = it.result || {};
  var claim = it.claim_label || r.claim_label;
  if (r.caution) c.appendChild(banner("warn", "Transmitted at a raised posture", r.caution, ""));
  if (!r.answered) {
    c.appendChild(banner("info", "The gateway did not answer", r.note || "No SSDP answer.", ""));
  }
  var dv = r.device;
  if (dv) {
    c.appendChild(el("p", "claim", "Identity — " + claim));
    c.appendChild(dl([["Friendly name", dv.friendly_name], ["Manufacturer", dv.manufacturer],
      ["Model", dv.model_name], ["Model number", dv.model_number], ["Description", dv.model_description],
      ["SSDP server", dv.server], ["Answered from", dv.peer], ["Description URL", dv.location]], claim));
  }
  var w = r.wan;
  if (w) {
    c.appendChild(el("p", "claim", "WAN — " + claim));
    c.appendChild(dl([["External IP", w.external_ip ? (w.external_ip + " (" + w.external_ip_class + ")") : null],
      ["Access type", w.access_type], ["Link status", w.link_status],
      ["Downstream rate", w.downstream_label], ["Upstream rate", w.upstream_label]], claim));
  }
  if (r.errors && r.errors.length) { c.appendChild(el("p", null, "Not answered:")); c.appendChild(list(r.errors)); }
  if (r.skipped && r.skipped.length) {
    c.appendChild(el("p", null, "Answers not followed:"));
    c.appendChild(list(r.skipped.map(function(s){ return s.location + " — " + s.why; })));
  }
  c.appendChild(el("p", null, "Sent (" + (r.elapsed_ms || 0) + " ms):"));
  c.appendChild(list(r.sent));
}

function renderOutboundResult(c, it){
  var r = it.result || {};
  var t, tr;
  if (r.dns) {
    c.appendChild(el("p", null, "DNS — " + r.dns.verdict));
    t = el("table"); tr = el("tr");
    ["Canary", "Expected", "System resolver", "Direct (" + (r.dns.resolvers || []).join(", ") + ")"].forEach(function(h){ tr.appendChild(el("th", null, h)); });
    t.appendChild(tr);
    r.dns.rows.forEach(function(row){
      var x = el("tr");
      x.appendChild(el("td", "mono", row.name));
      x.appendChild(el("td", "mono", (row.expected || []).join(", ")));
      x.appendChild(el("td", "mono", ((row.system || []).join(", ") || "—") + " · " + row.system_verdict));
      x.appendChild(el("td", "mono", ((row.direct || []).join(", ") || "—") + " · " + row.direct_verdict));
      t.appendChild(x);
    });
    var nx = r.dns.nxdomain || {};
    var y = el("tr");
    y.appendChild(el("td", "mono", nx.name)); y.appendChild(el("td", "mono", "NXDOMAIN"));
    y.appendChild(el("td", "mono", ((nx.system || []).join(", ") || nx.system_rcode || nx.system_error || "—") + " · " + nx.verdict));
    y.appendChild(el("td", "mono", (nx.direct || []).join(", ") || nx.direct_rcode || nx.direct_error || "—"));
    t.appendChild(y);
    c.appendChild(t);
  }
  if (r.captive) c.appendChild(el("p", null, "Captive portal — " + r.captive.verdict + " (" + r.captive.url + ")"));
  if (r.ports) {
    c.appendChild(el("p", null, "Ports — " + r.ports.verdict + ". " + r.ports.note + "."));
    t = el("table"); tr = el("tr");
    ["Port", "Target", "Service", "Result"].forEach(function(h){ tr.appendChild(el("th", null, h)); });
    t.appendChild(tr);
    r.ports.rows.forEach(function(row){
      var x = el("tr");
      [row.port, row.host, row.service, row.result].forEach(function(v){ x.appendChild(el("td", "mono", v)); });
      t.appendChild(x);
    });
    c.appendChild(t);
  }
  if (r.errors && r.errors.length) c.appendChild(list(r.errors));
  c.appendChild(el("p", null, "Sent (" + (r.elapsed_ms || 0) + " ms): " + (r.sent || "")));
}

function runActive(it){
  ACTIVE_RUNNING[it.id] = true;
  if (PIC) renderActive(PIC);
  fetch("../" + it.endpoint.replace(/^\//, ""), {method: "POST", cache: "no-store",
        headers: {"X-Orionx-Operator": "1"}})
    .then(function(r){ return r.json().then(function(j){ if (!r.ok) throw new Error(j.detail || ("HTTP " + r.status)); return j; }); })
    .then(function(j){ ACTIVE_RESULTS[it.id] = j; })
    .catch(function(e){ ACTIVE_RESULTS[it.id] = {id: it.id, state: "error", label: it.label, gated_by: it.gated_by,
                                                  endpoint: it.endpoint, result: {errors: [String(e.message || e)], sent: []}}; })
    .then(function(){ ACTIVE_RUNNING[it.id] = false; if (PIC) renderActive(PIC); });
}

function renderActive(p){
  var sec = $("sec-active"), box = $("active"); clear(box);
  var items = p.active || [];
  if (!items.length) { sec.className = "hidden"; return; }
  sec.className = "";
  items.forEach(function(idle){
    var it = ACTIVE_RESULTS[idle.id] || idle;
    var c = el("div", "card active");
    c.appendChild(el("h3", null, idle.label || idle.id));
    c.appendChild(el("span", "label", idle.claim_label || idle.probe_label || ""));
    c.appendChild(el("p", null, idle.what || ""));
    c.appendChild(el("p", null, "Gated by " + (idle.gated_by || "—") + ". Pressing the button sends: " + (idle.sends || "—")));
    var btn = el("button", "ctl run", ACTIVE_RUNNING[idle.id] ? "running…" : (it.state === "idle" ? idle.button : "run again"));
    btn.type = "button";
    btn.disabled = !!ACTIVE_RUNNING[idle.id];
    btn.addEventListener("click", function(){ runActive(idle); });
    c.appendChild(btn);
    if (it.state === "refused" && it.refusal) c.appendChild(refusalBanner(it.refusal));
    else if (it.state !== "idle" && it.result) {
      c.appendChild(el("p", "claim", "state: " + it.state + " · " + new Date((it.generated || 0) * 1000).toLocaleTimeString()));
      if (idle.id === "gateway") renderGatewayResult(c, it); else renderOutboundResult(c, it);
    }
    box.appendChild(c);
  });
}

function renderFooter(p){
  var f = $("foot"); clear(f);
  f.appendChild(el("p", null, "Generated " + new Date(p.generated * 1000).toLocaleString() + " · window " +
    p.summary.window + " · " + p.label + " · engine " + (p.bounded ? p.bounded.elapsed_ms : "—") + " ms · " +
    p.decision + " · data: scripts/awareness/network_picture.py (also the Cockpit NETWORK panel)."));
  if (p.reasons && p.reasons.length) {
    var ul = el("ul");
    p.reasons.forEach(function(r){ ul.appendChild(el("li", null, r)); });
    f.appendChild(ul);
  }
}

function render(p){
  PIC = p;
  renderStrip(p); renderBanners(p); renderHeadline(p);
  renderSightings(p); renderArp(p); renderActive(p); renderFooter(p);
}

function failed(msg){
  var box = $("banners"); clear(box);
  box.appendChild(banner("stop", "Could not read the network picture",
    msg + " The page shows nothing rather than a stale or invented picture.",
    "orionx-osint --status   # is the Workbench server running?"));
  $("v-hosts").textContent = "—"; setDot("d-hosts", "stop");
}

function poll(){
  var w = $("window").value;
  fetch("../api/network.json?window=" + encodeURIComponent(w), {cache: "no-store"})
    .then(function(r){ if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
    .then(render)
    .catch(function(e){ failed(String(e.message || e)); });
}

function boot(){
  $("window").addEventListener("change", poll);
  $("pause").addEventListener("click", function(){
    PAUSED = !PAUSED;
    this.setAttribute("aria-pressed", PAUSED ? "true" : "false");
    this.textContent = PAUSED ? "resume" : "pause";
  });
  poll();
  setInterval(function(){ if (!PAUSED) poll(); }, POLL_MS);
}
boot();
