/* The piece field behind the first screen.
 *
 * A torrent arrives as thousands of fixed-size pieces, out of order, from
 * strangers. That is the one picture this page is about, and it is what the
 * background draws: a field of small squares that land, flare, cool and
 * eventually go again, lit from underneath by pools of colour drifting past
 * each other at different rates.
 *
 * Three things this has already been, and why it isn't them any more:
 *
 * - **Two blurred blobs and a grid.** What every dark landing page has, and
 *   it said nothing about this one.
 * - **An even drizzle of squares.** Ten lit out of eight hundred reads as a
 *   still picture no matter how many there are. Pieces arrive in bursts now,
 *   which is also how they really arrive.
 * - **Slow.** Loops of a minute or more sit below the rate at which movement
 *   registers at all: technically animated, visually frozen. Everything here
 *   now turns over in seconds.
 *
 * Two rules it can't break:
 *
 * - **Nothing to the left of the words.** The clear area is measured from the
 *   headline itself, and it is one-sided — the field starts after the text's
 *   right edge and runs to the window edge. It used to be a plain distance,
 *   which meant the whole left gutter qualified: on a wide display that put a
 *   large block of squares out there with nothing to do and nowhere to go.
 * - **It stops dead when scrolled past.** A background still painting while
 *   nobody is looking is a battery drain.
 *
 * The light underneath is painted into a small buffer and scaled up, rather
 * than being a CSS gradient. A gradient this wide and this dark quantises into
 * visible contour lines on an 8-bit screen — that was the faint striping this
 * used to have. Interpolating a small buffer up smooths the steps out, and a
 * little noise in the buffer breaks up what survives that.
 *
 * Its own file on purpose: the page's scripts each run alone, so a fault in a
 * decoration can't take the demo or the scroll reveals with it.
 */
