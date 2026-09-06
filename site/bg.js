/* The piece field behind the first screen.
 *
 * A torrent arrives as thousands of fixed-size pieces, out of order, from
 * strangers. That is the one picture this whole page is about, and it is what
 * the background draws: a field of small squares that fill in, flare once as
 * they land, settle, and eventually go again. Left running it never finishes
 * and never sits still — which is the headline, more or less.
 *
 * It replaced two blurred blobs and a grid, because those are what every dark
 * landing page has and they said nothing about this one.
 *
 * Rules it plays by:
 *
 * - It is never allowed near the words. The weight of every cell is computed
 *   once from where it sits, and cells under the headline weigh nothing, so
 *   the field has a hole in it rather than a mask laid over it. Doing it in
 *   the canvas rather than in CSS also dodges mask-composite, which is where
 *   this sort of thing usually breaks in one browser.
 * - It stops dead when scrolled out of view. A background that keeps painting
 *   while nobody is looking is just a battery drain.
 * - Only living cells are drawn. An empty cell paints nothing at all, so the
 *   cost tracks what is lit, not the size of the grid.
 * - Reduced motion gets one still frame of a half-filled field: same picture,
 *   no movement.
 *
 * Its own file on purpose — the page's scripts each run alone, so a fault in
 * a decoration cannot take the demo or the scroll reveals with it.
 */
