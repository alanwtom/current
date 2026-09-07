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
 * It covers the whole screen and the text sits on top of it, which is the one
 * thing worth taking from Codex's hero — theirs is a pre-rendered video, not
 * code, and despite appearances it doesn't answer the pointer at all. Ours
 * does: the pointer carries a light with it, drags nine layers of colour past
 * each other at nine different rates, and pulls a wake of arriving pieces
 * along behind it.
 *
 * Two rules it can't break:
 *
 * - **The words stay readable.** The field runs under them at a bit over a
 *   quarter strength. It was a hole for a while, then a column to the right of
 *   the text — both wrong, for the same reason: the headline, its sentence and
 *   the download row span nearly the whole content width between them, so
 *   anything that avoids them avoids most of the screen.
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

  // Turned down across the board from where this peaked. It had become the
  // loudest thing on a page whose whole argument is that software should be
  // quiet — a background you notice is a background that has failed. What is
  // kept is the shape of it: pieces still land in bursts, the light still
  // drifts, the pointer still leads it. It just does all of that under its
  // breath now.
  var HELD_ALPHA  = 0.075;  // a piece at rest, outside any pool
  var FLARE_ALPHA = 0.44;   // the moment it lands
  var FILL_TARGET = 0.20;   // how much of the field is held at once

  // The fade-in has to be far shorter than the flare, or a piece spends the
  // brightest part of its life still fading up and the landing never reads.
  var ARRIVE  = 220;
  var FLARE   = 1100;
  var RELEASE = 1300;

  var DRIZZLE    = 3;     // pieces a second, always
  var BURST_SIZE = 16;    // and a run of them arriving together
  var BURST_RATE = 60;    // pieces a second inside a burst
  var BURST_GAP  = 850;   // ms of quiet after one, plus up to as much again
  var BURST_SPAN = 4;     // cells — how tight a burst lands

  // The pointer is the loudest thing in here, not a garnish.
  var CURSOR_REACH = 270;   // px — how far its light carries
  var CURSOR_LIFT  = 1.7;   // how much brighter a piece under it goes
  var CURSOR_EASE  = 0.075; // per frame — the lag that gives it weight
  var CURSOR_PULL  = 0.16;  // how much a burst prefers to land under it
  var TEXT_SHADE   = 0.24;  // how much of the field survives behind the words
  var GAIN_EASE    = 0.04;  // how fast it arrives and leaves

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
    // The big slow one, over on the left behind the headline: mostly ambient,
    // and what keeps that side of the screen from reading as flat black.
    //
    // `par` is how far this pool is dragged by the pointer, as a fraction of
    // its distance from the middle of the screen. All different, so the layers
    // slide over each other as you move rather than moving as one sheet —
    // which is the whole trick, and it doesn't work if they share a value.
    { x: 0.22, y: 0.26, ax: 0.05, ay: 0.06, px: 46500, py: 34500, r: 560, hue: 0, a: 0.093, par: 0.05 },
    { x: 0.34, y: 0.62, ax: 0.13, ay: 0.15, px: 22950, py: 16950, r: 260, hue: 1, a: 0.056, par: 0.14 },
    { x: 0.12, y: 0.55, ax: 0.10, ay: 0.13, px: 29550, py: 24450, r: 200, hue: 0, a: 0.062, par: 0.20 },
    { x: 0.50, y: 0.34, ax: 0.14, ay: 0.18, px: 14550, py: 18450, r: 230, hue: 0, a: 0.074, par: 0.11 },
    { x: 0.81, y: 0.50, ax: 0.13, ay: 0.16, px: 19650, py: 13350, r: 175, hue: 1, a: 0.062, par: 0.24 },
    { x: 0.71, y: 0.70, ax: 0.17, ay: 0.12, px: 25950, py: 17550, r: 245, hue: 0, a: 0.074, par: 0.08 },
    { x: 0.91, y: 0.27, ax: 0.09, ay: 0.21, px: 16050, py: 22650, r: 150, hue: 1, a: 0.068, par: 0.28 },
    { x: 0.67, y: 0.49, ax: 0.20, ay: 0.17, px: 31650, py: 21450, r: 295, hue: 0, a: 0.062, par: 0.17 },
    { x: 0.87, y: 0.78, ax: 0.11, ay: 0.14, px: 19050, py: 28950, r: 190, hue: 1, a: 0.068, par: 0.13 }
  ];

  var POOL_LIFT = 1.5;    // how much brighter a piece sitting in one is
  var BREATH    = 0.16;   // how far the whole field rises and falls
  var BREATH_MS = 7600;   // and how long one breath takes

  // The light buffer's scale, and it is a balance: coarser interpolates the
  // banding away more aggressively, finer puts the dither on smaller pixels so
  // the contours break up properly. Two is where both work.
  var GLOW_STEP = 2;
  var FADE_FROM = 0.54;   // where the light starts fading out at the bottom

  // --- state ---------------------------------------------------------------
  var cols = 0, rows = 0, count = 0, room = 0, cap = 0, cssW = 0, cssH = 0;
  var weight, flareMul, phase, stamp;   // 0 empty, 1 arriving/held, 2 releasing
  var live = [];              // indices currently drawing anything
  var held = [];              // indices in phase 1, oldest first
  // Where the pointer is, where the field thinks it is, and how much it is
  // listening. The eased position is what everything reads: chasing the real
  // one exactly makes the field feel nailed to the cursor, and the small lag
  // is most of what makes it feel like it has weight.
  var pointerX = 0, pointerY = 0, pointerIn = 0;
  var aimX = 0, aimY = 0, gain = 0;
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

  /* How much of the field is allowed to exist at a point: everywhere, dimmer
     behind the words, faded at the edges, gone before the section below.

     This was a column on the right for a while, which fixed one problem and
     created a worse one — half the screen with nothing happening in it. It
     went one-sided because of a stagnant block of squares in the left gutter,
     but the fault there was that nothing in that block ever moved, not that it
     was on the left. The pointer drives the whole field now, so there is no
     stagnant corner left to hide. */
  /* How much of the words' shade applies at a point: 1 in the open, down to
     TEXT_SHADE over the text. Kept separately from the weight because the
     flare is damped by it a second time — a resting piece behind the sentence
     is texture, but one flaring at full strength is a light blinking behind
     small grey type, which is the difference between a background and a
     distraction. */
  function shadeAt(x, y) {
    if (!textBox) return 1;
    var ox = Math.max(textBox.l - x, x - textBox.r, 0);
    var oy = Math.max(textBox.t - y, y - textBox.b, 0);
    var out = Math.min(1, Math.sqrt(ox * ox + oy * oy) / 96);
    return TEXT_SHADE + (1 - TEXT_SHADE) * out * out;
  }

  function weightAt(x, y, w, h) {
    // The field runs under the words as well, at a fraction of its strength.
    //
    // A hole was the wrong shape for "full bleed": the headline, the sentence
    // under it and the download row together span nearly the whole content
    // width, so cutting them out leaves two thin strips at the sides and not
    // much else. Codex's hero runs its whole animation under the text and puts
    // the text on top; at this alpha the pieces behind a 54px headline are
    // texture rather than clutter, and there is no legibility to lose against
    // white type on near-black.
    var clear = shadeAt(x, y);

    // Off well before the section below starts — most of the lower half is
    // behind the app window anyway, and drawing under it is unseen work.
    var bottom = y > h * FADE_FROM
      ? Math.max(0, 1 - (y - h * FADE_FROM) / (h * (1 - FADE_FROM)))
      : 1;

    // A touch under the chrome bar, and fading into both edges rather than
    // stopping at them in a straight line.
    var top = y < h * 0.05 ? y / (h * 0.05) : 1;
    var side = Math.min(1, Math.min(x, w - x) / (w * 0.07));

    // `clear` is not squared here on purpose: the rim easing above already
    // does that shaping, and squaring it a second time took the field behind
    // the words from a quarter strength to a sixteenth, which is invisible
    // rather than subtle.
    return clear * bottom * top * side;
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
    flareMul = new Float32Array(count);
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
      flareMul[i] = shadeAt(x, y);
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

    if (gain > 0.05 && Math.random() < 0.55 * gain) {
      for (tries = 0; tries < 14; tries++) {
        var cx = Math.round((aimX + (Math.random() - 0.5) * CURSOR_REACH) / PITCH);
        var cy = Math.round((aimY + (Math.random() - 0.5) * CURSOR_REACH) / PITCH);
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
    // Most bursts land near the pointer while there is one, so moving the
    // mouse across the field pulls a wake of arrivals along behind it.
    if (gain > 0.4 && Math.random() < 0.7) {
      for (var t2 = 0; t2 < 20; t2++) {
        var bx = Math.round((aimX + (Math.random() - 0.5) * CURSOR_REACH * 1.4) / PITCH);
        var by = Math.round((aimY + (Math.random() - 0.5) * CURSOR_REACH * 1.4) / PITCH);
        if (bx < 0 || by < 0 || bx >= cols || by >= rows) continue;
        var bi = by * cols + bx;
        if (weight[bi] < 0.2 || phase[bi] !== 0) continue;
        burstX = bx; burstY = by;
        burstLeft = BURST_SIZE + rand(BURST_SIZE);
        burstOwed = 0;
        return;
      }
    }

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
    var offX = (aimX - cssW / 2) * gain;
    var offY = (aimY - cssH / 2) * gain;
    var out = [];
    for (var i = 0; i < POOLS.length; i++) {
      var p = POOLS[i];
      out.push({
        x: (p.x + p.ax * Math.sin(now / p.px * TAU)) * cssW + offX * p.par,
        y: (p.y + p.ay * Math.cos(now / p.py * TAU)) * cssH + offY * p.par,
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
      if (gain > 0.01) {
        var dx = x - aimX, dy = y - aimY;
        var d = Math.sqrt(dx * dx + dy * dy);
        if (d < CURSOR_REACH) {
          near = 1 - d / CURSOR_REACH;
          near *= near;   // a bright core that still carries to the edge
          near *= gain;
        }
      }

      var alpha = weight[i] * body
        * (HELD_ALPHA * wave * (1 + POOL_LIFT * lift + CURSOR_LIFT * near)
           + FLARE_ALPHA * flare * flareMul[i]);

      if (alpha < 0.004) { still.push(i); continue; }

      // Grey at rest; the pool's own hue where the light is; accent as it
      // lands, because a landing is the app's "this is happening".
      var tint = Math.min(1, flare + near * 1.4 + lift * 0.7);
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

    // Frame-rate independent easing, so the lag feels the same at 60 and 120Hz.
    var step = 1 - Math.pow(1 - CURSOR_EASE, dt / 16.7);
    aimX += (pointerX - aimX) * step;
    aimY += (pointerY - aimY) * step;
    var gstep = 1 - Math.pow(1 - GAIN_EASE, dt / 16.7);
    gain += (pointerIn - gain) * gstep;

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
    // Start it in the middle, so the first movement eases out from the centre
    // rather than flying in from a corner.
    aimX = pointerX = cssW / 2;
    aimY = pointerY = cssH / 2;

    window.addEventListener('pointermove', function (event) {
      var box = canvas.getBoundingClientRect();
      pointerX = event.clientX - box.left;
      pointerY = event.clientY - box.top;
      pointerIn = 1;
    }, { passive: true });

    // Leaving the window puts the light back where it was rather than
    // stranding it wherever the pointer happened to exit.
    document.addEventListener('mouseleave', function () { pointerIn = 0; });
    document.addEventListener('mouseenter', function () { pointerIn = 1; });
  }
})();
