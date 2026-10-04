/* Orion-X — GODSEYE preflight logic.
 * @decision DEC-PHASE12-045
 *
 * Three rules this file exists to enforce:
 *   1. The globe is never the first thing shown. This page always renders
 *      first, and it names what GODSEYE cannot do on this deck before it
 *      offers any way in.
 *   2. It decides nothing. /api/status.json is the single authority for
 *      posture and route; orionx-osint refuses the bundle independently.
 *      This page can only agree. If it cannot read the status it fails
 *      CLOSED.
 *   3. No external resource is ever fetched. Everything is this origin.
 */
"use strict";

var S = { status: null };

/* The capability table. Hand-maintained and deliberately pessimistic: the
 * only honest thing to say about a layer whose backend does not exist is
 * that it does not work, and to say it before the operator waits for dots
 * that are never coming. Cross-checked by tests/unit/test_godseye.sh
 * against the routes osint_server.py actually refuses. */
var CAPS = [
  ["Base map &amp; terrain", "live",
   "Esri World Imagery + Re:Earth terrain, fetched live. With no network the globe has no map at all."],
  ["Satellites", "live",
   "CelesTrak element sets, propagated in the browser. The bundled element set is frozen at vendoring time and goes stale."],
  ["Seismic (USGS, IRIS)", "live", "Direct browser fetch from usgs.gov and iris.edu."],
  ["Natural hazards (EONET, GDACS, FIRMS)", "live",
   "Direct, except FIRMS which is relayed through r.jina.ai."],
  ["Weather, air quality, space weather", "live",
   "NOAA and Open-Meteo. Several of these are relayed through api.allorigins.win."],
  ["Maritime ports", "live", "Static WFP/ORNL dataset shipped in the bundle, plus live NGA notices."],
  ["Aircraft (direct ADS-B)", "live",
   "adsb.lol / adsb.one / airplanes.live are fetched directly by the browser."],
  ["Aircraft (OpenSky proxy)", "dead",
   "Routed through upstream's Node backend. Orion-X runs no Node, so this path answers HTTP 501."],
  ["CCTV cameras", "dead",
   "Source index and frame grabs are Node-backend routes (HTTP 501). Individual stream URLs in the bundled manifest still play, one deliberate click at a time."],
  ["Radio stations", "dead", "Node-backend route (HTTP 501)."],
  ["Traffic flow", "dead", "Node-backend route (HTTP 501)."],
  ["Overpass / OSM queries", "dead", "Node-backend route (HTTP 501)."],
  ["Photorealistic 3-D tiles", "nokey", "Needs a Google Maps or Cesium ion key. None ships, and none can be added without rebuilding the bundle."],
  ["AIS live vessels", "nokey", "Needs an AISstream key."],
  ["Guardian intel enrichment", "nokey", "Needs a Guardian key."],
  ["YouTube camera discovery", "nokey", "Needs a YouTube Data key."],
  ["AI mission briefing", "nokey", "Needs a Gemini key; would send your view to Google."],
  ["Shared Firebase cache", "nokey", "Needs a Firebase RTDB URL and secret."]
];

var VERDICT_LABEL = { live: "works", dead: "no backend", nokey: "no key" };

function el(tag, cls, text) {
  var n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text !== undefined && text !== null) n.textContent = String(text);
  return n;
}
function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); }

/* ---- status: one authority, fail closed -------------------------------- */

function failClosed(reason) {
  return {
    offline_page: true,
    posture: { known: false, label: "unknown", reason: reason },
    route: { default_route: false, interface: null },
    outbound: {
      allowed: false, state: "no-status",
      headline: "Deck status unavailable — GODSEYE will not be offered",
      detail: reason + " This page cannot tell what posture the deck is in " +
              "or whether it has a route, so it will not open a globe that " +
              "would reach out to dozens of third parties.",
      remedy: "orionx-osint --page godseye   # start the local server and open this page from it"
    }
  };
}

