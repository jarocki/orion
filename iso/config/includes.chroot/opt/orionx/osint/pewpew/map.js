/* Orion-X attack map — renderer.
 * @decision DEC-PHASE12-043
 *
 * The one rule: a source is drawn where its CLASSIFICATION puts it, never
 * where a guess at its location would. Sectors are scope (private / CGNAT /
 * public-unlocated / public-located / other); the angle inside a sector is a
 * stable hash of the address, so a host keeps its place between refreshes.
 * The page says this on its face, in #layout-note, every render.
 *
 * No library. No CDN. No world outline — see ../GEOIP.txt for why.
 */
"use strict";

var FEED = null, PAUSED = false, SOUND = false, SELECTED = null;
var TRACERS = [], LAST_TS = 0, RAF = null, LAYOUT = {};

var SCOPE_SECTORS = [
  {key:"private",   label:"PRIVATE · RFC1918", color:"#7ab8ff",
   match:function(s){ return s.scope === "private"; }},
  {key:"cgnat",     label:"CGNAT · 100.64/10", color:"#c08cff",
   match:function(s){ return s.scope === "cgnat"; }},
  {key:"located",   label:"PUBLIC · LOCATED",  color:"#34ff9e",
   match:function(s){ return s.scope === "public" && s.location.located; }},
  {key:"unlocated", label:"PUBLIC · UNLOCATED", color:"#ff6a13",
   match:function(s){ return s.scope === "public" && !s.location.located; }},
  {key:"other",     label:"LOOPBACK / LINK-LOCAL / RESERVED", color:"#6b7280",
   match:function(){ return true; }}
];

var SEV_COLOR = {critical:"#ff5f56", warning:"#ffb300", notice:"#7ab8ff", info:"#6b7280"};

function $(id){ return document.getElementById(id); }
function el(t,c,x){ var n=document.createElement(t); if(c)n.className=c;
  if(x!==undefined&&x!==null)n.textContent=String(x); return n; }
function clear(n){ while(n.firstChild) n.removeChild(n.firstChild); }

/* Stable 32-bit hash so a host sits in the same spot across polls. */
function hash32(s){
  var h = 2166136261;
  for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = (h * 16777619) >>> 0; }
  return h >>> 0;
}

function sectorOf(src){
  for (var i = 0; i < SCOPE_SECTORS.length; i++) {
    if (SCOPE_SECTORS[i].match(src)) return SCOPE_SECTORS[i];
  }
  return SCOPE_SECTORS[SCOPE_SECTORS.length - 1];
}

function ago(ts, now){
  var d = Math.max(0, now - ts);
  if (d < 60) return Math.round(d) + "s ago";
  if (d < 3600) return Math.round(d / 60) + "m ago";
  return Math.round(d / 3600) + "h ago";
}

/* ---- layout ------------------------------------------------------------ */

function computeLayout(){
  var cv = $("sky"), stage = $("stage");
  var dpr = window.devicePixelRatio || 1;
  var w = stage.clientWidth, h = stage.clientHeight;
  cv.width = Math.max(1, Math.round(w * dpr));
  cv.height = Math.max(1, Math.round(h * dpr));
  cv.style.width = w + "px"; cv.style.height = h + "px";
  var ctx = cv.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

  LAYOUT = {ctx:ctx, w:w, h:h, cx:w/2, cy:h/2,
            r:Math.max(70, Math.min(w, h) / 2 - 54)};

  if (!FEED) return;
  // Only sectors that actually have sources get arc space. An empty "LOCATED"
  // wedge on a deck with no GeoIP would imply the map could place things.
  var present = SCOPE_SECTORS.filter(function(sec){
    return FEED.sources.some(function(s){ return sectorOf(s) === sec; });
  });
  var span = present.length ? (Math.PI * 2) / present.length : Math.PI * 2;
  var at = -Math.PI / 2;
  present.forEach(function(sec){ sec._a0 = at; sec._a1 = at + span; at += span; });
  LAYOUT.sectors = present;

  var perSector = {};
  FEED.sources.forEach(function(s){
    var sec = sectorOf(s);
    (perSector[sec.key] = perSector[sec.key] || []).push(s);
  });
  Object.keys(perSector).forEach(function(k){
    var list = perSector[k], sec = null;
    for (var i = 0; i < SCOPE_SECTORS.length; i++) {
      if (SCOPE_SECTORS[i].key === k) sec = SCOPE_SECTORS[i];
    }
    if (!sec || sec._a0 === undefined) return;
    var pad = (sec._a1 - sec._a0) * 0.10;
    var a0 = sec._a0 + pad, a1 = sec._a1 - pad;
    list.sort(function(a, b){ return a.ip < b.ip ? -1 : 1; });
    list.forEach(function(s, i){
      var frac = list.length === 1 ? 0.5 : i / (list.length - 1);
      s._ang = a0 + (a1 - a0) * frac;
      // Deterministic radial jitter so overlapping hosts stay readable and
      // stay put. Radius carries no meaning and the note on screen says so.
      s._rad = LAYOUT.r * (0.68 + ((hash32(s.ip) % 1000) / 1000) * 0.30);
      s._x = LAYOUT.cx + Math.cos(s._ang) * s._rad;
      s._y = LAYOUT.cy + Math.sin(s._ang) * s._rad;
      s._sec = sec;
    });
  });
}