(function () {
  var canvas = document.getElementById('bg-field');
  if (!canvas || !canvas.getContext) return;

  var ctx = canvas.getContext('2d', { alpha: true });
  if (!ctx) return;

  var reduceMotion = window.matchMedia
    && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  var TAU = Math.PI * 2;

  // --- the pieces ----------------------------------------------------------
  var PITCH   = 17;     // cell to cell, including the gap
  var SQUARE  = 13;     // the drawn square, so a 4pt gutter — the app's own
  var CORNER  = 2;

  var HELD_ALPHA  = 0.10;   // a piece at rest, outside any pool
  var FLARE_ALPHA = 0.62;   // the moment it lands
  var FILL_TARGET = 0.26;   // how much of the field is held at once

  // The fade-in has to be far shorter than the flare, or a piece spends the
  // brightest part of its life still fading up and the landing never reads.
  var ARRIVE  = 220;
  var FLARE   = 1100;
  var RELEASE = 1300;

  var DRIZZLE    = 5;     // pieces a second, always
  var BURST_SIZE = 22;    // and a run of them arriving together
  var BURST_RATE = 90;    // pieces a second inside a burst
  var BURST_GAP  = 420;   // ms of quiet after one, plus up to as much again
  var BURST_SPAN = 4;     // cells — how tight a burst lands

  var CURSOR_REACH = 150; // px — pieces near the pointer brighten

  // --- the light -----------------------------------------------------------
  //
  // Periods are seconds rather than minutes, and deliberately share no
  // factors: pools on round numbers resynchronise and the whole field visibly
  // pulses as one, which is the opposite of the intent.
  //
  // hue 0 is the app's accent blue, 1 its teal. Mixing the two is what makes
  // colour appear to move, rather than only brightness.
  var ACCENT = [63, 169, 255];
  var TEAL   = [45, 212, 191];

  var POOLS = [
    // The big quiet one behind the headline. Ambient only — no squares live
    // over there — and it is what keeps the left of the screen from being the
    // flat black this all started as.
    { x: 0.26, y: 0.24, ax: 0.05, ay: 0.06, px: 31000, py: 23000, r: 560, hue: 0, a: 0.15 },

    { x: 0.62, y: 0.30, ax: 0.15, ay: 0.19, px:  9700, py: 12300, r: 210, hue: 0, a: 0.13 },
    { x: 0.81, y: 0.50, ax: 0.13, ay: 0.16, px: 13100, py:  8900, r: 175, hue: 1, a: 0.10 },
    { x: 0.71, y: 0.70, ax: 0.17, ay: 0.12, px: 17300, py: 11700, r: 245, hue: 0, a: 0.12 },
    { x: 0.91, y: 0.27, ax: 0.09, ay: 0.21, px: 10700, py: 15100, r: 150, hue: 1, a: 0.11 },
    { x: 0.67, y: 0.49, ax: 0.20, ay: 0.17, px: 21100, py: 14300, r: 295, hue: 0, a: 0.10 },
    { x: 0.87, y: 0.78, ax: 0.11, ay: 0.14, px: 12700, py: 19300, r: 190, hue: 1, a: 0.11 }
  ];

  var POOL_LIFT = 2.2;    // how much brighter a piece sitting in one is
  var BREATH    = 0.30;   // how far the whole field rises and falls
  var BREATH_MS = 5200;   // and how long one breath takes

  // The light buffer's scale, and it is a balance: coarser interpolates the
  // banding away more aggressively, finer puts the dither on smaller pixels so
  // the contours break up properly. Two is where both work.
  var GLOW_STEP = 2;
  var FADE_FROM = 0.54;   // where the light starts fading out at the bottom

  // --- state ---------------------------------------------------------------
  var cols = 0, rows = 0, count = 0, room = 0, cap = 0, cssW = 0, cssH = 0;
  var weight, phase, stamp;   // 0 empty, 1 arriving/held, 2 releasing
  var live = [];              // indices currently drawing anything
  var held = [];              // indices in phase 1, oldest first
  var cursorX = -1e4, cursorY = -1e4, cursorSeen = 0;
  var running = false, last = 0, owed = 0, raf = 0;
  var burstLeft = 0, burstOwed = 0, burstX = 0, burstY = 0, burstNext = 0;
  var textBox = null;
  var glow = null, gctx = null, dither = null;

  function rand(n) { return (Math.random() * n) | 0; }

  /* The text itself, not the container it sits in. The hero's wrapper is the
     page's full content width, so measuring that punches a hole the width of
     the window and leaves no field at all. */
  function measureText() {
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

    textBox = {
      l: l - box.left, r: r - box.left,
      t: t - box.top,  b: b - box.top
    };
  }

  /* How much of the field is allowed to exist at a point.
     Nothing at all to the left of the words; a margin to their right before it
     starts; gone before the section below. */
  function weightAt(x, y, w, h) {
    // One-sided, at every height: the field is a column to the right of the
    // words and nothing else. Allowing it below them as well left a band of
    // squares under the download button, on the left, where they mostly sat
    // still — the single thing about this that looked worst.
    var clear = 1;
    if (textBox) {
      if (x <= textBox.r) return 0;
      clear = Math.min(1, (x - textBox.r) / 110);
    }

    // Off well before the section below starts — most of the lower half is
    // behind the app window anyway, and drawing under it is unseen work.
    var bottom = y > h * FADE_FROM
      ? Math.max(0, 1 - (y - h * FADE_FROM) / (h * (1 - FADE_FROM)))
      : 1;

    // A touch under the chrome bar, and fading into the right edge rather
    // than stopping at it in a straight line.
    var top = y < h * 0.05 ? y / (h * 0.05) : 1;
    var side = Math.min(1, (w - x) / (w * 0.10));

    return clear * clear * bottom * top * side;
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

    buildGlow();
    seed();
  }

  /* The buffer the pools are painted into, at a fraction of the real size.
     Scaling it back up is what keeps a wide dark gradient from banding into
     contour lines, and the noise tile breaks up whatever survives that. */
  function buildGlow() {
    if (!glow) {
      glow = document.createElement('canvas');
      if (!glow || !glow.getContext) { glow = null; return; }
      gctx = glow.getContext('2d');
      if (!gctx) { glow = null; return; }
    }
    glow.width = Math.max(1, Math.ceil(cssW / GLOW_STEP));
    glow.height = Math.max(1, Math.ceil(cssH / GLOW_STEP));

    buildDither();
  }

  /* One step of dither, added rather than laid on top, and in the light's own
     colour rather than white.
     Banding is a quantising artefact: a 1/255 step spread over enough pixels
     shows as a contour line, and on a background this dark those steps are
     wide. Varying each pixel by that same single step breaks the lines up, and
     one step is far below what anyone can see as texture.

     Two ways I got this wrong first, both of which looked like poor rendering:

     - Noise in the light buffer, which is a quarter-scale, so it was scaled up
       into four-pixel blobs at fourteen times this amplitude. That is grain,
       not dither.
     - White, painted over the finished canvas with source-over. The canvas is
       barely opaque — around 14/255 where the light is — so adding even 2/255
       of white shifts the *ratio* of the channels enormously: red swung
       between 73 and 96 on neighbouring pixels. Visible chroma noise from an
       adjustment that was supposed to be invisible.

     Additive, in the accent's own hue, inside the buffer: brightness moves by
     one step and the colour does not move at all. */
  function buildDither() {
    if (dither || !gctx.createPattern) return;
    var tile = document.createElement('canvas');
    if (!tile.getContext) return;
    tile.width = tile.height = 64;
    var t = tile.getContext('2d');
    if (!t || !t.createImageData) return;
    var img = t.createImageData(64, 64);
    for (var i = 0; i < img.data.length; i += 4) {
      img.data[i] = ACCENT[0];
      img.data[i + 1] = ACCENT[1];
      img.data[i + 2] = ACCENT[2];
      img.data[i + 3] = Math.random() < 0.5 ? 0 : 1;
    }
    t.putImageData(img, 0, 0);
    dither = gctx.createPattern(tile, 'repeat');
  }

  /* Start part-filled, and filled the way the live field grows: plant a few
     nuclei and let the growth rule spread them. Seeding at random instead
     produces even static, which is what this must not look like. */
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
      var i = nextCell(false);
      if (i < 0) break;
      phase[i] = 1; stamp[i] = settled;
      live.push(i); held.push(i);
    }
  }

  /* Where the next piece lands. Inside a burst, one neighbourhood — that is
     what makes it read as an arrival. Otherwise beside a piece already there,
     because pieces that clump grow shapes and pieces scattered grow static. */
  function nextCell(inBurst) {
    var tries, i;

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

  function openBurst(now) {
    for (var tries = 0; tries < 30; tries++) {
      var i = rand(count);
      if (weight[i] < 0.35 || phase[i] !== 0) continue;
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

  /* Where each pool has drifted to this frame. Worked out once per frame —
     the piece loop below runs several hundred times. */
  function placePools(now) {
    var out = [];
    for (var i = 0; i < POOLS.length; i++) {
      var p = POOLS[i];
      out.push({
        x: (p.x + p.ax * Math.sin(now / p.px * TAU)) * cssW,
        y: (p.y + p.ay * Math.cos(now / p.py * TAU)) * cssH,
        r: p.r, hue: p.hue, a: p.a
      });
    }
    return out;
  }

  function paintGlow(pools, breath) {
    if (!glow) return;
    var s = GLOW_STEP;
    gctx.clearRect(0, 0, glow.width, glow.height);
    gctx.globalCompositeOperation = 'lighter';

    for (var i = 0; i < pools.length; i++) {
      var p = pools[i];
      var c = p.hue ? TEAL : ACCENT;
      var r = p.r / s, px = p.x / s, py = p.y / s;
      var a = p.a * (0.82 + 0.18 * breath);
      var g = gctx.createRadialGradient(px, py, 0, px, py, r);
      g.addColorStop(0, 'rgba(' + c[0] + ',' + c[1] + ',' + c[2] + ',' + a.toFixed(3) + ')');
      g.addColorStop(1, 'rgba(' + c[0] + ',' + c[1] + ',' + c[2] + ',0)');
      gctx.fillStyle = g;
      gctx.fillRect(px - r, py - r, r * 2, r * 2);
    }

    if (dither) {
      gctx.fillStyle = dither;
      gctx.fillRect(0, 0, glow.width, glow.height);
    }

    // Fade the light out downward instead of stopping at the buffer's edge.
    // Without this the glow ends on a straight horizontal line across the
    // page, which is obvious anywhere the app window doesn't cover it.
    gctx.globalCompositeOperation = 'destination-out';
    var fade = gctx.createLinearGradient(0, glow.height * FADE_FROM, 0, glow.height);
    fade.addColorStop(0, 'rgba(0,0,0,0)');
    fade.addColorStop(0.55, 'rgba(0,0,0,0.65)');
    fade.addColorStop(1, 'rgba(0,0,0,1)');
    gctx.fillStyle = fade;
    gctx.fillRect(0, glow.height * FADE_FROM, glow.width, glow.height);

    gctx.globalCompositeOperation = 'source-over';
  }

  function draw(now) {
    // In CSS pixels, not device ones — the context carries the retina scale,
    // so clearing to canvas.width would wipe an area four times too big every
    // frame on a retina Mac.
    ctx.clearRect(0, 0, cssW, cssH);

    var pools = placePools(now);
    var breath = Math.sin(now / BREATH_MS * TAU);

    paintGlow(pools, breath);
    if (glow) {
      ctx.imageSmoothingEnabled = true;
      if ('imageSmoothingQuality' in ctx) ctx.imageSmoothingQuality = 'high';
      ctx.drawImage(glow, 0, 0, cssW, cssH);
    }

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
      flare *= flare * 0.6 + flare * 0.4;   // fast off the top, then a tail

      var x = (i % cols) * PITCH;
      var y = ((i / cols) | 0) * PITCH;

      // How deep in a pool this piece sits, and whose pool it is. Carrying the
      // hue through to the square is what makes the colour appear to move
      // rather than only the brightness.
      var lift = 0, teal = 0;
      for (var q = 0; q < pools.length; q++) {
        var pdx = x - pools[q].x, pdy = y - pools[q].y;
        var pd = Math.sqrt(pdx * pdx + pdy * pdy);
        if (pd < pools[q].r) {
          var f = 1 - pd / pools[q].r;
          f *= f;
          if (f > lift) { lift = f; teal = pools[q].hue; }
        }
      }

      // The breath travels across as a swell rather than the whole field
      // blinking at once.
      var wave = 1 + BREATH * Math.sin(now / BREATH_MS * TAU - (x + y) * 0.0035);

      var near = 0;
      if (cursorSeen) {
        var dx = x - cursorX, dy = y - cursorY;
        var d = Math.sqrt(dx * dx + dy * dy);
        if (d < CURSOR_REACH) { near = 1 - d / CURSOR_REACH; near *= near; }
      }

      var alpha = weight[i] * body
        * (HELD_ALPHA * wave * (1 + POOL_LIFT * lift)
           + FLARE_ALPHA * flare
           + 0.10 * near);

      if (alpha < 0.004) { still.push(i); continue; }

      // Grey at rest; the pool's own hue where the light is; accent as it
      // lands, because a landing is the app's "this is happening".
      var tint = Math.min(1, flare + near * 0.75 + lift * 0.7);
      var c = teal ? TEAL : ACCENT;
      var r = Math.round(255 + (c[0] - 255) * tint);
      var g = Math.round(255 + (c[1] - 255) * tint);
      var b = Math.round(255 + (c[2] - 255) * tint);

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
