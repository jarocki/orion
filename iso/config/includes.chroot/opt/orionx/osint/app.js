/* Orion-X Investigation Surface — launcher logic.
 * @decision DEC-PHASE12-043
 *
 * Three rules this file exists to enforce, in the browser, every render:
 *   1. An off-deck link is never presented as if it would work. If the deck
 *      has no default route, or is at a posture where reaching out is wrong,
 *      the link is inert and the page says which, why, and what to do.
 *   2. The page never claims a state it has not read. If /api/status.json is
 *      unreachable it fails CLOSED: posture unknown, outbound disabled.
 *   3. No external resource is ever fetched. Everything comes from this origin.
 */
"use strict";

var S = {status:null, links:null, recipes:null, filter:"all", query:""};

var CAT_LABEL = {
  "methodology":"method", "verification":"verify", "geolocation":"geoloc",
  "image-video-forensics":"image/video", "corporate-records":"corporate",
  "archives":"archive", "infrastructure":"infra",
  "transport-tracking":"transport", "social-people":"people",
  "malware-intel":"malware"
};

function el(tag, cls, text){
  var n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined && text !== null) n.textContent = String(text);
  return n;
}
function clear(n){ while (n.firstChild) n.removeChild(n.firstChild); }

function banner(kind, title, body, remedy){
  var b = el("div", "banner " + kind);
  b.appendChild(el("h3", null, title));
  if (body) b.appendChild(el("p", null, body));
  if (remedy) b.appendChild(el("code", "remedy", remedy));
  return b;
}

/* ---- status ------------------------------------------------------------ */

function failClosedStatus(reason){
  return {
    offline_page: true,
    posture: {known:false, label:"unknown", reason:reason},
    route: {default_route:false, interface:null},
    outbound: {allowed:false, state:"no-status",
      headline:"Deck status unavailable — off-deck links disabled",
      detail:reason + " This page cannot tell what posture the deck is in or " +
             "whether it has a route, so it will not offer a link that reaches " +
             "out. Everything under ON THIS DECK is unaffected.",
      remedy:"orionx-osint        # start the local server and open this page from it"},
    geoip: {available:false, reason:"not checked", remedy:""},
    bus: {present:false, reason:"not checked", remedy:""}
  };
}

function loadStatus(){
  if (location.protocol === "file:") {
    S.status = failClosedStatus("This page was opened directly from disk.");
    return Promise.resolve();
  }
  return fetch("api/status.json", {cache:"no-store"})
    .then(function(r){ if(!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
    .then(function(j){ S.status = j; })
    .catch(function(e){
      S.status = failClosedStatus("Could not read the deck's own status (" + e.message + ").");
    });
}

function renderStrip(){
  var strip = document.getElementById("strip");
  clear(strip);
  var st = S.status;

  function chip(label, value, level){
    var c = el("span", "chip");
    c.appendChild(el("span", "dot " + level));
    c.appendChild(document.createTextNode(label + " "));
    c.appendChild(el("b", null, value));
    strip.appendChild(c);
  }
  chip("posture", st.posture.known ? st.posture.label : "UNKNOWN",
       st.posture.known ? (st.posture.tier === "2" ? "warn" : "go") : "stop");
  chip("route", st.route.default_route
        ? ("via " + (st.route.interface || "default")) : "none",
       st.route.default_route ? "go" : "warn");
  chip("off-deck links", st.outbound.allowed ? "enabled" : "DISABLED",
       st.outbound.allowed ? "go" : "stop");
  chip("geoip", st.geoip.available ? "loaded" : "absent",
       st.geoip.available ? "go" : "warn");
  chip("event bus", st.bus.present ? "live" : "not yet",
       st.bus.present ? "go" : "warn");
}

function renderBanners(){
  var host = document.getElementById("banners");
  clear(host);
  var st = S.status;

  if (location.protocol === "file:") {
    host.appendChild(banner("stop",
      "Opened from disk — most of this page cannot work",
      "CyberChef needs Web Workers and the catalogue needs fetch(); browsers " +
      "deny both to a file:// origin. Start the local server instead. It binds " +
      "127.0.0.1 only and nothing on the network can reach it.",
      "orionx-osint"));
  }
  if (!st.outbound.allowed) {
    host.appendChild(banner(st.outbound.state === "shields-up" ? "warn" : "stop",
      st.outbound.headline, st.outbound.detail, st.outbound.remedy));
  }
  if (!st.geoip.available && !st.offline_page) {
    host.appendChild(banner("info",
      "No geolocation database — the attack map places nothing",
      "That is the intended default. " + (st.geoip.reason || "") +
      " The map still shows every source, its scope (private / CGNAT / public), " +
      "volume, severity and ports; public sources are labelled UNLOCATED rather " +
      "than given a position. Installing a database adds country and ASN " +
      "labels only — still no coordinates. See /opt/orionx/osint/GEOIP.txt.",
      st.geoip.remedy || "sudo /opt/orionx/optional/install-geoip.sh"));
  }
}

/* ---- cards ------------------------------------------------------------- */

function b64url(s){
  var bytes = new TextEncoder().encode(s), bin = "";
  for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/=+$/, "");
}

function chefUrl(rec){
  var u = "cyberchef/#recipe=" + encodeURIComponent(rec.recipe);
  if (rec.input) u += "&input=" + encodeURIComponent(b64url(rec.input));
  return u;
}

function copyButton(text, label){
  var b = el("button", "btn copy", label || "copy command");
  b.type = "button";
  b.addEventListener("click", function(){
    var done = function(){ b.textContent = "copied"; setTimeout(function(){
      b.textContent = label || "copy command"; }, 1400); };
    var fail = function(){ b.textContent = "select it above"; };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, fail);
    } else { fail(); }
  });
  return b;
}