/* ---- drawing ----------------------------------------------------------- */

function draw(t){
  RAF = requestAnimationFrame(draw);
  var L = LAYOUT, ctx = L.ctx;
  if (!ctx) return;
  ctx.clearRect(0, 0, L.w, L.h);

  // Range rings — pure chrome, no scale implied.
  ctx.save();
  ctx.strokeStyle = "rgba(255,255,255,0.045)";
  ctx.lineWidth = 1;
  [0.35, 0.6, 0.85, 1.0].forEach(function(f){
    ctx.beginPath(); ctx.arc(L.cx, L.cy, L.r * f, 0, Math.PI * 2); ctx.stroke();
  });
  ctx.restore();

  if (L.sectors) {
    L.sectors.forEach(function(sec){
      ctx.save();
      ctx.strokeStyle = sec.color; ctx.globalAlpha = 0.28; ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(L.cx, L.cy, L.r * 1.04, sec._a0 + 0.03, sec._a1 - 0.03);
      ctx.stroke();
      ctx.globalAlpha = 0.85;
      var mid = (sec._a0 + sec._a1) / 2;
      var lx = L.cx + Math.cos(mid) * (L.r * 1.12);
      var ly = L.cy + Math.sin(mid) * (L.r * 1.12);
      ctx.fillStyle = sec.color;
      ctx.font = "600 10px 'DejaVu Sans Mono', monospace";
      ctx.textAlign = Math.cos(mid) > 0.25 ? "left" : (Math.cos(mid) < -0.25 ? "right" : "center");
      ctx.textBaseline = Math.sin(mid) > 0 ? "top" : "bottom";
      ctx.fillText(sec.label, lx, ly);
      ctx.restore();
    });
  }

  // The deck.
  var pulse = 1 + Math.sin(t / 620) * 0.08;
  ctx.save();
  ctx.translate(L.cx, L.cy);
  var g = ctx.createRadialGradient(0, 0, 2, 0, 0, 26 * pulse);
  g.addColorStop(0, "rgba(255,106,19,0.95)");
  g.addColorStop(1, "rgba(255,106,19,0)");
  ctx.fillStyle = g;
  ctx.beginPath(); ctx.arc(0, 0, 26 * pulse, 0, Math.PI * 2); ctx.fill();
  ctx.fillStyle = "#ff6a13";
  ctx.beginPath();
  for (var i = 0; i < 6; i++) {
    var a = (Math.PI / 3) * i - Math.PI / 2;
    var px = Math.cos(a) * 9, py = Math.sin(a) * 9;
    if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
  }
  ctx.closePath(); ctx.fill();
  ctx.fillStyle = "#9aa0a6";
  ctx.font = "600 9px 'DejaVu Sans Mono', monospace";
  ctx.textAlign = "center"; ctx.textBaseline = "top";
  ctx.fillText("THIS DECK", 0, 16);
  ctx.restore();

  if (!FEED) return;

  // Tracers.
  var now = performance.now();
  TRACERS = TRACERS.filter(function(tr){ return now - tr.born < tr.life; });
  TRACERS.forEach(function(tr){
    var s = tr.src;
    if (s._x === undefined) return;
    var p = (now - tr.born) / tr.life;
    var ease = p * p * (3 - 2 * p);
    var x = s._x + (L.cx - s._x) * ease;
    var y = s._y + (L.cy - s._y) * ease;
    ctx.save();
    ctx.strokeStyle = tr.color; ctx.globalAlpha = 0.20;
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(s._x, s._y); ctx.lineTo(L.cx, L.cy); ctx.stroke();
    ctx.globalAlpha = 1 - p * 0.35;
    ctx.lineWidth = 2; ctx.lineCap = "round";
    var tailX = s._x + (L.cx - s._x) * Math.max(0, ease - 0.11);
    var tailY = s._y + (L.cy - s._y) * Math.max(0, ease - 0.11);
    ctx.beginPath(); ctx.moveTo(tailX, tailY); ctx.lineTo(x, y); ctx.stroke();
    ctx.fillStyle = tr.color;
    ctx.beginPath(); ctx.arc(x, y, 2.4, 0, Math.PI * 2); ctx.fill();
    if (p > 0.93) {
      ctx.globalAlpha = (1 - p) / 0.07;
      ctx.beginPath(); ctx.arc(L.cx, L.cy, 14 + (p - 0.93) * 180, 0, Math.PI * 2);
      ctx.strokeStyle = tr.color; ctx.lineWidth = 1.6; ctx.stroke();
    }
    ctx.restore();
  });

  // Source nodes.
  FEED.sources.forEach(function(s){
    if (s._x === undefined) return;
    var col = SEV_COLOR[s.max_severity] || "#6b7280";
    var size = 3.2 + Math.min(7, Math.log(1 + s.events) * 2.1);
    var on = SELECTED === s.ip;
    ctx.save();
    ctx.globalAlpha = on ? 1 : 0.9;
    var gg = ctx.createRadialGradient(s._x, s._y, 1, s._x, s._y, size * 3);
    gg.addColorStop(0, col); gg.addColorStop(1, "rgba(0,0,0,0)");
    ctx.globalAlpha = on ? 0.5 : 0.28;
    ctx.fillStyle = gg;
    ctx.beginPath(); ctx.arc(s._x, s._y, size * 3, 0, Math.PI * 2); ctx.fill();
    ctx.globalAlpha = 1; ctx.fillStyle = col;
    ctx.beginPath(); ctx.arc(s._x, s._y, size, 0, Math.PI * 2); ctx.fill();
    if (on) {
      ctx.strokeStyle = "#e6e8ec"; ctx.lineWidth = 1.4;
      ctx.beginPath(); ctx.arc(s._x, s._y, size + 5, 0, Math.PI * 2); ctx.stroke();
    }
    // The label is the address plus, where it exists, the country code. Never
    // a place name the map did not get from a database.
    var label = s.ip + (s.location.located ? "  " + s.location.country : "");
    ctx.fillStyle = on ? "#e6e8ec" : "#9aa0a6";
    ctx.font = (on ? "600 " : "") + "10px 'DejaVu Sans Mono', monospace";
    ctx.textAlign = s._x < LAYOUT.cx ? "right" : "left";
    ctx.textBaseline = "middle";
    ctx.fillText(label, s._x + (s._x < LAYOUT.cx ? -(size + 6) : size + 6), s._y);
    ctx.restore();
  });
}

