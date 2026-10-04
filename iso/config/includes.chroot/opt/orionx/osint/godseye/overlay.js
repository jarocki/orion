/* Orion-X — GODSEYE in-app honesty overlay.
 * @decision DEC-PHASE12-045
 *
 * This is the one Orion-X file that runs inside the vendored upstream page
 * (app/index.html loads it; that line and the removal of the Google Fonts
 * link are the only two edits to the vendored bundle — see PROVENANCE.txt).
 *
 * It exists for the Loop stage. The preflight gate and the server gate both
 * answer "may this be served" at the moment of the request. Neither can
 * answer "is it still true". An operator can raise the threat posture, or
 * pull the cable, while the globe is open — and a Cesium scene keeps
 * displaying the last successful fetch indefinitely. Dots that stopped
 * updating forty minutes ago look exactly like dots that are current.
 *
 * So: poll the single authority, and when the deck may no longer reach out,
 * cover the globe. Not dim it, not warn beside it — cover it, because the
 * picture underneath has become a claim the deck can no longer support.
 *
 * Fails closed: if /api/status.json cannot be read, the curtain drops.
 */
(function () {
  "use strict";

  var POLL_MS = 15000;
  var CURTAIN_ID = "orionx-godseye-curtain";
  var STRIP_ID = "orionx-godseye-strip";

  /* Layers that cannot work on this deck no matter what the network does.
   * Stated once, on first paint, so nobody waits for aircraft that are
   * never coming. Kept in step with osint_server.GODSEYE_BACKEND_ROUTES by
   * tests/unit/test_godseye.sh. */
  var DEAD = [
    "aircraft via the OpenSky proxy",
    "the CCTV source index and frame grabs",
    "the radio station list",
    "traffic flow and status",
    "Overpass / OpenStreetMap queries"
  ];

  function css(node, text) { node.setAttribute("style", text); }

  function makeStrip() {
    var bar = document.createElement("div");
    bar.id = STRIP_ID;
    css(bar,
      "position:fixed;left:0;right:0;bottom:0;z-index:2147483000;" +
      "background:rgba(11,13,17,.94);border-top:2px solid #ffb300;" +
      "color:#e6e8ec;font:12px/1.5 ui-monospace,monospace;padding:9px 14px;" +
      "display:flex;gap:12px;align-items:flex-start;justify-content:space-between");
    var text = document.createElement("div");
    text.textContent =
      "ORION-X: this build has no Node backend, so " + DEAD.join(", ") +
      " do not work — those routes answer HTTP 501, not an empty layer. " +
      "No API key ships, so the key-gated layers are off. Every host this " +
      "page can contact is listed in /opt/orionx/osint/godseye/HOSTS.txt.";
    var close = document.createElement("button");
    close.type = "button";
    close.textContent = "dismiss";
    css(close,
      "flex:none;background:#171a21;color:#9aa0a6;border:1px solid #303848;" +
      "border-radius:5px;padding:4px 10px;font:11px ui-monospace,monospace;cursor:pointer");
    close.addEventListener("click", function () { bar.remove(); });
    bar.appendChild(text);
    bar.appendChild(close);
    return bar;
  }

  function curtain(headline, detail, remedy) {
    var existing = document.getElementById(CURTAIN_ID);
    if (existing) return existing;
    var box = document.createElement("div");
    box.id = CURTAIN_ID;
    css(box,
      "position:fixed;inset:0;z-index:2147483600;background:#0b0d11;" +
      "color:#e6e8ec;font:15px/1.55 system-ui,sans-serif;overflow:auto;" +
      "padding:56px 20px");
    var inner = document.createElement("div");
    css(inner, "max-width:720px;margin:0 auto");

    var h = document.createElement("h1");
    h.textContent = headline;
    css(h, "margin:0 0 6px;font-size:1.2rem;color:#ff5f56;letter-spacing:.03em");
    inner.appendChild(h);

    var tag = document.createElement("p");
    tag.textContent = "GODSEYE · covered by Orion-X · the globe behind this is stale";
    css(tag, "margin:0 0 20px;font:11px ui-monospace,monospace;color:#6b7280;" +
             "letter-spacing:.14em;text-transform:uppercase");
    inner.appendChild(tag);

    [["What is not working", detail],
     ["Why it is covered",
      "Cesium keeps drawing the last successful response for as long as the " +
      "page is open. Those aircraft and events are not current and there is " +
      "nothing on the canvas that would tell you so. A stale picture that " +
      "looks live is worse than no picture."],
     ["What still works",
      "The local investigation surface: CyberChef, the artifact and PCAP " +
      "tools, and the R.A.I.N. attack map of what this deck has itself seen."]
    ].forEach(function (pair) {
      var dt = document.createElement("h2");
      dt.textContent = pair[0];
      css(dt, "margin:18px 0 3px;font-size:.72rem;letter-spacing:.18em;" +
              "text-transform:uppercase;color:#ff6a13");
      var dd = document.createElement("p");
      dd.textContent = pair[1];
      css(dd, "margin:0;color:#9aa0a6;font-size:.9rem");
      inner.appendChild(dt);
      inner.appendChild(dd);
    });

    if (remedy) {
      var r = document.createElement("code");
      r.textContent = remedy;
      css(r, "display:block;margin-top:16px;background:#0a0c10;border:1px solid #242a35;" +
             "border-radius:6px;padding:10px 12px;color:#ffb15c;" +
             "font:13px ui-monospace,monospace;white-space:pre-wrap");
      inner.appendChild(r);
    }

    var back = document.createElement("p");
    css(back, "margin-top:26px");
    var a = document.createElement("a");
    a.href = "/godseye/";
    a.textContent = "← back to the GODSEYE preflight";
    css(a, "color:#7ab8ff");
    back.appendChild(a);
    inner.appendChild(back);

    box.appendChild(inner);
    document.body.appendChild(box);
    return box;
  }

  function lift() {
    var existing = document.getElementById(CURTAIN_ID);
    if (existing) existing.remove();
  }

  function poll() {
    fetch("/api/status.json", { cache: "no-store" })
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (status) {
        var ob = (status && status.outbound) || {};
        if (ob.allowed) { lift(); return; }
        curtain(ob.headline || "This deck may no longer reach out",
                ob.detail || "The deck's posture or route changed while " +
                             "GODSEYE was open.",
                ob.remedy || "");
      })
      .catch(function (err) {
        // Fail closed. Not knowing is not permission.
        curtain("Deck status unreadable — GODSEYE covered",
                "The local status endpoint stopped answering (" +
                err.message + "). This page cannot tell whether the deck is " +
                "still allowed to reach out, so it assumes not.",
                "orionx-osint --check");
      });
  }

  function start() {
    document.body.appendChild(makeStrip());
    poll();
    setInterval(poll, POLL_MS);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