(function () {
  var canvas = document.getElementById('bg-field');
  if (!canvas || !canvas.getContext) return;

  var ctx = canvas.getContext('2d', { alpha: true });
  if (!ctx) return;

  var reduceMotion = window.matchMedia
    && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // --- the look ------------------------------------------------------------
  var PITCH   = 17;    // cell to cell, including the gap
  var SQUARE  = 13;    // the drawn square, so a 4px gutter — the app's own
  var CORNER  = 2;

  var HELD_ALPHA  = 0.115;  // a piece at rest
  var FLARE_ALPHA = 0.60;   // the moment it lands
  var FILL_TARGET = 0.25;   // how much of the field is held at once

  var ARRIVE  = 350;    // ms to fade in
  var FLARE   = 2000;   // ms for the accent to decay out of it
  var RELEASE = 2400;   // ms to fade out again
  var DRIZZLE   = 2.5;  // pieces a second, always
  var BURST_SIZE= 26;   // and a run of them arriving together
  var BURST_RATE= 46;   // pieces a second inside a burst
  var BURST_GAP = 1100; // ms of quiet after one, plus up to as much again
  var BURST_SPAN= 5;    // cells — how tight a burst lands

  // The fade-in has to be much shorter than the flare, or a piece spends the
  // brightest part of its life still fading up and the landing never reads.
  // That was one of two things wrong with the first version of this: the
  // flare was there in the numbers and invisible on the screen.
  //
  // The other was that pieces landed at an even rate, everywhere, forever.
  // Ten lit squares scattered through eight hundred is a drizzle, and a
  // drizzle reads as a still picture no matter how much of it there is.
  // Torrents don't behave that way — a peer connects, a run of pieces lands
  // together, then it's quiet. So most of them now arrive in bursts, which
  // gives the thing what it was missing: somewhere to look.

  var CURSOR_REACH = 150;   // px — pieces near the pointer brighten

  // Three pools of warmth drifting through the field on long, unequal loops,
  // and a slow breath under everything.
  //
  // Without these the only thing moving was the landings themselves, and a
  // piece that lands and then sits at a fixed brightness forever leaves a
  // field that is technically animated and visually still. Now the bright
  // part of the field slides around and the whole thing rises and falls, so
  // there is something happening between bursts as well as during them.
  // The periods are deliberately not multiples of each other — three pools on
  // round numbers resynchronise every so often and the field visibly pulses as
  // one, which is the opposite of the intent.
  var POOLS = [
    { x: 0.70, y: 0.32, ax: 0.30, ay: 0.24, sx: 59000,  sy: 43000, r: 380 },
    { x: 0.88, y: 0.60, ax: 0.24, ay: 0.30, sx: 79000,  sy: 67000, r: 300 },
    { x: 0.56, y: 0.72, ax: 0.32, ay: 0.19, sx: 101000, sy: 87000, r: 430 }
  ];
  var POOL_LIFT = 1.9;    // how much brighter a piece sitting in one is
  var BREATH    = 0.30;   // how far the whole field rises and falls
  var BREATH_MS = 9500;   // and how long one breath takes

  // --- state ---------------------------------------------------------------
  var cols = 0, rows = 0, count = 0, room = 0, cap = 0, cssW = 0, cssH = 0;
  var weight, phase, stamp;   // 0 empty, 1 arriving/held, 2 releasing
  var live = [];              // indices currently drawing anything
  var held = [];              // indices in phase 1, oldest first
  var cursorX = -1e4, cursorY = -1e4, cursorSeen = 0;
  var running = false, last = 0, owed = 0, raf = 0;
  var burstLeft = 0, burstOwed = 0, burstX = 0, burstY = 0, burstNext = 0;

  var TAU = Math.PI * 2;

  function rand(n) { return (Math.random() * n) | 0; }

  /* How much of the field is allowed to exist at a given point.
     Nothing where the words are, quiet at the very top, gone before the
     bottom edge, densest about three quarters across.

     The hole is measured from the headline block itself rather than guessed
     as a fraction of the viewport. Guessing works at one window size and
     fails at the rest — on a phone the copy runs the full width, so a hole
     sized for a desktop hero left squares sitting behind the second line of
     the sentence. */
  var textBox = null;

  function measureText() {
    // The text itself, not the container it sits in. The hero's wrapper is
    // the page's full content width, so measuring that punched a hole the
    // width of the window and left almost no field at all.
    var parts = document.querySelectorAll('.hero h1, .hero .lede, .hero .get');
    if (!parts || !parts.length) { textBox = null; return; }

    var box = canvas.getBoundingClientRect();
    var l = Infinity, r = -Infinity, t = Infinity, b = -Infinity;
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i].getBoundingClientRect();
      if (p.width === 0) continue;
      if (p.left < l) l = p.left;
      if (p.right > r) r = p.right;
      if (p.top < t) t = p.top;
      if (p.bottom > b) b = p.bottom;
    }
    if (l === Infinity) { textBox = null; return; }

    var pad = 26;
    textBox = {
      l: l - box.left - pad, r: r - box.left + pad,
      t: t - box.top - pad,  b: b - box.top + pad
    };
  }

  function weightAt(x, y, w, h) {
    // How far outside the words this is, faded in over a comfortable margin.
    var clear = 1;
    if (textBox) {
      var ox = Math.max(textBox.l - x, x - textBox.r, 0);
      var oy = Math.max(textBox.t - y, y - textBox.b, 0);
      clear = Math.min(1, Math.sqrt(ox * ox + oy * oy) / 130);
    }

    // Off well before the section below starts — most of the lower half is
    // behind the app window anyway, and drawing under it is work nobody sees.
    var bottom = y > h * 0.52 ? Math.max(0, 1 - (y - h * 0.52) / (h * 0.30)) : 1;

    // And a touch under the chrome bar.
    var top = y < h * 0.05 ? y / (h * 0.05) : 1;

    // Both side edges fade rather than stop, or the field ends in a straight
    // line down the window and reads as a panel.
    var margin = w * 0.13;
    var sides = Math.min(1, Math.min(x, w - x) / margin);

    // Densest about three quarters across and thinning both ways. A lean that
    // just rises with x packs the last few columns solid, which is what the
    // right-hand edge looked like before: a wall rather than a drift.
    var t = (x / w - 0.74) / 0.34;
    var lean = 0.3 + 0.7 * Math.exp(-t * t);

    return clear * clear * bottom * top * sides * lean;
  }

  function build() {
    var box = canvas.getBoundingClientRect();
    var w = Math.max(1, Math.round(box.width));
    var h = Math.max(1, Math.round(box.height));
    var dpr = Math.min(window.devicePixelRatio || 1, 2);

    canvas.width = w * dpr;
    canvas.height = h * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    cssW = w; cssH = h;

    cols = Math.ceil(w / PITCH);
    rows = Math.ceil(h / PITCH);
    count = cols * rows;

    weight = new Float32Array(count);
    phase = new Uint8Array(count);
    stamp = new Float64Array(count);
    live = [];
    held = [];

    measureText();

    room = 0;
    for (var i = 0; i < count; i++) {
      var x = (i % cols) * PITCH + SQUARE / 2;
      var y = ((i / cols) | 0) * PITCH + SQUARE / 2;
        var v = weightAt(x, y, w, h);
      weight[i] = v < 0.06 ? 0 : v;   // below this it would never be seen
      if (weight[i] > 0) room++;
    }
    cap = Math.round(room * FILL_TARGET);

    seed();
  }

  /* Start part-filled, and filled the same way the live field grows: plant a
     few nuclei and let the growth rule spread them. Scattering the seed at
     random instead — which is what this did first — produces even static, and
     static is exactly what it must not look like. Pieces clump. */
  function seed() {
    var now = (window.performance ? performance.now() : 0);
    var settled = now - ARRIVE - FLARE;   // already landed, already cooled

    for (var n = 0; n < 26; n++) {
      for (var tries = 0; tries < 30; tries++) {
        var pick = rand(count);
        if (weight[pick] > 0 && phase[pick] === 0) {
          phase[pick] = 1; stamp[pick] = settled;
          live.push(pick); held.push(pick);
          break;
        }
      }
    }

    var target = Math.round(cap * 0.75);
    while (held.length < target) {
      var i = nextCell();
      if (i < 0) break;
      phase[i] = 1; stamp[i] = settled;
      live.push(i); held.push(i);
    }
  }

  /* Where the next piece lands. Mostly beside one that has already arrived,
     because pieces that clump grow shapes and pieces scattered uniformly grow
     static. Near the pointer when there is one, which is the only interactive
     part of this and the only one worth having. */
  function nextCell(inBurst) {
    var tries, i;

    // Inside a burst everything lands in one neighbourhood, which is what
    // makes it read as an arrival rather than more drizzle.
    if (inBurst) {
      for (tries = 0; tries < 24; tries++) {
        var bx = burstX + rand(BURST_SPAN * 2 + 1) - BURST_SPAN;
        var by = burstY + rand(BURST_SPAN * 2 + 1) - BURST_SPAN;
        if (bx < 0 || by < 0 || bx >= cols || by >= rows) continue;
        i = by * cols + bx;
        if (weight[i] > 0 && phase[i] === 0) return i;
      }
    }

    if (cursorSeen && Math.random() < 0.35) {
      for (tries = 0; tries < 12; tries++) {
        var cx = Math.round((cursorX + (Math.random() - 0.5) * CURSOR_REACH * 2) / PITCH);
        var cy = Math.round((cursorY + (Math.random() - 0.5) * CURSOR_REACH * 2) / PITCH);
        if (cx < 0 || cy < 0 || cx >= cols || cy >= rows) continue;
        i = cy * cols + cx;
        if (weight[i] > 0 && phase[i] === 0) return i;
      }
    }

    if (held.length && Math.random() < 0.9) {
      for (tries = 0; tries < 16; tries++) {
        var from = held[rand(held.length)];
        var fx = from % cols, fy = (from / cols) | 0;
        var nx = fx + rand(3) - 1, ny = fy + rand(3) - 1;
        if (nx < 0 || ny < 0 || nx >= cols || ny >= rows) continue;
        i = ny * cols + nx;
        if (weight[i] > 0 && phase[i] === 0) return i;
      }
    }

    for (tries = 0; tries < 20; tries++) {
      i = rand(count);
      if (weight[i] > 0 && phase[i] === 0) return i;
    }
    return -1;
  }

  function land(now, inBurst) {
    var i = nextCell(inBurst);
    if (i < 0) return;
    phase[i] = 1;
    stamp[i] = now;
    live.push(i);
    held.push(i);
  }

  /* Starts a run of pieces somewhere the field has room. Aimed at a spot the
     pointer isn't, when there is a pointer — the cursor already brightens what
     it passes over, and a burst landing under it is one thing too many. */
  function openBurst(now) {
    for (var tries = 0; tries < 30; tries++) {
      var i = rand(count);
      if (weight[i] < 0.35 || phase[i] !== 0) continue;
      // Bias toward the denser half of the field so bursts land where there
      // is already something to join rather than alone in the thin edges.
      if (weight[i] < 0.6 && Math.random() < 0.6) continue;
      burstX = i % cols;
      burstY = (i / cols) | 0;
      burstLeft = BURST_SIZE + rand(BURST_SIZE);
      burstOwed = 0;
      return;
    }
    burstNext = now + BURST_GAP;
  }

  /* Once the field is as full as it is allowed to get, the oldest pieces go
     back. Without this it fills up, stops, and is a picture again. */
  function release(now) {
    while (held.length > cap) {
      var out = held.shift();
      if (phase[out] === 1) { phase[out] = 2; stamp[out] = now; }
    }
  }

  function draw(now) {
    // In CSS pixels, not device ones — the context carries the retina scale,
    // so clearing to canvas.width would wipe an area four times too big every
    // frame on a retina Mac.
    ctx.clearRect(0, 0, cssW, cssH);

    // Where the pools have drifted to this frame. Worked out once here rather
    // than once per piece — the loop below runs several hundred times.
    var pools = [];
    for (var p = 0; p < POOLS.length; p++) {
      var pool = POOLS[p];
      pools.push({
        x: (pool.x + pool.ax * Math.sin(now / pool.sx * TAU)) * cssW,
        y: (pool.y + pool.ay * Math.cos(now / pool.sy * TAU)) * cssH,
        r: pool.r
      });
    }

    var breath = Math.sin(now / BREATH_MS * TAU);

    var still = [];
    for (var n = 0; n < live.length; n++) {
      var i = live[n];
      var age = now - stamp[i];
      var body;

      if (phase[i] === 1) {
        body = age < ARRIVE ? age / ARRIVE : 1;
      } else {
        body = 1 - age / RELEASE;
        if (body <= 0) { phase[i] = 0; continue; }
      }

      var flare = phase[i] === 1 && age < FLARE ? 1 - age / FLARE : 0;
      flare *= flare * 0.6 + flare * 0.4;   // fast off the top, then a long tail

      var x = (i % cols) * PITCH;
      var y = ((i / cols) | 0) * PITCH;

      // Near the pointer a piece brightens and leans blue, so moving across
      // the field feels like touching it rather than dragging a spotlight.
      var near = 0;
      if (cursorSeen) {
        var dx = x - cursorX, dy = y - cursorY;
        var d = Math.sqrt(dx * dx + dy * dy);
        if (d < CURSOR_REACH) { near = 1 - d / CURSOR_REACH; near *= near; }
      }

      // How deep in a pool of warmth this piece is sitting.
      var lift = 0;
      for (var q = 0; q < pools.length; q++) {
        var pdx = x - pools[q].x, pdy = y - pools[q].y;
        var pd = Math.sqrt(pdx * pdx + pdy * pdy);
        if (pd < pools[q].r) {
          var f = 1 - pd / pools[q].r;
          f *= f;
          if (f > lift) lift = f;
        }
      }

      // The breath is offset along a diagonal, so it travels across the field
      // as a slow swell rather than the whole thing blinking at once.
      var wave = 1 + BREATH * Math.sin(
        now / BREATH_MS * TAU - (x + y) * 0.0035
      ) * (0.4 + 0.6 * (0.5 + 0.5 * breath));

      var blue = Math.min(1, flare + near * 0.75 + lift * 0.45);
      var alpha = weight[i] * body
        * (HELD_ALPHA * wave * (1 + POOL_LIFT * lift)
           + FLARE_ALPHA * flare
           + 0.10 * near);

      if (alpha < 0.003) { still.push(i); continue; }

      // Grey at rest, accent as it lands. The app's own two colours.
      var r = Math.round(255 - 192 * blue);
      var g = Math.round(255 - 86 * blue);
      var b = 255;
      ctx.fillStyle = 'rgba(' + r + ',' + g + ',' + b + ',' + alpha.toFixed(3) + ')';

      if (ctx.roundRect) {
        ctx.beginPath();
        ctx.roundRect(x, y, SQUARE, SQUARE, CORNER);
        ctx.fill();
      } else {
        ctx.fillRect(x, y, SQUARE, SQUARE);
      }
      still.push(i);
    }
    live = still;
  }

  function frame(now) {
    raf = 0;
    if (!running) return;

    var dt = Math.min(now - last, 250);
    last = now;

    owed += (dt / 1000) * DRIZZLE;
    while (owed >= 1) { land(now, false); owed -= 1; }

    if (burstLeft > 0) {
      burstOwed += (dt / 1000) * BURST_RATE;
      while (burstOwed >= 1 && burstLeft > 0) {
        land(now, true);
        burstLeft -= 1;
        burstOwed -= 1;
      }
      if (burstLeft === 0) burstNext = now + BURST_GAP + Math.random() * BURST_GAP;
    } else if (now >= burstNext) {
      openBurst(now);
    }

    release(now);
    draw(now);

    raf = requestAnimationFrame(frame);
  }

  function start() {
    if (running || reduceMotion) return;
    running = true;
    last = performance.now();
    raf = requestAnimationFrame(frame);
  }

  function stop() {
    running = false;
    if (raf) { cancelAnimationFrame(raf); raf = 0; }
  }

  // --- wiring --------------------------------------------------------------
  build();

  if (reduceMotion) {
    draw(performance.now());
  } else if ('IntersectionObserver' in window) {
    new IntersectionObserver(function (entries) {
      entries[0].isIntersecting ? start() : stop();
    }).observe(canvas);
    start();
  } else {
    start();
  }

  var resizeTimer = 0;
  window.addEventListener('resize', function () {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () {
      build();
      if (reduceMotion) draw(performance.now());
    }, 200);
  }, { passive: true });

  if (!reduceMotion
      && window.matchMedia
      && window.matchMedia('(hover: hover) and (pointer: fine)').matches) {
    window.addEventListener('pointermove', function (event) {
      var box = canvas.getBoundingClientRect();
      cursorX = event.clientX - box.left;
      cursorY = event.clientY - box.top;
      cursorSeen = 1;
    }, { passive: true });
  }
})();