function localCard(item){
  var c = el("div", "card local");
  var top = el("div", "top");
  top.appendChild(el("h3", null, item.name));
  top.appendChild(el("span", "badge local", "on deck"));
  c.appendChild(top);
  c.appendChild(el("p", null, item.blurb));
  if (item.kind === "command" && item.command) {
    c.appendChild(el("div", "cmd", item.command));
  }
  var foot = el("div", "foot");
  if (item.kind === "page" && item.launch) {
    var a = el("a", "btn go", "open");
    a.href = item.launch.replace(/^\//, "");
    foot.appendChild(a);
  } else if (item.command) {
    foot.appendChild(copyButton(item.command));
  }
  foot.appendChild(el("span", "badge cat", item.category));
  c.appendChild(foot);
  return c;
}

function recipeCard(rec){
  var c = el("div", "card local");
  var top = el("div", "top");
  top.appendChild(el("h3", null, rec.name));
  top.appendChild(el("span", "badge local", "local"));
  c.appendChild(top);
  c.appendChild(el("p", null, rec.why));
  c.appendChild(el("div", "cmd", rec.recipe));
  var foot = el("div", "foot");
  var a = el("a", "btn go", rec.input ? "open with example" : "open");
  a.href = chefUrl(rec);
  foot.appendChild(a);
  foot.appendChild(el("span", "badge cat", rec.group));
  c.appendChild(foot);
  return c;
}

function installCard(item){
  var c = el("div", "card install");
  var top = el("div", "top");
  top.appendChild(el("h3", null, item.name));
  top.appendChild(el("span", "badge install", "installable"));
  c.appendChild(top);
  c.appendChild(el("p", null, item.blurb));
  c.appendChild(el("div", "cmd", item.command));
  var foot = el("div", "foot");
  foot.appendChild(copyButton(item.command));
  foot.appendChild(el("span", "badge cat", "needs network"));
  c.appendChild(foot);
  return c;
}

function onlineCard(item){
  var allowed = S.status.outbound.allowed;
  var c = el("div", "card online" + (allowed ? "" : " blocked"));
  var top = el("div", "top");
  top.appendChild(el("h3", null, item.name));
  top.appendChild(el("span", "badge offdeck", "off deck"));
  c.appendChild(top);
  c.appendChild(el("p", null, item.note));
  if (item.caution) {
    var w = el("p", "why");
    w.appendChild(el("span", "badge caution", "caution"));
    w.appendChild(document.createTextNode(" " + item.caution));
    c.appendChild(w);
  }
  c.appendChild(el("div", "url", item.url));
  var foot = el("div", "foot");
  if (allowed) {
    var a = el("a", "btn out", "open ↗");
    a.href = item.url; a.target = "_blank"; a.rel = "noopener noreferrer";
    foot.appendChild(a);
  } else {
    var dead = el("button", "btn dead", "unavailable");
    dead.type = "button"; dead.disabled = true;
    dead.title = S.status.outbound.headline;
    foot.appendChild(dead);
  }
  foot.appendChild(copyButton(item.url, "copy URL"));
  foot.appendChild(el("span", "badge cat", CAT_LABEL[item.category] || item.category));
  c.appendChild(foot);
  return c;
}

/* ---- filtering + render ------------------------------------------------ */

function matches(hay){
  if (!S.query) return true;
  return hay.toLowerCase().indexOf(S.query) !== -1;
}

function renderFilters(){
  var host = document.getElementById("filters");
  clear(host);
  var cats = ["all"];
  (S.links.online || []).forEach(function(o){
    if (cats.indexOf(o.category) === -1) cats.push(o.category);
  });
  cats.forEach(function(cat){
    var b = el("button", null, cat === "all" ? "all off-deck" : (CAT_LABEL[cat] || cat));
    b.type = "button";
    b.setAttribute("aria-pressed", String(S.filter === cat));
    b.addEventListener("click", function(){ S.filter = cat; render(); });
    host.appendChild(b);
  });
}

function fill(gridId, items, make, emptyMsg){
  var g = document.getElementById(gridId);
  clear(g);
  if (!items.length) {
    var p = el("p", "empty", emptyMsg);
    g.parentNode.insertBefore(p, g);
    return;
  }
  items.forEach(function(i){ g.appendChild(make(i)); });
}

function dropEmptyNotes(){
  Array.prototype.slice.call(document.querySelectorAll("p.empty"))
    .forEach(function(n){ n.parentNode.removeChild(n); });
}

function render(){
  renderStrip();
  renderBanners();
  renderFilters();
  dropEmptyNotes();

  var L = S.links;
  fill("grid-local",
    (L.local || []).filter(function(i){
      return matches(i.name + " " + i.blurb + " " + i.category + " " + (i.command||""));
    }), localCard, "Nothing matches that filter.");

  fill("grid-recipes",
    ((S.recipes && S.recipes.recipes) || []).filter(function(r){
      return matches(r.name + " " + r.why + " " + r.group + " " + r.recipe);
    }), recipeCard, "Nothing matches that filter.");

  fill("grid-install",
    (L.installable || []).filter(function(i){
      return matches(i.name + " " + i.blurb + " " + i.command);
    }), installCard, "Nothing matches that filter.");

  var online = (L.online || []).filter(function(o){
    return (S.filter === "all" || o.category === S.filter) &&
           matches(o.name + " " + o.note + " " + o.category + " " + o.url);
  });
  fill("grid-online", online, onlineCard, "Nothing matches that filter.");

  var lede = document.getElementById("online-lede");
  lede.textContent =
    online.length + " of " + (L.online || []).length + " resources shown. " +
    "Every URL here returned HTTP 200 at its final address on " +
    (L.online_verified || "the verification date") + "; anything that did not " +
    "was dropped rather than shipped as a maybe. Links are " +
    (S.status.outbound.allowed ? "live." : "DISABLED right now — see the banner above.");
}

function renderFooter(){
  var f = document.getElementById("footer");
  clear(f);
  var st = S.status, parts = [];
  parts.push("DEC-PHASE12-043 · Orion-X Phoenix Edition.");
  parts.push("CyberChef 11.5.0, Apache-2.0, vendored and served locally — " +
             "/opt/orionx/osint/cyberchef/PROVENANCE.txt.");
  parts.push("Attack map inspired by IPew (hrbrmstr/pewpew, CC BY-SA 4.0); " +
             "its sound is vendored, its code is not — " +
             "/opt/orionx/osint/pewpew/PROVENANCE.txt.");
  parts.push("Off-deck catalogue seeded from Bellingcat's Online Investigation " +
             "Toolkit and verified link by link.");
  if (st.geoip && st.geoip.available) {
    parts.push("IP Geolocation by DB-IP (https://db-ip.com), CC BY 4.0.");
  }
  f.appendChild(el("p", null, parts.join(" ")));
}

function fatal(msg, remedy){
  var host = document.getElementById("banners");
  host.appendChild(banner("stop", "The launcher could not load its catalogue", msg, remedy));
}

function boot(){
  document.getElementById("q").addEventListener("input", function(e){
    S.query = e.target.value.trim().toLowerCase();
    render();
  });

  loadStatus().then(function(){
    renderStrip();
    renderBanners();
    return Promise.all([
      fetch("links.json", {cache:"no-store"}).then(function(r){ return r.json(); }),
      fetch("recipes.json", {cache:"no-store"}).then(function(r){ return r.json(); })
    ]);
  }).then(function(res){
    S.links = res[0];
    S.recipes = res[1];
    render();
    renderFooter();
  }).catch(function(e){
    fatal("links.json / recipes.json could not be read (" + e.message + "). " +
          "Nothing is listed because nothing could be verified — the page " +
          "will not guess at a catalogue.",
          "orionx-osint --check");
  });

  // Loop: posture and route change under the operator's feet. Re-ask.
  setInterval(function(){
    if (location.protocol === "file:") return;
    loadStatus().then(function(){ if (S.links) render(); });
  }, 15000);
}

document.addEventListener("DOMContentLoaded", boot);