function loadStatus() {
  if (location.protocol === "file:") {
    S.status = failClosed("This page was opened directly from disk.");
    return Promise.resolve();
  }
  return fetch("/api/status.json", { cache: "no-store" })
    .then(function (r) { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
    .then(function (j) { S.status = j; })
    .catch(function (e) {
      S.status = failClosed("Could not read the deck's own status (" + e.message + ").");
    });
}

/* ---- render ------------------------------------------------------------ */

function renderStrip() {
  var strip = document.getElementById("strip");
  clear(strip);
  var st = S.status;
  function chip(label, value, level) {
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
  chip("GODSEYE", st.outbound.allowed ? "may be served" : "REFUSED",
       st.outbound.allowed ? "go" : "stop");
}

function dl(pairs) {
  var d = el("dl");
  pairs.forEach(function (p) {
    if (!p[1]) return;
    d.appendChild(el("dt", null, p[0]));
    d.appendChild(el("dd", null, p[1]));
  });
  return d;
}

function renderVerdict() {
  var host = document.getElementById("verdict");
  clear(host);
  var st = S.status, ob = st.outbound;

  if (location.protocol === "file:") {
    var f = el("div", "banner stop");
    f.appendChild(el("h3", null, "Opened from disk — nothing here can work"));
    f.appendChild(dl([["What", "GODSEYE needs an HTTP origin: browsers deny " +
      "fetch() and Web Workers to file://, and the posture gate lives in the " +
      "server, not in this page."]]));
    f.appendChild(el("code", "remedy", "orionx-osint --page godseye"));
    host.appendChild(f);
    return;
  }

  if (!ob.allowed) {
    var b = el("div", "banner " + (ob.state === "shields-up" ? "warn" : "stop"));
    b.appendChild(el("h3", null, ob.headline ||
      "GODSEYE will not be served right now"));
    b.appendChild(dl([
      ["What is not working",
       "The globe. Every layer in GODSEYE is a live third-party request, " +
       "including the map underneath them."],
      ["Why that matters", ob.state === "no-route"
        ? "With no route the globe would draw a featureless dark sphere. " +
          "That is indistinguishable from a quiet world, and it is not " +
          "evidence of one — it is evidence that this deck asked nobody."
        : "Opening it would announce this deck, and the subject of your " +
          "interest, to several dozen hosts — about fifteen of them through " +
          "anonymous public relays that see your address and your query."],
      ["What still works",
       "Everything on the investigation surface that runs here: CyberChef, " +
       "the artifact and PCAP tools, and the R.A.I.N. attack map of what " +
       "THIS deck has actually seen."],
      ["Detail", ob.detail || ""]
    ]));
    if (ob.remedy) b.appendChild(el("code", "remedy", ob.remedy));
    host.appendChild(b);
    return;
  }

  var g = el("div", "banner go");
  g.appendChild(el("h3", null, ob.headline || "A route exists — GODSEYE may be opened"));
  g.appendChild(dl([
    ["Before you click",
     "A default route is not proof the internet is reachable, and GODSEYE " +
     "will start contacting third parties the moment it loads. The posture " +
     "is " + (S.status.posture.label || "unknown") + "."],
    ["If the posture rises while it is open",
     "The overlay inside GODSEYE re-reads the deck every 15 seconds and " +
     "covers the globe, because a globe drawn from old requests is stale " +
     "data that still looks live."]
  ]));
  host.appendChild(g);
}

function renderCaps() {
  var body = document.getElementById("caps");
  clear(body);
  var counts = { live: 0, dead: 0, nokey: 0 };
  CAPS.forEach(function (row) {
    counts[row[1]] += 1;
    var tr = el("tr");
    var name = el("td", "name");
    name.innerHTML = row[0];
    tr.appendChild(name);
    var v = el("td");
    v.appendChild(el("span", "verdict " + row[1], VERDICT_LABEL[row[1]]));
    tr.appendChild(v);
    tr.appendChild(el("td", null, row[2]));
    body.appendChild(tr);
  });
  document.getElementById("caps-lede").textContent =
    counts.live + " layer families can work on this deck with a network. " +
    counts.dead + " cannot work at all, because upstream serves them from a " +
    "Node backend and Orion-X runs no Node at runtime — those routes answer " +
    "HTTP 501 with a named reason rather than a 404 the globe would draw as " +
    "an empty layer. " + counts.nokey + " are disabled for want of an API " +
    "key. No key ships in this image and none can be added on the deck: " +
    "GODSEYE compiles its keys in at build time, and a key baked into a " +
    "distributed ISO is a published key.";
}

function renderHosts() {
  document.getElementById("hosts-lede").textContent =
    "HOSTS.txt is generated from the bytes that ship, not written from " +
    "memory, and the unit suite fails if the two disagree. It names which " +
    "hosts are contacted the moment the globe opens, which are contacted " +
    "per layer, which are anonymous relays, and which are merely strings in " +
    "the bundle that nothing requests.";
  var host = document.getElementById("hosts-actions");
  clear(host);
  var a = el("a", "btn out", "read HOSTS.txt");
  a.href = "HOSTS.txt";
  host.appendChild(a);
  var p = el("a", "btn out", "read PROVENANCE.txt");
  p.href = "PROVENANCE.txt";
  host.appendChild(p);

  if (S.status.outbound.allowed) {
    var open = el("a", "btn go", "Open the globe →");
    open.href = "app/";
    host.appendChild(open);
  } else {
    var dead = el("button", "btn dead", "Open the globe");
    dead.type = "button";
    dead.disabled = true;
    dead.title = S.status.outbound.headline || "refused";
    host.appendChild(dead);
    host.appendChild(el("span", "note",
      "The server refuses this independently: requesting app/ directly " +
      "returns HTTP 503 and the same explanation."));
  }
}

function renderFooter() {
  var f = document.getElementById("footer");
  clear(f);
  f.appendChild(el("p", null,
    "DEC-PHASE12-045 · Orion-X Phoenix Edition. GODSEYE by Vrushank " +
    "Patel (VrushankPatel/godseye), Apache-2.0, vendored as a pre-built " +
    "static bundle — /opt/orionx/osint/godseye/PROVENANCE.txt. CesiumJS " +
    "Apache-2.0. Orion-X adds the preflight, the in-app overlay, the " +
    "server-side posture gate and the host inventory; it changes two lines " +
    "of the upstream page and nothing else."));
}

function render() {
  renderStrip();
  renderVerdict();
  renderCaps();
  renderHosts();
  renderFooter();
}

function boot() {
  loadStatus().then(render);
  // Loop: the operator can raise or lower the posture while this page sits
  // open. Re-ask rather than trusting the answer from a minute ago.
  setInterval(function () {
    if (location.protocol === "file:") return;
    loadStatus().then(render);
  }, 15000);
}

document.addEventListener("DOMContentLoaded", boot);
