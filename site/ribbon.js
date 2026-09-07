/* The hero's background: three ribbons of light, resolved into a dot matrix.
 *
 * Nothing is drawn as a ribbon. There are three invisible waves running left to
 * right across the hero, and a grid of dots laid over them; each dot asks how
 * close it is to a wave, and answers with its size and its colour. Far away it
 * is a half-pixel of near-black indigo. On the line itself it is a 2.6px teal
 * dot. Everything you can actually see — the edges, the crossings, the way the
 * shape reads as a surface rather than a stack of curves — is that one rule
 * applied 4,000 times.
 *
 * It is deliberately dim and deliberately slow. The page's whole argument is
 * that software should be quiet, and the first version of a background here got
 * removed for being the loudest thing on screen. The way this one earns its
 * place is by never competing with the headline: the brightest dot is 62%
 * opaque and 2.6px wide, a full wave takes about twenty seconds, and the CSS
 * mask has it gone before the app window begins.
 *
 * Four things worth knowing before changing any of it:
 *
 *   * Reduce Motion draws one frame and stops. Not a slower version, not a
 *     shorter one — the timer never starts and the pointer is never listened
 *     for, so there is nothing left that could move.
 *   * It only runs while it is on screen. An IntersectionObserver stops the
 *     loop once you have scrolled past the hero, and page visibility stops it
 *     when the tab is in the background, because this is a laptop's battery.
 *   * Dots are drawn in twelve batches, not one at a time. Colour and size are
 *     quantised into twelve steps, so a frame is twelve fill() calls instead of
 *     four thousand. That is the difference between 1ms and 20ms a frame.
 *   * The wave positions are computed once per column, not once per dot. Every
 *     dot in a column sits under the same three waves, so the sines come out of
 *     the inner loop and the falloff comes out of a lookup table.
 *
 * Its own file, like the page's other scripts, so a fault in here can't take
 * the demo or the reveals with it.
 */