/* ---- side panel -------------------------------------------------------- */

function renderList(){
  var host = $("list");
  clear(host);
  var now = FEED ? FEED.generated : Date.now() / 1000;

  if (!FEED || !FEED.sources.length) {
    var why = el("div", "empty");
    if (!FEED) {
      why.textContent = "Waiting for the first poll.";
    } else if (!FEED.bus_readable) {
      why.textContent = "The event bus at " + FEED.bus_path + " could not be " +
        "read. The map is empty because there is nothing to read, not because " +
        "nothing happened — those are different and this one is the bad one.";
    } else {
      why.textContent = "No events with a source address in the last " +
        Math.round(FEED.window_seconds / 60) + " minutes. " +
        (FEED.unattributed ? (FEED.unattributed + " event(s) arrived with no " +
          "source address in their structured detail; they are counted below " +
          "the map but cannot be drawn as a source.")
         : "On a quiet deck this is the correct picture.");
    }
    host.appendChild(why);
    return;
  }

  FEED.sources.forEach(function(s){
    var row = el("div", "src" + (SELECTED === s.ip ? " on" : ""));
    row.tabIndex = 0;
    var l1 = el("div", "l1");
    l1.appendChild(el("span", "ip", s.ip));
    var tags = el("span");
    tags.appendChild(el("span", "tag " + s.max_severity, s.max_severity));
    tags.appendChild(document.createTextNode(" "));
    tags.appendChild(el("span", "tag " + (s.scope === "public" ? "public" :
      (s.scope === "private" ? "private" : (s.scope === "cgnat" ? "cgnat" : "other"))),
      s.scope));
    l1.appendChild(tags);
    row.appendChild(l1);

    var bits = [];
    bits.push(s.events + " event" + (s.events === 1 ? "" : "s"));
    if (s.distinct_ports) bits.push(s.distinct_ports + " ports");
    if (s.protocols.length) bits.push(s.protocols.join("/"));
    bits.push(ago(s.last_seen, now));
    var meta = el("div", "meta", bits.join("  ·  "));
    row.appendChild(meta);

    var loc = el("div", "meta");
    if (s.location.located) {
      loc.appendChild(el("span", "tag located", "located"));
      loc.appendChild(document.createTextNode(" " + s.location.country_name +
        " (" + s.location.country + ")" +
        (s.location.asn ? "  ·  " + s.location.asn : "") +
        (s.location.as_org ? "  " + s.location.as_org : "")));
    } else {
      loc.appendChild(el("span", "tag unlocated", "unlocated"));
      loc.appendChild(document.createTextNode(" " + s.location.reason));
    }
    row.appendChild(loc);

    if (s.detectors.length || s.kinds.length) {
      row.appendChild(el("div", "meta",
        (s.kinds.length ? s.kinds.join(", ") + "  —  " : "") +
        "seen by " + s.detectors.join(", ")));
    }

    row.addEventListener("click", function(){
      SELECTED = (SELECTED === s.ip) ? null : s.ip;
      renderList();
    });
    row.addEventListener("keydown", function(e){
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); row.click(); }
    });
    host.appendChild(row);
  });

  if (FEED.unattributed) {
    host.appendChild(el("div", "empty",
      FEED.unattributed + " event(s) in this window carry no source address " +
      "in their structured detail and so cannot be placed. They are not lost " +
      "— see the Cockpit event stream, or: orionx-logquery --report summary"));
  }
}

