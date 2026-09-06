// The interactive demo in the hero: a working Current window, in the page.
// Kept in its own file so a fault here can never stop reveal.js running — when
// both lived in one file, a runtime throw in here left every section below the
// hero stuck at opacity 0, and the page looked empty.
/* ==========================================================================
   BEGIN CURRENT DEMO WIDGET — BEHAVIOUR
   One IIFE, no globals, no external requests.
   ======================================================================== */
(function () {
  "use strict";

  var root = document.getElementById("cd-demo");
  if (!root) return;
  var $ = function (id) { return document.getElementById(id); };

  /* ---- icons (inline SVG, all decorative — labels live on the buttons) --- */
  var P = {
    grid: '<rect x="2" y="2" width="5" height="5" rx="1.3"/><rect x="9" y="2" width="5" height="5" rx="1.3"/><rect x="2" y="9" width="5" height="5" rx="1.3"/><rect x="9" y="9" width="5" height="5" rx="1.3"/>',
    down: '<circle cx="8" cy="8" r="6"/><path d="M8 5v6M5.6 8.6L8 11l2.4-2.4"/>',
    up:   '<circle cx="8" cy="8" r="6"/><path d="M8 11V5M5.6 7.4L8 5l2.4 2.4"/>',
    check:'<circle cx="8" cy="8" r="6"/><path d="M5.3 8.2l1.9 1.9L10.8 6.4"/>',
    warn: '<path d="M8 2.7l6 10.6H2z"/><path d="M8 6.6v3.1"/><circle cx="8" cy="11.6" r=".55" fill="currentColor" stroke="none"/>',
    clean:'<circle cx="8" cy="8" r="6"/><circle cx="8" cy="8" r="2.1" fill="currentColor" stroke="none"/>',
    pause:'<rect x="4.6" y="3.6" width="2.3" height="8.8" rx="1.1" fill="currentColor" stroke="none"/><rect x="9.1" y="3.6" width="2.3" height="8.8" rx="1.1" fill="currentColor" stroke="none"/>',
    play: '<path d="M5.6 3.7l7 4.3-7 4.3z" fill="currentColor" stroke="none"/>',
    folder:'<path d="M2 5.3a1.3 1.3 0 011.3-1.3h2.4l1.4 1.6h5.6A1.3 1.3 0 0114 6.9v5.2a1.3 1.3 0 01-1.3 1.3H3.3A1.3 1.3 0 012 12.1z"/>',
    trash:'<path d="M2.8 4.4h10.4M6.3 4.4V2.9h3.4v1.5M4.3 4.4l.7 8.3h6l.7-8.3"/>',
    search:'<circle cx="7" cy="7" r="4.2"/><path d="M10.2 10.2L14 14"/>',
    plus: '<path d="M8 3.4v9.2M3.4 8h9.2" stroke-width="1.9"/>',
    x:    '<path d="M4 4l8 8M12 4l-8 8"/>',
    sbar: '<rect x="1.6" y="3" width="12.8" height="10" rx="2.2"/><path d="M6.1 3v10"/>',
    ibar: '<rect x="1.6" y="3" width="12.8" height="10" rx="2.2"/><path d="M9.9 3v10"/>',
    swarm:'<circle cx="5.4" cy="6" r="2"/><circle cx="10.9" cy="6.4" r="1.6"/><path d="M2 12.6c0-1.9 1.5-3 3.4-3s3.4 1.1 3.4 3M10 9.9c1.8-.2 3.3.8 3.3 2.7"/>'
  };
  function icon(name, size) {
    var s = size || 16;
    return '<svg class="cd-i" width="' + s + '" height="' + s + '" viewBox="0 0 16 16" fill="none" ' +
      'stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" ' +
      'aria-hidden="true" focusable="false">' + P[name] + "</svg>";
  }

  /* ---- data ------------------------------------------------------------- */
  /* sizeMB is decimal MB; uploadedMB is fixed per torrent so the share ratio
     moves with the download rather than being a made-up constant. */
  var torrents = [
    { id:"debian",  name:"Debian 13 netinst arm64",               sizeMB:4000,  pct:35,  rate:6.5, upRate:1.0, uploadedMB:143,   seeds:63,  swarmSeeds:63,  swarmPeers:129, peers:20, added:"Sep 4, 2026 at 5:57 PM", state:"downloading", paused:false, health:"healthy" },
    { id:"sintel",  name:"Sintel (2010)",                         sizeMB:4000,  pct:25,  rate:4.6, upRate:0.5, uploadedMB:88,    seeds:41,  swarmSeeds:41,  swarmPeers:96,  peers:14, added:"Sep 4, 2026 at 9:12 PM", state:"downloading", paused:false, health:"healthy" },
    { id:"blender", name:"Blender Foundation Open Movies Collection", sizeMB:11000, pct:15, rate:7.9, upRate:0.2, uploadedMB:61, seeds:2,   swarmSeeds:2,   swarmPeers:38,  peers:9,  added:"Sep 3, 2026 at 11:04 AM", state:"downloading", paused:false, health:"rare" },
    { id:"archive", name:"Internet Archive Monthly Snapshot",      sizeMB:18000, pct:11,  rate:8.9, upRate:1.1, uploadedMB:210,   seeds:28,  swarmSeeds:28,  swarmPeers:174, peers:31, added:"Sep 2, 2026 at 8:40 AM", state:"downloading", paused:false, health:"healthy" },
    { id:"ubuntu",  name:"Ubuntu 26.04 LTS Desktop",              sizeMB:700,   pct:100, rate:0,   upRate:0,   uploadedMB:512,   seeds:118, swarmSeeds:118, swarmPeers:240, peers:0,  added:"Aug 29, 2026 at 6:20 PM", state:"done", paused:false, health:"healthy" },
    { id:"bbb",     name:"Big Buck Bunny (2008) 4K Remaster",     sizeMB:4000,  pct:26,  rate:4.8, upRate:0.6, uploadedMB:120,   seeds:55,  swarmSeeds:55,  swarmPeers:118, peers:17, added:"Sep 4, 2026 at 4:05 PM", state:"downloading", paused:false, health:"healthy" },
    { id:"arch",    name:"Arch Linux 2026.09 ISO",                sizeMB:1200,  pct:100, rate:0,   upRate:1.1, uploadedMB:2772,  seeds:87,  swarmSeeds:87,  swarmPeers:143, peers:12, added:"Aug 21, 2026 at 7:33 AM", state:"seeding", paused:false, health:"healthy" },
    { id:"nasa",    name:"NASA Apollo Archive (restored)",        sizeMB:32000, pct:100, rate:0,   upRate:0.4, uploadedMB:40960, seeds:24,  swarmSeeds:24,  swarmPeers:51,  peers:6,  added:"Jul 14, 2026 at 2:15 PM", state:"seeding", paused:false, health:"healthy" }
  ];
  var cleanIds  = { arch:1, nasa:1, ubuntu:1 };   /* Ready to Clean */
  var attentIds = { blender:1 };                  /* Needs Attention — rare swarm */

  var SECTIONS = [
    { id:"all",         label:"All",             icon:"grid",  group:"library" },
    { id:"downloading", label:"Downloading",     icon:"down",  group:"library" },
    { id:"seeding",     label:"Seeding",         icon:"up",    group:"library" },
    { id:"completed",   label:"Completed",       icon:"check", group:"library" },
    { id:"attention",   label:"Needs Attention", icon:"warn",  group:"smart" },
    { id:"clean",       label:"Ready to Clean",  icon:"clean", group:"smart" }
  ];

  var state = {
    section: "all",
    query: "",
    selected: "debian",
    inspector: true,
    magnetOpen: false,
    savePath: "~/Downloads/Current",
    remember: false,
    showFiles: false,
    touched: false,        /* the visitor has interacted at least once */
    autoplayRan: false
  };

  /* ---- formatting (never coloured, always tabular) ---------------------- */
  function fmtSize(mb) {
    if (mb >= 1000) return (mb / 1000).toFixed(1) + " GB";
    return Math.round(mb) + " MB";
  }
  function fmtRate(mbs) { return mbs.toFixed(1) + " MB/s"; }
  function fmtEta(t) {
    if (t.state !== "downloading" || t.paused || t.rate <= 0) return "—";
    var remainMB = t.sizeMB * (1 - t.pct / 100);
    var secs = remainMB / t.rate;
    if (secs < 60) return "under a minute";
    var mins = Math.round(secs / 60);
    if (mins < 60) return mins + " min";
    var h = Math.floor(mins / 60), m = mins % 60;
    return h + " hr" + (m ? " " + m + " min" : "");
  }
  function downloadedMB(t) { return t.sizeMB * t.pct / 100; }
  function ratio(t) {
    var d = downloadedMB(t);
    return d > 0 ? (t.uploadedMB / d).toFixed(2) + "×" : "0.00×";
  }
  function stateKey(t) { return t.paused ? "paused" : t.state; }
  function stateWord(t) {
    if (t.paused) return "Paused";
    if (t.state === "downloading") return "Downloading";
    if (t.state === "seeding") return "Seeding";
    return "Done";
  }
  function stateIcon(t) {
    if (t.state === "downloading") return "down";
    if (t.state === "seeding") return "up";
    return "check";
  }
  function byId(id) {
    for (var i = 0; i < torrents.length; i++) if (torrents[i].id === id) return torrents[i];
    return null;
  }

  /* ---- filtering -------------------------------------------------------- */
  function inSection(t, section) {
    if (section === "all") return true;
    if (section === "downloading") return t.state === "downloading";
    if (section === "seeding") return t.state === "seeding";
    if (section === "completed") return t.pct >= 100;
    if (section === "attention") return !!attentIds[t.id];
    if (section === "clean") return !!cleanIds[t.id];
    return true;
  }
  function sectionCount(section) {
    var n = 0;
    for (var i = 0; i < torrents.length; i++) if (inSection(torrents[i], section)) n++;
    return n;
  }
  function visible() {
    var q = state.query.trim().toLowerCase();
    return torrents.filter(function (t) {
      if (!inSection(t, state.section)) return false;
      if (q && t.name.toLowerCase().indexOf(q) === -1) return false;
      return true;
    });
  }
  function sectionLabel(id) {
    for (var i = 0; i < SECTIONS.length; i++) if (SECTIONS[i].id === id) return SECTIONS[i].label;
    return "All";
  }
  function plural(n, word) { return n + " " + word + (n === 1 ? "" : "s"); }

  /* ---- caption: the demo explaining itself ------------------------------ */
  var capEl = $("cd-caption"), capText = $("cd-caption-text"), capDot = $("cd-caption-dot");
  var HINT = 'This is the real interface, not a picture. <strong>Pick a section</strong>, ' +
             '<strong>click a torrent</strong>, hover a row’s circle to <strong>pause</strong> it, ' +
             'or press <strong>+</strong> to add one. <kbd>Tab</kbd> and <kbd>↑↓</kbd> work too.';
  var capTimer = null;
  /* announce:false writes without disturbing a screen reader — used for the
     autoplay and for per-keystroke search, which would otherwise chatter. */
  function setCaption(html, opts) {
    var announce = !opts || opts.announce !== false;
    if (!announce) capEl.setAttribute("aria-live", "off");
    capText.innerHTML = html;
    capEl.classList.remove("is-flash");
    void capEl.offsetWidth;
    capEl.classList.add("is-flash");
    if (!announce) {
      window.setTimeout(function () { capEl.setAttribute("aria-live", "polite"); }, 400);
    }
    if (capTimer) window.clearTimeout(capTimer);
  }
  function captionHint() { setCaption(HINT, { announce: false }); }

  /* ---- sidebar ---------------------------------------------------------- */
  var sideEls = {};
  function buildSidebar() {
    var lists = { library: $("cd-side-library"), smart: $("cd-side-smart") };
    lists.library.innerHTML = "";
    lists.smart.innerHTML = "";
    SECTIONS.forEach(function (s) {
      var li = document.createElement("li");
      var b = document.createElement("button");
      b.type = "button";
      b.className = "cd-side-row";
      b.setAttribute("data-section", s.id);
      b.innerHTML =
        '<span class="cd-side-icon">' + icon(s.icon, 15) + "</span>" +
        '<span class="cd-side-label"></span>';
      b.querySelector(".cd-side-label").textContent = s.label;
      b.addEventListener("click", function () {
        touch();
        selectSection(s.id, false);
      });
      li.appendChild(b);
      lists[s.group].appendChild(li);
      sideEls[s.id] = b;
    });
    renderSidebar();
  }
  function renderSidebar() {
    SECTIONS.forEach(function (s) {
      var b = sideEls[s.id];
      if (!b) return;
      var on = state.section === s.id;
      if (on) b.setAttribute("aria-current", "true"); else b.removeAttribute("aria-current");
      /* The count lives in the label rather than on screen — the real window
         has no badges, and a per-tick badge is exactly what used to make this
         list renegotiate its layout every second. */
      b.setAttribute("aria-label", s.label + ", " + plural(sectionCount(s.id), "torrent"));
    });
  }

  function selectSection(id, silent) {
    state.section = id;
    $("cd-section-label").textContent = sectionLabel(id);
    renderSidebar();
    renderList();
    if (!silent) {
      var n = visible().length;
      if (state.query) {
        setCaption("Filtered to <strong>" + sectionLabel(id) + "</strong>, still matching “" +
          escapeHtml(state.query) + "” — " + plural(n, "torrent") + ".");
      } else {
        setCaption("Filtered to <strong>" + sectionLabel(id) + "</strong> — " +
          plural(n, "torrent") + ". The title beside the traffic lights follows the sidebar.");
      }
    }
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c];
    });
  }

  /* ---- the library list ------------------------------------------------- */
  var listEl = $("cd-list");
  var rowEls = {};          /* id -> cached refs, so ticking never queries the DOM */

  function renderList(newId) {
    var rows = visible();
    rowEls = {};
    listEl.innerHTML = "";

    if (!rows.length) {
      var e = document.createElement("p");
      e.className = "cd-empty";
      e.textContent = state.query
        ? "Nothing matches “" + state.query + "” in " + sectionLabel(state.section) + "."
        : "Nothing in " + sectionLabel(state.section) + " right now.";
      listEl.appendChild(e);
      return;
    }

    rows.forEach(function (t) {
      var row = document.createElement("div");
      row.className = "cd-row" + (t.id === state.selected ? " is-sel" : "") + (t.id === newId ? " is-new" : "");
      row.setAttribute("role", "listitem");
      row.setAttribute("data-id", t.id);

      var g = document.createElement("button");
      g.type = "button";
      g.className = "cd-glyph";
      g.innerHTML = '<span class="cd-stateglyph">' + icon(stateIcon(t), 15) + "</span>" +
                    '<span class="cd-pauseglyph"></span>';
      g.addEventListener("click", function (ev) { ev.stopPropagation(); touch(); togglePause(t.id); });

      var main = document.createElement("button");
      main.type = "button";
      main.className = "cd-main";
      main.setAttribute("data-id", t.id);
      main.innerHTML =
        '<span class="cd-row-top">' +
          '<span class="cd-name"></span>' +
          '<span class="cd-row-rate cd-num"></span>' +
        "</span>" +
        '<span class="cd-meter"><i class="cd-fill"></i></span>' +
        '<span class="cd-row-sub">' +
          '<span class="cd-sub-l cd-num"></span>' +
          '<span class="cd-sub-r cd-num"></span>' +
        "</span>";
      main.querySelector(".cd-name").textContent = t.name;
      main.addEventListener("click", function () { touch(); selectTorrent(t.id, true); });

      row.appendChild(g);
      row.appendChild(main);
      listEl.appendChild(row);

      rowEls[t.id] = {
        row: row, glyph: g, main: main,
        pauseGlyph: g.querySelector(".cd-pauseglyph"),
        stateGlyph: g.querySelector(".cd-stateglyph"),
        rate: main.querySelector(".cd-row-rate"),
        fill: main.querySelector(".cd-fill"),
        subL: main.querySelector(".cd-sub-l"),
        subR: main.querySelector(".cd-sub-r")
      };
      paintRow(t);
    });
  }

  /* Full paint: colours, glyph, labels. Called on state changes only. */
  function paintRow(t) {
    var r = rowEls[t.id];
    if (!r) return;
    var key = stateKey(t);

    r.glyph.className = "cd-glyph cd-t-" + key + (t.paused ? " is-paused" : "");
    r.stateGlyph.innerHTML = icon(stateIcon(t), 15);
    r.pauseGlyph.innerHTML = icon(t.paused ? "play" : "pause", 14);
    /* Toggle-button semantics: the label states the action and never moves,
       aria-pressed carries the state. The title is the mouse's version. */
    r.glyph.setAttribute("aria-pressed", t.paused ? "true" : "false");
    r.glyph.setAttribute("aria-label", "Pause " + t.name);
    r.glyph.setAttribute("title", (t.paused ? "Resume " : "Pause ") + t.name);

    r.fill.className = "cd-fill cd-f-" + key;
    r.main.setAttribute("aria-current", t.id === state.selected ? "true" : "false");
    paintRowLive(t);
  }

  /* Live paint: only the two things that move — a transform and some text. */
  function paintRowLive(t) {
    var r = rowEls[t.id];
    if (!r) return;
    r.fill.style.transform = "scaleX(" + (Math.max(0, Math.min(100, t.pct)) / 100).toFixed(4) + ")";

    var rateTxt, subL, subR = "", subRHtml = null;
    if (t.paused) {
      rateTxt = "Paused";
    } else if (t.state === "downloading") {
      rateTxt = fmtRate(t.rate);
    } else if (t.state === "seeding") {
      rateTxt = "↑ " + fmtRate(t.upRate);
    } else {
      rateTxt = "—";
    }

    if (t.state === "downloading") {
      subL = Math.round(t.pct) + "% · " + fmtSize(downloadedMB(t)) + " of " + fmtSize(t.sizeMB);
      subR = t.paused ? "" : fmtEta(t) === "—" ? "" : fmtEta(t) + " left";
    } else if (t.state === "seeding") {
      subL = "100% · " + fmtSize(t.sizeMB) + " · " + fmtSize(t.uploadedMB) + " shared";
      subR = t.paused ? "" : "Ratio " + ratio(t);
    } else {
      subL = "100% · " + fmtSize(t.sizeMB) + " of " + fmtSize(t.sizeMB);
      subRHtml = '<span class="cd-donepill">Done</span>';
    }

    if (r.rate.textContent !== rateTxt) r.rate.textContent = rateTxt;
    if (r.subL.textContent !== subL) r.subL.textContent = subL;
    if (subRHtml !== null) {
      if (r.subR.getAttribute("data-pill") !== "1") { r.subR.innerHTML = subRHtml; r.subR.setAttribute("data-pill", "1"); }
    } else {
      if (r.subR.getAttribute("data-pill") === "1") { r.subR.removeAttribute("data-pill"); r.subR.textContent = ""; }
      if (r.subR.textContent !== subR) r.subR.textContent = subR;
    }
  }

  function selectTorrent(id, announce) {
    if (state.selected === id) { renderInspector(); return; }
    var prev = rowEls[state.selected];
    if (prev) { prev.row.classList.remove("is-sel"); prev.main.setAttribute("aria-current", "false"); }
    state.selected = id;
    var now = rowEls[id];
    if (now) { now.row.classList.add("is-sel"); now.main.setAttribute("aria-current", "true"); }
    renderInspector();
    if (announce) {
      var t = byId(id);
      setCaption("Selected <strong>" + escapeHtml(t.name) + "</strong> — the inspector on the right " +
        "always describes the selected torrent.");
    }
  }

  function togglePause(id) {
    var t = byId(id);
    if (!t) return;
    t.paused = !t.paused;
    paintRow(t);
    if (state.selected === id) renderInspector();
    if (t.paused) {
      setCaption("Paused <strong>" + escapeHtml(t.name) + "</strong> — its meter goes grey and the rate " +
        "reads Paused. The same circle resumes it.");
    } else {
      setCaption("Resumed <strong>" + escapeHtml(t.name) + "</strong> — it picks up where it left off.");
    }
  }

  /* keyboard: up/down moves the selection through the visible rows */
  listEl.addEventListener("keydown", function (ev) {
    if (ev.key !== "ArrowDown" && ev.key !== "ArrowUp") return;
    var rows = visible();
    if (!rows.length) return;
    var i = -1;
    for (var k = 0; k < rows.length; k++) if (rows[k].id === state.selected) i = k;
    var next = ev.key === "ArrowDown" ? Math.min(rows.length - 1, i + 1) : Math.max(0, i < 0 ? 0 : i - 1);
    if (i < 0) next = 0;
    ev.preventDefault();
    touch();
    selectTorrent(rows[next].id, false);
    var r = rowEls[rows[next].id];
    if (r) { r.main.focus(); }
    setCaption("Selected <strong>" + escapeHtml(rows[next].name) + "</strong> with the arrow keys.",
      { announce: false });
  });

  /* ---- inspector -------------------------------------------------------- */
  var inspEl = $("cd-insp");
  var inspLive = null;   /* cached refs for the numbers that tick */

  function statRow(k, v, cls) {
    return '<div class="cd-stat"><span class="cd-stat-k">' + k + '</span>' +
      '<i class="cd-lead"></i><span class="cd-stat-v cd-num' + (cls ? " " + cls : "") + '">' + v + "</span></div>";
  }

  function renderInspector() {
    var t = byId(state.selected);
    inspLive = null;
    if (!t) { inspEl.innerHTML = ""; return; }
    var key = stateKey(t);
    var rare = t.health === "rare";

    inspEl.innerHTML =
      '<h2 class="cd-insp-name" id="cd-insp-name"></h2>' +
      '<div class="cd-insp-actions">' +
        '<span class="cd-pill cd-pill-' + key + '">' + icon(t.paused ? "pause" : stateIcon(t), 13) +
          "<span>" + stateWord(t) + "</span></span>" +
        '<span class="cd-insp-btns">' +
          '<button type="button" class="cd-insp-btn" id="cd-insp-pause" aria-pressed="' + (t.paused ? "true" : "false") +
            '" title="' + (t.paused ? "Resume" : "Pause") + '">' +
            icon(t.paused ? "play" : "pause", 14) + '<span class="cd-sr">Pause</span></button>' +
          '<button type="button" class="cd-insp-btn" id="cd-insp-reveal">' + icon("folder", 14) +
            '<span class="cd-sr">Reveal in Finder</span></button>' +
          '<button type="button" class="cd-insp-btn cd-danger" id="cd-insp-remove">' + icon("trash", 14) +
            '<span class="cd-sr">Remove torrent</span></button>' +
        "</span>" +
      "</div>" +

      '<div class="cd-card">' +
        '<div class="cd-pct-line">' +
          '<span class="cd-pct cd-num" id="cd-insp-pct">' + Math.round(t.pct) + "%</span>" +
          '<span class="cd-pct-of cd-num" id="cd-insp-of">' + fmtSize(downloadedMB(t)) + " of " + fmtSize(t.sizeMB) + "</span>" +
        "</div>" +
        '<div class="cd-insp-meter"><i class="cd-fill cd-f-' + key + '" id="cd-insp-fill" ' +
          'style="transform:scaleX(' + (t.pct / 100).toFixed(4) + ')"></i></div>' +
      "</div>" +

      '<div>' +
        '<div class="cd-group-head">TRANSFER</div>' +
        '<div class="cd-card">' +
          statRow("Speed", t.paused || t.state !== "downloading" ? "—" : fmtRate(t.rate), "cd-v-speed") +
          statRow("Uploading at", t.paused ? "—" : t.upRate > 0 ? fmtRate(t.upRate) : "—") +
          statRow("Time remaining", t.paused ? "Paused" : fmtEta(t), "cd-v-eta") +
          statRow("Downloaded", fmtSize(downloadedMB(t)), "cd-v-down") +
          statRow("Uploaded", fmtSize(t.uploadedMB)) +
          statRow("Share ratio", ratio(t), "cd-v-ratio") +
          statRow("Peers connected", t.paused ? "0" : String(t.peers)) +
          statRow("Seeds in swarm", String(t.swarmSeeds)) +
          statRow("Peers in swarm", String(t.swarmPeers)) +
          statRow("Added", t.added) +
        "</div>" +
      "</div>" +

      '<div class="cd-health cd-health-' + (rare ? "rare" : "healthy") + '">' +
        '<span class="cd-health-icon">' + icon("swarm", 16) + "</span>" +
        "<span>" +
          '<span class="cd-health-title">' + (rare ? "Rare · " + t.swarmSeeds + " seeds" : "Healthy · " + t.swarmSeeds + " seeds") + "</span>" +
          '<span class="cd-health-body">' + (rare
            ? "Few complete sources. Staying available keeps this torrent alive, so it is excluded from automatic cleanup."
            : "Plenty of complete sources exist. This torrent doesn’t need you to stay available.") + "</span>" +
        "</span>" +
      "</div>";

    inspEl.querySelector("#cd-insp-name").textContent = t.name;

    $("cd-insp-pause").addEventListener("click", function () { touch(); togglePause(t.id); });
    $("cd-insp-reveal").addEventListener("click", function () {
      touch();
      setCaption("Reveal would open <strong>" + escapeHtml(state.savePath) + "</strong> in Finder. " +
        "In the demo it stops here.");
    });
    $("cd-insp-remove").addEventListener("click", function () {
      touch();
      setCaption("Remove asks first in the real app, and cleanup only ever moves files to the Trash — " +
        "nothing here deletes anything.");
    });

    inspLive = {
      pct: $("cd-insp-pct"), of: $("cd-insp-of"), fill: $("cd-insp-fill"),
      speed: inspEl.querySelector(".cd-v-speed"),
      eta: inspEl.querySelector(".cd-v-eta"),
      down: inspEl.querySelector(".cd-v-down"),
      ratio: inspEl.querySelector(".cd-v-ratio"),
      id: t.id
    };
  }

  function paintInspectorLive() {
    if (!inspLive) return;
    var t = byId(inspLive.id);
    if (!t) return;
    var pct = Math.round(t.pct) + "%";
    if (inspLive.pct.textContent !== pct) inspLive.pct.textContent = pct;
    var of = fmtSize(downloadedMB(t)) + " of " + fmtSize(t.sizeMB);
    if (inspLive.of.textContent !== of) inspLive.of.textContent = of;
    inspLive.fill.style.transform = "scaleX(" + (t.pct / 100).toFixed(4) + ")";
    if (inspLive.eta) {
      var eta = t.paused ? "Paused" : fmtEta(t);
      if (inspLive.eta.textContent !== eta) inspLive.eta.textContent = eta;
    }
    if (inspLive.down) {
      var d = fmtSize(downloadedMB(t));
      if (inspLive.down.textContent !== d) inspLive.down.textContent = d;
    }
    if (inspLive.ratio) {
      var r = ratio(t);
      if (inspLive.ratio.textContent !== r) inspLive.ratio.textContent = r;
    }
  }

  /* ---- chrome bar controls ---------------------------------------------- */
  $("cd-sidebar-glyph").innerHTML = icon("sbar", 15);
  $("cd-search-icon").innerHTML = icon("search", 13);
  $("cd-search-clear").insertAdjacentHTML("afterbegin", icon("x", 11));
  $("cd-add").insertAdjacentHTML("afterbegin", icon("plus", 15));
  $("cd-insp-toggle").insertAdjacentHTML("afterbegin", icon("ibar", 15));

  var searchInput = $("cd-search");
  var searchWrap = $("cd-search-wrap");
  searchInput.addEventListener("input", function () {
    touch();
    state.query = searchInput.value;
    searchWrap.classList.toggle("is-filled", state.query.length > 0);
    renderList();
    var n = visible().length;
    if (state.query.trim()) {
      setCaption("Searching “" + escapeHtml(state.query) + "” — " +
        plural(n, "match") + " in " + sectionLabel(state.section) + ".", { announce: false });
    } else {
      setCaption("Search cleared — " + plural(n, "torrent") + " in " +
        sectionLabel(state.section) + ".", { announce: false });
    }
  });
  $("cd-search-clear").addEventListener("click", function () {
    touch();
    searchInput.value = "";
    state.query = "";
    searchWrap.classList.remove("is-filled");
    renderList();
    setCaption("Search cleared — " + plural(visible().length, "torrent") + " in " +
      sectionLabel(state.section) + ".");
    searchInput.focus();
  });

  $("cd-palette").addEventListener("click", function () {
    touch();
    searchInput.focus();
    searchInput.select();
    setCaption("The palette jumps straight to search — start typing a torrent’s name to find it.");
  });

  $("cd-insp-toggle").addEventListener("click", function () {
    touch();
    state.inspector = !state.inspector;
    var b = $("cd-insp-toggle");
    $("cd-win").classList.toggle("cd-no-insp", !state.inspector);
    b.classList.toggle("is-on", state.inspector);
    b.setAttribute("aria-pressed", state.inspector ? "true" : "false");
    b.setAttribute("title", state.inspector ? "Hide inspector" : "Show inspector");
    b.querySelector(".cd-sr").textContent = state.inspector ? "Hide inspector" : "Show inspector";
    setCaption(state.inspector
      ? "Inspector shown — it follows whichever torrent is selected."
      : "Inspector hidden — the list takes the width back.");
  });

  /* ---- the magnet card --------------------------------------------------- */
  var mount = $("cd-magnet-mount");
  var PATHS = ["~/Downloads/Current", "~/Movies/Current", "/Volumes/Media/Torrents"];
  var pathIdx = 0;
  var lastFocus = null;

  function openMagnet() {
    if (state.magnetOpen) return;
    state.magnetOpen = true;
    lastFocus = document.activeElement;

    var scrim = document.createElement("div");
    scrim.className = "cd-scrim";
    scrim.id = "cd-scrim";
    scrim.innerHTML =
      '<div class="cd-magnet" role="dialog" aria-modal="true" aria-labelledby="cd-magnet-title" id="cd-magnet">' +
        '<div class="cd-magnet-top">' +
          "<div>" +
            '<div class="cd-magnet-title" id="cd-magnet-title">Cosmos Laundromat (2015) 4K</div>' +
            '<div class="cd-magnet-meta cd-num">1 file · 2.4 GB</div>' +
          "</div>" +
          '<button type="button" class="cd-magnet-close" id="cd-magnet-x">' + icon("x", 13) +
            '<span class="cd-sr">Close</span></button>' +
        "</div>" +
        '<div class="cd-magnet-head">SAVE TO</div>' +
        '<div class="cd-path-row">' +
          '<span style="color:var(--cd-secondary)">' + icon("folder", 15) + "</span>" +
          '<span class="cd-path" id="cd-magnet-path"></span>' +
          '<button type="button" class="cd-btn" id="cd-magnet-change">Change…</button>' +
        "</div>" +
        '<button type="button" class="cd-check" id="cd-magnet-remember" role="checkbox" aria-checked="' +
          (state.remember ? "true" : "false") + '">' +
          '<span class="cd-check-box">' + icon("check", 11) + "</span>" +
          '<span class="cd-check-label">Remember this location</span>' +
        "</button>" +
        '<div class="cd-files" id="cd-magnet-files" hidden>' +
          '<div class="cd-file"><span style="color:var(--cd-secondary)">' + icon("check", 13) + "</span>" +
            '<span class="cd-file-name">Cosmos_Laundromat_2015_4K.mkv</span>' +
            '<span class="cd-num">2.4 GB</span></div>' +
        "</div>" +
        '<div class="cd-magnet-foot">' +
          '<button type="button" class="cd-btn" id="cd-magnet-files-btn">Choose files…</button>' +
          '<button type="button" class="cd-btn cd-btn-primary" id="cd-magnet-go">Download 2.4 GB</button>' +
        "</div>" +
      "</div>";
    mount.appendChild(scrim);

    $("cd-magnet-path").textContent = state.savePath;

    scrim.addEventListener("mousedown", function (ev) {
      if (ev.target === scrim) closeMagnet("Magnet card dismissed. The + button brings it back.");
    });
    $("cd-magnet-x").addEventListener("click", function () {
      closeMagnet("Magnet card dismissed. The + button brings it back.");
    });
    $("cd-magnet-change").addEventListener("click", function () {
      pathIdx = (pathIdx + 1) % PATHS.length;
      state.savePath = PATHS[pathIdx];
      $("cd-magnet-path").textContent = state.savePath;
      setCaption("Save location set to <strong>" + escapeHtml(state.savePath) + "</strong>. " +
        "Current asks where a download goes <em>after</em> the magnet resolves, when it finally knows its size.");
    });
    $("cd-magnet-remember").addEventListener("click", function () {
      state.remember = !state.remember;
      this.setAttribute("aria-checked", state.remember ? "true" : "false");
      setCaption(state.remember
        ? "Remembering this location — that also stops Current asking next time."
        : "Current will keep asking where each download goes.");
    });
    $("cd-magnet-files-btn").addEventListener("click", function () {
      state.showFiles = !state.showFiles;
      $("cd-magnet-files").hidden = !state.showFiles;
      setCaption(state.showFiles
        ? "One file in this torrent — you’d untick anything you didn’t want."
        : "File list hidden.");
    });
    $("cd-magnet-go").addEventListener("click", addCosmos);

    scrim.addEventListener("keydown", function (ev) {
      if (ev.key !== "Tab") return;
      var f = scrim.querySelectorAll("button, input");
      if (!f.length) return;
      var first = f[0], last = f[f.length - 1];
      if (ev.shiftKey && document.activeElement === first) { ev.preventDefault(); last.focus(); }
      else if (!ev.shiftKey && document.activeElement === last) { ev.preventDefault(); first.focus(); }
    });

    $("cd-magnet-go").focus();
    setCaption("The magnet card asks the one question a magnet link can’t answer: " +
      "<strong>where does this go?</strong> Change the folder, then press Download — or <kbd>Esc</kbd> to dismiss.");
  }

  function closeMagnet(msg) {
    if (!state.magnetOpen) return;
    state.magnetOpen = false;
    var s = $("cd-scrim");
    if (s) s.parentNode.removeChild(s);
    /* Focus goes back where it came from — or to the + button, which is where
       it came from whenever the card was opened any way but by clicking it. */
    if (lastFocus && lastFocus.focus && lastFocus !== document.body && root.contains(lastFocus)) lastFocus.focus();
    else $("cd-add").focus();
    if (msg) setCaption(msg);
  }

  var cosmosCount = 0;
  function addCosmos() {
    var id = "cosmos" + (cosmosCount++ ? cosmosCount : "");
    var t = {
      id: id, name: "Cosmos Laundromat (2015) 4K", sizeMB: 2400, pct: 0,
      rate: 5.2, upRate: 0.1, uploadedMB: 4, seeds: 34, swarmSeeds: 34, swarmPeers: 77,
      peers: 11, added: "Just now", state: "downloading", paused: false, health: "healthy"
    };
    torrents.unshift(t);
    closeMagnet(null);
    state.query = "";
    searchInput.value = "";
    searchWrap.classList.remove("is-filled");
    state.selected = id;
    selectSection("all", true);
    renderList(id);
    renderInspector();
    renderSidebar();
    updateStorage();
    setCaption("Added <strong>Cosmos Laundromat (2015) 4K</strong> to " +
      escapeHtml(state.savePath) + " — it’s at the top of the list and already moving.");
  }

  $("cd-add").addEventListener("click", function () { touch(); openMagnet(); });

  /* Escape is handled on the widget, never on the host document. */
  root.addEventListener("keydown", function (ev) {
    if (ev.key === "Escape" && state.magnetOpen) {
      ev.preventDefault();
      touch();
      closeMagnet("Magnet card dismissed with Escape.");
    }
  });

  /* ---- storage + chrome rates ------------------------------------------- */
  /* The readout starts at the app's own 7.6 GB and moves by what the demo
     actually downloads, rather than by the whole (fictional) library size. */
  var STORAGE_START = 7.6, STORAGE_TOTAL = 93.1, storageBase = null;
  function updateStorage() {
    var usedMB = 0;
    for (var i = 0; i < torrents.length; i++) usedMB += downloadedMB(torrents[i]);
    if (storageBase === null) storageBase = usedMB / 1000;
    var usedGB = STORAGE_START + (usedMB / 1000 - storageBase);
    $("cd-storage-used").textContent = usedGB.toFixed(1) + " GB";
    $("cd-storage-fill").style.width = Math.min(100, (usedGB / STORAGE_TOTAL) * 100).toFixed(2) + "%";
  }
  function updateRates() {
    var d = 0, u = 0;
    for (var i = 0; i < torrents.length; i++) {
      var t = torrents[i];
      if (t.paused) continue;
      if (t.state === "downloading") { d += t.rate; u += t.upRate; }
      else if (t.state === "seeding") { u += t.upRate; }
    }
    var dn = d.toFixed(1) + " MB/s", up = u.toFixed(1) + " MB/s";
    if ($("cd-rate-down").textContent !== dn) $("cd-rate-down").textContent = dn;
    if ($("cd-rate-up").textContent !== up) $("cd-rate-up").textContent = up;
  }

  /* ---- the tick: text and one transform, nothing that resizes anything --- */
  var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)");
  var timer = null, onScreen = true;

  function tick() {
    var structural = false;
    for (var i = 0; i < torrents.length; i++) {
      var t = torrents[i];
      if (t.state !== "downloading" || t.paused || t.pct >= 100) continue;
      /* Derived from the real rate, then floored so a very large torrent still
         visibly moves. Roughly a percent every three to ten seconds. */
      var perSec = Math.max(0.09, (t.rate / t.sizeMB) * 100 * 1.8);
      t.pct = Math.min(100, t.pct + perSec);
      t.uploadedMB += t.upRate * 0.6;
      if (t.pct >= 100) {
        t.pct = 100;
        t.state = "seeding";
        t.upRate = Math.max(0.3, t.upRate);
        cleanIds[t.id] = 1;
        structural = true;
        if (rowEls[t.id]) paintRow(t);
        if (state.selected === t.id) renderInspector();
      } else {
        paintRowLive(t);
      }
    }
    paintInspectorLive();
    updateStorage();
    updateRates();
    if (structural) { renderSidebar(); if (state.section !== "all") renderList(); }
  }

  function startTicking() {
    if (timer || (reduceMotion && reduceMotion.matches)) return;
    timer = window.setInterval(tick, 1000);
  }
  function stopTicking() {
    if (timer) { window.clearInterval(timer); timer = null; }
  }

  if ("IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (entries) {
      onScreen = entries[0].isIntersecting;
      if (onScreen && document.visibilityState !== "hidden") { startTicking(); maybeAutoplay(); }
      else { stopTicking(); cancelAutoplay(); }
    }, { threshold: 0.12 });
    io.observe(root);
  } else {
    startTicking();
    window.setTimeout(function () { maybeAutoplay(); }, 0);
  }
  document.addEventListener("visibilitychange", function () {
    if (document.visibilityState === "hidden") { stopTicking(); cancelAutoplay(); }
    else if (onScreen) { startTicking(); maybeAutoplay(); }
  });

  /* ---- discovery: pulse, then one gentle autoplay ------------------------ */
  var ghost = $("cd-ghost");
  var apTimers = [];
  var idleTimer = null;

  function touch() {
    if (!state.touched) {
      state.touched = true;
      $("cd-add").classList.remove("cd-hint");
    }
    cancelAutoplay();
    if (idleTimer) { window.clearTimeout(idleTimer); idleTimer = null; }
  }
  /* Any real input counts, including one the demo didn't wire up. */
  ["pointerdown", "keydown", "wheel", "touchstart"].forEach(function (evt) {
    root.addEventListener(evt, function () { touch(); }, { passive: true });
  });

  function cancelAutoplay() {
    apTimers.forEach(window.clearTimeout);
    apTimers = [];
    ghost.classList.remove("is-on", "is-tap");
  }
  function later(fn, ms) { apTimers.push(window.setTimeout(fn, ms)); }

  function ghostTo(el) {
    if (!el) return;
    var a = el.getBoundingClientRect();
    var b = $("cd-win").getBoundingClientRect();
    var x = a.left - b.left + a.width / 2;
    var y = a.top - b.top + a.height / 2;
    ghost.style.transform = "translate(" + Math.round(x) + "px," + Math.round(y) + "px)";
  }
  function ghostTap() {
    ghost.classList.remove("is-tap");
    void ghost.offsetWidth;
    ghost.classList.add("is-tap");
  }

  function maybeAutoplay() {
    if (state.touched || state.autoplayRan) return;
    if (reduceMotion && reduceMotion.matches) return;
    if (idleTimer) return;
    idleTimer = window.setTimeout(runAutoplay, 6500);
  }

  /* One demonstration, once. It shows filtering — the cheapest idea to grasp —
     and puts everything back exactly as it found it. */
  function runAutoplay() {
    idleTimer = null;
    if (state.touched || state.autoplayRan) return;
    if (!onScreen || document.visibilityState === "hidden") return;
    if (reduceMotion && reduceMotion.matches) return;
    state.autoplayRan = true;

    var seedBtn = sideEls.seeding, allBtn = sideEls.all;
    if (!seedBtn || !allBtn) return;

    ghostTo(allBtn);
    later(function () { ghost.classList.add("is-on"); ghostTo(seedBtn); }, 60);
    later(function () {
      ghostTap();
      selectSection("seeding", true);
      setCaption("Like this — <strong>Seeding</strong> shows the " +
        plural(sectionCount("seeding"), "torrent") + " that finished and are still sharing.",
        { announce: false });
    }, 420);
    later(function () { ghostTo(allBtn); }, 2600);
    later(function () {
      ghostTap();
      selectSection("all", true);
      setCaption("…and back to <strong>All</strong>. That’s the whole trick — " +
        "everything here is clickable. Your turn.", { announce: false });
    }, 2960);
    later(function () { ghost.classList.remove("is-on"); }, 3700);
    later(function () { if (!state.touched) captionHint(); }, 8000);
  }

  /* ---- boot ------------------------------------------------------------- */
  buildSidebar();
  renderList();
  renderInspector();
  updateStorage();
  updateRates();
  captionHint();

  if (reduceMotion && reduceMotion.matches) {
    $("cd-add").classList.remove("cd-hint");
  }
  if (reduceMotion && reduceMotion.addEventListener) {
    reduceMotion.addEventListener("change", function () {
      if (reduceMotion.matches) { stopTicking(); cancelAutoplay(); $("cd-add").classList.remove("cd-hint"); }
      else if (onScreen) startTicking();
    });
  }
  /* Stop the pulse eventually even if nobody ever clicks — a hint, not a nag. */
  window.setTimeout(function () { $("cd-add").classList.remove("cd-hint"); }, 30000);
})();
/* ==========================================================================
   END CURRENT DEMO WIDGET — BEHAVIOUR
   ======================================================================== */