(function () {
  var cv = document.getElementById('ribbon');
  if (!cv || !cv.getContext) return;

  var ctx = cv.getContext('2d');
  if (!ctx) return;

  var TAU = Math.PI * 2;

  /* Reduce Motion, and the belt-and-braces case of a browser with no
     matchMedia at all — both get the still frame. */
  var still = !window.matchMedia ||
              matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ---- the three waves --------------------------------------------------
     Each is a base height down the canvas plus two sines, one long and one
     short, which is what keeps the line from reading as a single tidy sine.
     `speed` is in cycles per second: 0.055 is one pass every eighteen seconds.
     `thick` is the falloff distance in canvas heights — how far from the line a
     dot can be and still light up at all. `gain` dims the whole ribbon, so the
     third one sits behind the other two.

     `thick` is the number that decides whether this reads as ribbons at all.
     The first pass had it at 0.115 — 74px of falloff on a 640px hero, three
     times over — and the three lines merged into one soft blob, so the hero
     looked like a rectangle of dots with some vague weather in it. Thin lines
     with clear dark between them is the whole effect.
     -------------------------------------------------------------------- */
  var RIBBONS = [
    { base: 0.31, thick: 0.055, gain: 1.00,
      f1: 0.9, a1: 0.150, s1:  0.055,   f2: 2.1, a2: 0.048, s2: -0.037 },
    { base: 0.50, thick: 0.045, gain: 0.88,
      f1: 1.3, a1: 0.125, s1: -0.041,   f2: 2.7, a2: 0.042, s2:  0.061 },
    { base: 0.68, thick: 0.034, gain: 0.66,
      f1: 1.7, a1: 0.095, s1:  0.033,   f2: 3.4, a2: 0.032, s2: -0.052 }
  ];

  var SPACING = 15;   // CSS px between dots
  var STEPS   = 12;   // colour and size steps; also the number of fill() calls
  var FLOOR   = 0.10; // below this a dot isn't worth drawing at all

  /* ---- keeping out of the headline's way --------------------------------
     The hero's text is all on the left. The ribbon is held to 30% strength
     there and comes up to full across the middle of the page, so the words sit
     on near-black and the field does its arguing in the empty right-hand side.

     This is a gain in the field rather than a second mask layer on the canvas,
     because compositing two masks needs `mask-composite: intersect` and the
     fallback when a browser doesn't have it is the *union* — a ribbon at full
     strength everywhere, including over the screenshot. Wrong in a way that
     only shows up somewhere you aren't looking.
     -------------------------------------------------------------------- */
  var LEFT_GAIN = 0.30, LEFT_EDGE = 0.18, RIGHT_EDGE = 0.68;

  /* ---- the colour ramp --------------------------------------------------
     The app's own palette, dimmed: indigo at the invisible edge, the accent
     blue through the body of the ribbon, pale cyan at the core. Not the
     reference's cyan/indigo/purple — that belongs to a different site, and
     purple means nothing anywhere in Current.

     The core was the app's teal (#2dd4bf) first, which is the obvious choice
     from the palette and looked wrong: teal over near-black at a fifth of an
     opacity reads as olive, so the hero came out faintly green. The core is
     the *end of the blue*, not a second hue.

     Each row is [position, r, g, b, alpha].
     -------------------------------------------------------------------- */
  var STOPS = [
    [0.00,  52,  76, 190, 0.00],
    [0.52,  63, 169, 255, 0.30],
    [1.00, 124, 224, 238, 0.62]
  ];

  var FILL   = [];               // one rgba() string per step
  var RADIUS = new Float32Array(STEPS);
  (function buildRamp() {
    for (var b = 0; b < STEPS; b++) {
      var f = (b + 0.5) / STEPS;
      var i = 1;
      while (i < STOPS.length - 1 && f > STOPS[i][0]) i++;
      var lo = STOPS[i - 1], hi = STOPS[i];
      var k = (f - lo[0]) / (hi[0] - lo[0]);
      if (k < 0) k = 0; else if (k > 1) k = 1;
      FILL[b] = 'rgba(' +
        Math.round(lo[1] + (hi[1] - lo[1]) * k) + ',' +
        Math.round(lo[2] + (hi[2] - lo[2]) * k) + ',' +
        Math.round(lo[3] + (hi[3] - lo[3]) * k) + ',' +
        (lo[4] + (hi[4] - lo[4]) * k).toFixed(3) + ')';
      /* Size carries the value as much as colour does — that is what makes a
         halftone read as a surface. The power is above 1 on purpose: it holds
         the faint dots down near half a pixel so the grid they sit on stays
         out of sight, and only the line itself has dots with any weight. Below
         1 it does the opposite, and the hero grows a visible mesh. */
      RADIUS[b] = 0.45 + 1.85 * Math.pow(f, 1.25);
    }
  })();

  /* ---- the falloff table -----------------------------------------------
     A gaussian, but Math.exp() called three times per dot is the single most
     expensive thing in the frame, and none of that precision survives being
     quantised into twelve steps a moment later. So: 192 samples of
     exp(-q) over q in [0, 6], and past 6 the answer is close enough to zero
     that the dot is skipped.
     -------------------------------------------------------------------- */
  var LUT_N = 192, LUT_MAX = 6, LUT_SCALE = LUT_N / LUT_MAX;
  var FALL = new Float32Array(LUT_N + 1);
  (function buildFalloff() {
    for (var i = 0; i <= LUT_N; i++) FALL[i] = Math.exp(-(i / LUT_N) * LUT_MAX);
  })();

  /* ---- geometry, rebuilt on resize -------------------------------------- */
  var W = 0, H = 0, cols = 0, rows = 0, x0 = 0, y0 = 0;
  var colU = null;                  // 0..1 across the width, per column
  var colGain = null;               // the left-hand hold-back, per column
  var rowV = null;                  // 0..1 down the height, per row
  var centres = [];                 // one Float32Array per ribbon, per column
  var bucketXY = [], bucketN = new Int32Array(STEPS);
  var docLeft = 0, docTop = 0;      // canvas position in the document

  function measure() {
    var r = cv.getBoundingClientRect();
    var w = Math.max(1, Math.round(r.width));
    var h = Math.max(1, Math.round(r.height));

    docLeft = r.left + (window.scrollX || window.pageXOffset || 0);
    docTop  = r.top  + (window.scrollY || window.pageYOffset || 0);

    if (w === W && h === H) return false;
    W = w; H = h;

    /* Two device pixels is the whole benefit. A 3x backing store on a phone
       triples the fill cost for dots that are already sub-pixel-smooth. */
    var dpr = Math.min(2, window.devicePixelRatio || 1);
    cv.width  = Math.round(W * dpr);
    cv.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);   // everything below is in CSS px

    /* One dot beyond the edge on each side, so the grid doesn't visibly stop
       short of the window, and centred on whatever remainder is left over. */
    cols = Math.ceil(W / SPACING) + 2;
    rows = Math.ceil(H / SPACING) + 2;
    x0 = (W - (cols - 1) * SPACING) / 2;
    y0 = (H - (rows - 1) * SPACING) / 2;

    colU = new Float32Array(cols);
    colGain = new Float32Array(cols);
    rowV = new Float32Array(rows);
    for (var c = 0; c < cols; c++) {
      var u = (x0 + c * SPACING) / W;
      colU[c] = u;
      /* Smoothstep from the left edge to the right, so there is no seam where
         the quiet side stops being quiet. */
      var e = (u - LEFT_EDGE) / (RIGHT_EDGE - LEFT_EDGE);
      if (e < 0) e = 0; else if (e > 1) e = 1;
      colGain[c] = LEFT_GAIN + (1 - LEFT_GAIN) * (e * e * (3 - 2 * e));
    }
    for (var rw = 0; rw < rows; rw++) rowV[rw] = (y0 + rw * SPACING) / H;

    centres = [];
    for (var k = 0; k < RIBBONS.length; k++) centres.push(new Float32Array(cols));

    /* Every bucket gets room for every dot. It can't happen — a dot lands in
       exactly one bucket — but sizing them properly would mean counting twice a
       frame, and at a megabyte for a 4K window this is not the memory worth
       being clever about. */
    bucketXY = [];
    for (var b = 0; b < STEPS; b++) bucketXY.push(new Float32Array(cols * rows * 2));
    return true;
  }

  /* ---- the pointer ------------------------------------------------------
     The waves lean toward the cursor: within about a fifth of the width, each
     line is pulled roughly 40% of the way to wherever you are, so the ribbon
     bulges under the pointer and the crossings move. Smoothed at 7% a frame,
     which is slow enough that a flick of the mouse arrives as a swell rather
     than a jump.

     It starts at the middle of the hero and near the first ribbon's own height,
     so at rest — and on a touchscreen, where this never gets a value at all —
     the bend it contributes is almost nothing.
     -------------------------------------------------------------------- */
  var PULL = 0.42, REACH = 0.045, SMOOTH = 0.07;
  var pu = 0.5, pv = 0.42, tu = 0.5, tv = 0.42;

  function draw(t) {
    var k, c, rw, i, b;

    pu += (tu - pu) * SMOOTH;
    pv += (tv - pv) * SMOOTH;

    /* Wave heights, once per column. */
    for (k = 0; k < RIBBONS.length; k++) {
      var R = RIBBONS[k], out = centres[k];
      for (c = 0; c < cols; c++) {
        var u = colU[c];
        var y = R.base +
                R.a1 * Math.sin(TAU * (R.f1 * u + R.s1 * t)) +
                R.a2 * Math.sin(TAU * (R.f2 * u + R.s2 * t));
        var dx = u - pu;
        out[c] = y + (pv - y) * PULL * FALL[Math.min(LUT_N, (dx * dx / REACH * LUT_SCALE) | 0)];
      }
    }

    for (b = 0; b < STEPS; b++) bucketN[b] = 0;

    /* Sort every dot into a bucket by how strongly it is lit. */
    for (c = 0; c < cols; c++) {
      var px = x0 + c * SPACING;
      var cg = colGain[c];
      for (rw = 0; rw < rows; rw++) {
        var v = rowV[rw], f = 0;
        for (k = 0; k < RIBBONS.length; k++) {
          var Rk = RIBBONS[k];
          var d = v - centres[k][c];
          var q = d * d / (Rk.thick * Rk.thick);
          if (q < LUT_MAX) f += Rk.gain * FALL[(q * LUT_SCALE) | 0];
        }
        f *= cg;
        if (f < FLOOR) continue;
        if (f > 1) f = 1;
        b = (f * STEPS) | 0; if (b > STEPS - 1) b = STEPS - 1;
        var n = bucketN[b]++, arr = bucketXY[b];
        arr[n * 2] = px;
        arr[n * 2 + 1] = y0 + rw * SPACING;
      }
    }

    ctx.clearRect(0, 0, W, H);
    for (b = 0; b < STEPS; b++) {
      var count = bucketN[b];
      if (!count) continue;
      var pts = bucketXY[b], r = RADIUS[b];
      ctx.beginPath();
      for (i = 0; i < count; i++) {
        var ax = pts[i * 2], ay = pts[i * 2 + 1];
        /* moveTo to the arc's own start point, or each circle is joined to the
           last one by a stray line. */
        ctx.moveTo(ax + r, ay);
        ctx.arc(ax, ay, r, 0, TAU);
      }
      ctx.fillStyle = FILL[b];
      ctx.fill();
    }
  }

  /* ---- the loop --------------------------------------------------------- */
  var clock = 0, last = 0, frame = 0, onScreen = true;

  function tick(now) {
    frame = 0;
    /* Elapsed time, not frame count, so the drift runs at the same speed on a
       120Hz display — and clamped, so coming back from a paused tab doesn't
       fast-forward the ribbon through the seconds it was away. */
    var dt = last ? Math.min(0.05, (now - last) / 1000) : 0;
    last = now;
    clock += dt;
    draw(clock);
    if (running()) frame = requestAnimationFrame(tick);
  }

  /* A canvas that CSS has taken out of the layout measures 0x0. That is how the
     phone case is handled — `.ribbon` is `display:none` under 720px, and the
     answer here is to do nothing at all rather than animate a canvas nobody
     can see. It also covers rotating a tablet across the threshold, since the
     resize handler comes back through here. */
  function sized() { return W > 4 && H > 4; }

  function running() {
    return !still && sized() && onScreen && !document.hidden;
  }

  function start() {
    if (frame || !running()) return;
    last = 0;                       // next frame is the reference, not the last one before the pause
    frame = requestAnimationFrame(tick);
  }

  function stop() {
    if (!frame) return;
    cancelAnimationFrame(frame);
    frame = 0;
  }

  measure();

  /* The first frame is drawn here and now, not on the first animation frame.
     It costs a millisecond and it covers the case reveal.js had to grow a
     failsafe for: a page that loads in a background tab is not being rendered,
     so requestAnimationFrame never fires and an IntersectionObserver never
     reports anything. Without this the ribbon would be an empty canvas until
     something woke the loop up — which, on a tab opened in the background and
     then looked at, is a hero that visibly fills in. */
  if (sized()) draw(0);

  if (!still) {
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (entries) {
        onScreen = entries[entries.length - 1].isIntersecting;
        if (onScreen) start(); else stop();
      }).observe(cv);
    }
    document.addEventListener('visibilitychange', function () {
      if (document.hidden) stop(); else start();
    });
    window.addEventListener('pointermove', function (e) {
      /* Listened for on the window, because the canvas itself takes no
         pointer events — it sits under the headline and the download button,
         and it must not be the thing that gets clicked.

         Document coordinates against a cached canvas position, rather than
         reading the canvas's box on every move: this fires far more often than
         the screen refreshes, and measuring an element forces layout. */
      var w = W || 1, h = H || 1;
      tu = (e.pageX - docLeft) / w;
      tv = (e.pageY - docTop) / h;
      if (tu < -0.5) tu = -0.5; else if (tu > 1.5) tu = 1.5;
      if (tv < -0.5) tv = -0.5; else if (tv > 1.5) tv = 1.5;
    }, { passive: true });
    start();
  }

  var pending = 0;
  function relayout() {
    pending = 0;
    /* Setting a canvas's width or height clears it, so a resize always has to
       be followed by a draw — and it has to happen here rather than being left
       to the next animation frame, because there might not be one. Reduce
       Motion has no loop at all, and the loop that does exist is stopped
       whenever the hero is scrolled out of view or the tab is in the
       background. Any of those, plus a window resize, leaves an empty hero. */
    if (!measure()) return;
    if (sized()) draw(clock);
    start();                 // crossing back over the phone threshold restarts it
  }
  window.addEventListener('resize', function () {
    if (!pending) pending = requestAnimationFrame(relayout);
  }, { passive: true });
  /* The cached canvas position is in document coordinates, so a scroll doesn't
     invalidate it — but a reflow above the hero would, and this is the cheap
     way to catch that without measuring on every pointer move. */
  window.addEventListener('load', relayout);
})();