/* ---- banners ----------------------------------------------------------- */

function banner(kind, title, body, remedy){
  var b = el("div", "banner " + kind);
  b.appendChild(el("h3", null, title));
  if (body) b.appendChild(el("p", null, body));
  if (remedy) b.appendChild(el("code", null, remedy));
  return b;
}

function renderBanners(){
  var host = $("alerts");
  clear(host);
  if (!FEED) return;

  if (location.protocol === "file:") {
    host.appendChild(banner("stop", "Opened from disk — this map has no data",
      "It reads its feed over HTTP from orionx-osint, and a file:// page cannot " +
      "fetch. Nothing you see would be live.", "orionx-osint --page pewpew"));
    return;
  }
  if (!FEED.bus_readable) {
    host.appendChild(banner("stop", "Event bus unreadable — this map is blind",
      "Nothing can be drawn because nothing can be read from " + FEED.bus_path +
      ". An empty map here does NOT mean a quiet network. The deck's detectors " +
      "may still be running and publishing; this page just cannot see them.",
      "systemctl status orionx-scanwatch orionx-postured"));
  }
  if (!FEED.geoip.available) {
    host.appendChild(banner("info", "No geolocation — nothing is placed, by design",
      "This map has no world outline and draws no coordinates. " +
      (FEED.geoip.reason || "") + " Public sources are labelled UNLOCATED " +
      "rather than guessed at. Installing a database adds country and ASN " +
      "LABELS only — still no positions. Scope, volume, ports, protocols, " +
      "severity and timing are all unaffected and all true.",
      FEED.geoip_remedy));
  }
  if (FEED.counts.sources_capped) {
    host.appendChild(banner("warn", "Source list truncated",
      "More than " + FEED.counts.max_sources + " distinct sources appeared in " +
      "this window; " + FEED.counts.sources_dropped + " are not drawn. That is " +
      "usually a spoofed-source flood. The map is bounded on purpose, but what " +
      "you see is a sample, not the set.",
      "orionx-logquery --report summary"));
  }
  if (FEED.counts.malformed_lines) {
    host.appendChild(banner("warn", FEED.counts.malformed_lines +
      " unparseable line(s) on the bus",
      "Skipped rather than guessed at. If this number keeps climbing, " +
      "something is writing malformed JSON to the event spool.",
      "tail -n 20 " + FEED.bus_path));
  }
}

/* ---- chrome ------------------------------------------------------------ */

function setChip(dotId, valId, text, level){
  var d = $(dotId);
  d.className = "dot" + (level ? " " + level : "");
  $(valId).textContent = text;
}

function renderChrome(){
  if (!FEED) return;
  setChip("d-bus", "v-bus", FEED.bus_readable ? "live" : "unreadable",
          FEED.bus_readable ? "go" : "stop");
  setChip("d-src", "v-src", String(FEED.counts.sources),
          FEED.counts.sources ? "go" : "");
  setChip("d-geo", "v-geo", FEED.geoip.available ? "loaded" : "absent",
          FEED.geoip.available ? "go" : "warn");

  $("count-note").textContent = " · " + FEED.counts.located + " located, " +
    FEED.counts.unlocated + " unlocated";

  $("layout-note").textContent =
    "Bearing and distance on this diagram are LAYOUT, not location. A host's " +
    "angle places it in its scope sector; its radius is a stable hash of the " +
    "address so it stays put between refreshes. Node size is event volume, " +
    "colour is highest severity. Nothing here is a geographic position.";

  var foot = $("foot");
  clear(foot);
  var p = el("p");
  p.style.margin = "0";
  p.textContent = "Fed from " + FEED.bus_path + " · window " +
    Math.round(FEED.window_seconds / 60) + " min · " +
    FEED.counts.events_parsed + " bus records read · " +
    FEED.counts.sources + " sources, " + FEED.unattributed +
    " unattributable · DEC-PHASE12-043. " +
    "Inspired by IPew (hrbrmstr/pewpew, CC BY-SA 4.0); the pew sound is theirs, " +
    "the code is not." +
    (FEED.geoip.available ? "  IP Geolocation by DB-IP (https://db-ip.com), CC BY 4.0." : "");
  foot.appendChild(p);
}

/* ---- polling + tracer scheduling --------------------------------------- */

function spawnTracers(feed){
  // Only events newer than the last poll become tracers, so a refresh does
  // not replay the whole window as if it had just happened.
  var fresh = feed.tracers.filter(function(t){ return t.ts > LAST_TS; });
  if (feed.tracers.length) LAST_TS = feed.tracers[feed.tracers.length - 1].ts;
  if (!fresh.length) return;

  var byIp = {};
  feed.sources.forEach(function(s){ byIp[s.ip] = s; });
  var spread = Math.min(4000, 260 * fresh.length);
  fresh.slice(-60).forEach(function(t, i, arr){
    var src = byIp[t.ip];
    if (!src) return;
    setTimeout(function(){
      if (PAUSED) return;
      TRACERS.push({src:src, born:performance.now(), life:1250,
                    color:SEV_COLOR[t.severity] || "#6b7280"});
      if (SOUND) {
        var a = $("pew");
        try { a.currentTime = 0; a.play(); } catch (e) { /* no audio device */ }
      }
    }, arr.length === 1 ? 0 : (spread * i) / arr.length);
  });
}

function poll(){
  if (location.protocol === "file:") {
    FEED = {bus_readable:false, bus_path:"(not served)", sources:[], tracers:[],
            unattributed:0, window_seconds:900, generated:Date.now()/1000,
            geoip:{available:false, reason:""}, geoip_remedy:"orionx-osint",
            counts:{sources:0, located:0, unlocated:0, events_parsed:0,
                    malformed_lines:0, sources_capped:false, sources_dropped:0,
                    max_sources:0}};
    renderBanners(); renderChrome(); renderList();
    return;
  }
  var w = $("window").value;
  fetch("../api/pewpew.json?window=" + encodeURIComponent(w), {cache:"no-store"})
    .then(function(r){ if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
    .then(function(j){
      FEED = j;
      computeLayout();
      renderBanners(); renderChrome(); renderList();
      if (!PAUSED) spawnTracers(j);
    })
    .catch(function(e){
      var host = $("alerts");
      clear(host);
      host.appendChild(banner("stop", "Lost contact with orionx-osint",
        "The map cannot refresh (" + e.message + "). What is on screen is " +
        "stale and should not be trusted as current.",
        "orionx-osint --page pewpew"));
    });
}

function boot(){
  $("pause").addEventListener("click", function(){
    PAUSED = !PAUSED;
    this.setAttribute("aria-pressed", String(PAUSED));
    this.textContent = PAUSED ? "paused" : "pause";
  });
  $("sound").addEventListener("click", function(){
    SOUND = !SOUND;
    this.setAttribute("aria-pressed", String(SOUND));
    this.textContent = SOUND ? "sound on" : "sound off";
  });
  $("window").addEventListener("change", function(){ LAST_TS = 0; poll(); });
  $("sky").addEventListener("click", function(ev){
    if (!FEED) return;
    var rect = this.getBoundingClientRect();
    var x = ev.clientX - rect.left, y = ev.clientY - rect.top, best = null, bd = 400;
    FEED.sources.forEach(function(s){
      if (s._x === undefined) return;
      var d = (s._x - x) * (s._x - x) + (s._y - y) * (s._y - y);
      if (d < bd) { bd = d; best = s; }
    });
    SELECTED = best ? best.ip : null;
    renderList();
  });
  window.addEventListener("resize", function(){ computeLayout(); });

  computeLayout();
  RAF = requestAnimationFrame(draw);
  poll();
  setInterval(function(){ if (!PAUSED) poll(); }, 5000);
}

document.addEventListener("DOMContentLoaded", boot);
