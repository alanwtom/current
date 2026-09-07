/* Runs the website's background animation offscreen, so it can actually be
 * judged.
 *
 *     node Scripts/field-harness.mjs            # measure the rhythm
 *     node Scripts/field-harness.mjs --frames   # render PNGs to /tmp
 *
 * This exists because of how the background got shipped wrong the first time.
 * A canvas animation can only be checked by watching it, and the browser I was
 * checking it in renders on demand: it painted one frame every few seconds, so
 * every screenshot came back identical and a change that did nothing looked
 * exactly like a change that worked. I called a still image "not moving" and,
 * later, called a working one "static" — both from the same bad evidence.
 *
 * So: site/bg.js is run here against a fake canvas and a clock I control. Time
 * advances as fast as the CPU allows, eight minutes of animation take under a
 * second, and every square it tries to draw is recorded. `--frames` composites
 * those squares into real images (bmp, converted with sips) that can be looked
 * at directly.
 *
 * Nothing here is a copy of the animation — it drives the real file. If bg.js
 * changes, this measures the change.
 */
import fs from 'fs';
import path from 'path';
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SOURCE = path.join(ROOT, 'site', 'bg.js');
const WANT_FRAMES = process.argv.includes('--frames');

// The window it pretends to be, and where the hero's text sits inside it.
const W = 1440, H = 1188;
const TEXT = { left: 88, right: 660, top: 72, bottom: 430, width: 572 };

let clock = 0;
let frameDraws = [];
let draws = [];
let framePools = [];      // the light buffer's radial gradients, this frame
let pools = [];

const ctx = {
  _fill: 'rgba(0,0,0,0)',
  set fillStyle(v) { this._fill = v; },
  get fillStyle() { return this._fill; },
  setTransform() {}, clearRect() {}, beginPath() {}, drawImage() {},
  save() {}, restore() {},
  imageSmoothingEnabled: true, imageSmoothingQuality: 'high',
  createPattern: () => ({ __pattern: true }),
  createLinearGradient() { const g = { __linear: true }; g.addColorStop = () => {}; return g; },
  roundRect(x, y, w, h) { this._x = x; this._y = y; this._w = w; this._h = h; },
  fill() { record(this._x, this._y, this._w, this._h, this._fill); },
  fillRect(x, y, w, h) { record(x, y, w, h, this._fill); },
};

function record(x, y, w, h, style) {
  // the dither pass fills with a pattern, not a colour — nothing to record
  if (typeof style !== 'string' || style.indexOf('rgba') !== 0) return;
  const p = style.slice(5, -1).split(',').map(Number);
  frameDraws.push({ x, y, w, h, r: p[0], g: p[1], b: p[2], a: p[3] });
}

const canvas = {
  width: 0, height: 0,
  getContext: () => ctx,
  getBoundingClientRect: () => ({ width: W, height: H, left: 0, top: 0 }),
};

/* The offscreen buffer bg.js paints its pools into. Rather than rasterising
   it, the stub records each radial gradient — centre, radius, colour — which
   is exactly what's needed to measure whether the light moves, and lets the
   frame renderer composite the same pools at full resolution. */
function fakeBuffer() {
  let pending = null;
  const bctx = {
    canvas: null,
    globalCompositeOperation: 'source-over',
    set fillStyle(v) { this._fill = v; if (v && v.__radial) pending = v; },
    get fillStyle() { return this._fill; },
    clearRect() {}, setTransform() {}, putImageData() {},
    createImageData: (w, h) => ({ data: new Uint8ClampedArray(w * h * 4) }),
    createPattern: () => ({ __pattern: true }),
    createLinearGradient() {
      const g = { __linear: true, stops: [] };
      g.addColorStop = (o, c) => g.stops.push([o, c]);
      return g;
    },
    save() {}, restore() {},
    createRadialGradient(x0, y0, r0, x1, y1, r1) {
      const g = { __radial: true, x: x1, y: y1, r: r1, stops: [] };
      g.addColorStop = (o, c) => g.stops.push([o, c]);
      return g;
    },
    fillRect() {
      if (pending && pending.stops.length) {
        const m = pending.stops[0][1].match(/rgba\(([^)]+)\)/);
        if (m) {
          const [r, g, b, a] = m[1].split(',').map(Number);
          framePools.push({ x: pending.x, y: pending.y, rad: pending.r, r, g, b, a });
        }
        pending = null;
      }
    },
  };
  return { width: 0, height: 0, getContext: () => bctx };
}

let rafQueue = [];
global.document = {
  getElementById: id => (id === 'bg-field' ? canvas : null),
  querySelectorAll: () => [{ getBoundingClientRect: () => TEXT }],
  createElement: () => fakeBuffer(),
};
global.performance = { now: () => clock };
global.requestAnimationFrame = fn => { rafQueue.push(fn); return 1; };
global.cancelAnimationFrame = () => { rafQueue = []; };
global.setTimeout = () => 0;
global.clearTimeout = () => {};
global.CanvasRenderingContext2D = function () {};
/* Listeners bg.js registers, kept so the test can drive a pointer. */
const listeners = {};
const listen = (type, fn) => { (listeners[type] = listeners[type] || []).push(fn); };

global.window = {
  // motion allowed, and a fine pointer present so the pointer path is wired
  matchMedia: q => ({ matches: q.indexOf('hover') !== -1 }),
  devicePixelRatio: 1,
  performance: global.performance,
  addEventListener: listen,
  requestAnimationFrame: global.requestAnimationFrame,
};
global.document.addEventListener = listen;

function movePointer(x, y) {
  (listeners.pointermove || []).forEach(fn => fn({ clientX: x, clientY: y }));
}

eval(fs.readFileSync(SOURCE, 'utf8'));

/** Advances the animation by one frame. */
function step(ms = 16) {
  clock += ms;
  const due = rafQueue;
  rafQueue = [];
  frameDraws = [];
  framePools = [];
  due.forEach(fn => fn(clock));
  draws = frameDraws.slice();
  pools = framePools.slice();
}

const isBlue = d => d.b - d.r > 40;

/* "Lit" has to mean *brighter than this field's own resting level*, not
   brighter than some number I typed in. It was `alpha > 0.35`, and when the
   whole field was turned down — the flare going from 0.62 to 0.36 — that
   threshold sat above almost every piece and the harness reported a field with
   nothing happening in it and twelve-second dead stretches. The animation was
   fine; the ruler was wrong. */
const litCount = () => {
  if (!draws.length) return 0;
  const mean = draws.reduce((s, d) => s + d.a, 0) / draws.length;
  const bar = mean * 3.5;
  return draws.filter(d => d.a > bar).length;
};
/* Total alpha drawn inside the words' own box, and outside it, per unit area.
   The field runs under the text now, so the check is no longer "none there" —
   it is "far dimmer there", which is what protects legibility. */
function textVsRest() {
  let inside = 0, outside = 0, nIn = 0, nOut = 0;
  for (const d of draws) {
    const within = d.x < TEXT.right && d.x + d.w > TEXT.left
                && d.y < TEXT.bottom && d.y + d.h > TEXT.top;
    if (within) { inside += d.a; nIn++; } else { outside += d.a; nOut++; }
  }
  return { inside: nIn ? inside / nIn : 0, outside: nOut ? outside / nOut : 0 };
}

// --- measure -------------------------------------------------------------
step();
let dimmestBehindText = Infinity, brightestBehindText = 0;
let shadeSum = 0, shadeN = 0;

for (let i = 0; i < 2100; i++) step();      // let it settle, ~35s
const settled = draws.length;

let peakAlpha = 0, peakLit = 0, dead = 0, worstDead = 0;
let busy = 0, quiet = 0, sum = 0, textHits = 0;
let totalMin = Infinity, totalMax = 0;
const bothSides = { left: false, right: false };
const lightPath = [];                       // where the field's light sits

for (let i = 0; i < 3750; i++) {            // one minute, every frame
  step();
  const lit = litCount();

  // the alpha-weighted centre of the whole field, and its total brightness
  let wsum = 0, wx = 0, wy = 0;
  for (const d of draws) { wsum += d.a; wx += d.x * d.a; wy += d.y * d.a; }
  totalMin = Math.min(totalMin, wsum); totalMax = Math.max(totalMax, wsum);
  if (i % 125 === 0) lightPath.push([wx / wsum, wy / wsum]);
  sum += lit;
  peakLit = Math.max(peakLit, lit);
  peakAlpha = Math.max(peakAlpha, draws.reduce((m, d) => Math.max(m, d.a), 0));
  {
    const t = textVsRest();
    if (t.inside > 0) {
      const r = t.outside / t.inside;
      dimmestBehindText = Math.min(dimmestBehindText, r);
      shadeSum += r; shadeN++;
    }
  }
  for (const d of draws) {
    if (d.x < TEXT.right && d.x + d.w > TEXT.left && d.y < TEXT.bottom && d.y + d.h > TEXT.top)
      brightestBehindText = Math.max(brightestBehindText, d.a);
  }
  bothSides.left = bothSides.left || draws.some(d => d.x + d.w < TEXT.left);
  bothSides.right = bothSides.right || draws.some(d => d.x > TEXT.right);
  if (lit === 0) { dead += 16; worstDead = Math.max(worstDead, dead); } else dead = 0;
  if (lit > 12) busy++; else if (lit < 3) quiet++;
}

for (let i = 0; i < 26000; i++) step();     // out to roughly eight minutes
const late = draws.length;
const lateText = textVsRest();

console.log(`\nafter a minute of running:`);
console.log(`  pieces held           ${settled}`);
console.log(`  lit at once           mean ${(sum / 3750).toFixed(1)}, peak ${peakLit}`);
console.log(`  brightest piece       ${peakAlpha.toFixed(2)} alpha`);
console.log(`  busy frames           ${(100 * busy / 3750).toFixed(0)}%`);
console.log(`  quiet frames          ${(100 * quiet / 3750).toFixed(0)}%`);
console.log(`  longest dead stretch  ${(worstDead / 1000).toFixed(1)}s`);

let travel = 0, spanX = [Infinity, -Infinity], spanY = [Infinity, -Infinity];
for (let i = 1; i < lightPath.length; i++) travel += Math.hypot(lightPath[i][0]-lightPath[i-1][0], lightPath[i][1]-lightPath[i-1][1]);
for (const [x, y] of lightPath) {
  spanX = [Math.min(spanX[0], x), Math.max(spanX[1], x)];
  spanY = [Math.min(spanY[0], y), Math.max(spanY[1], y)];
}
console.log(`  centre of light       moves ${(spanX[1]-spanX[0]).toFixed(0)}px across, ${(spanY[1]-spanY[0]).toFixed(0)}px down, ${travel.toFixed(0)}px travelled`);
console.log(`  pieces on both sides  left ${bothSides.left}, right ${bothSides.right}`);
console.log(`  behind the words      ${(shadeSum / shadeN).toFixed(1)}x dimmer on average (${dimmestBehindText.toFixed(1)}x when a pool passes under it), brightest piece ${brightestBehindText.toFixed(2)} alpha`);
console.log(`  overall brightness    swings ${(100*(totalMax-totalMin)/totalMax).toFixed(0)}% between its dimmest and brightest`);
console.log(`  after eight minutes   ${late} pieces held\n`);

let failed = 0;
const check = (name, ok) => { if (!ok) failed++; console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}`); };

check('a landing piece is far brighter than a resting one', peakAlpha > 0.35);
check('it has a rhythm — busy moments and quiet ones', busy > 0 && quiet > 0);
check('the light drifts rather than sitting still', spanX[1] - spanX[0] > 30 || spanY[1] - spanY[0] > 30);
check('the field breathes', (totalMax - totalMin) / totalMax > 0.1);
check('never dead for longer than four seconds', worstDead < 4000);
// The minimum is not the test: it dips whenever a pool of light drifts under
// the text, which is the effect doing its job rather than a fault. What has to
// hold is that it is typically much dimmer there, and that no single piece
// behind the words ever gets bright enough to blink.
check('the field is typically far dimmer behind the words',
      shadeSum / shadeN > 2);
check('a piece flaring behind the words stays dim', brightestBehindText < 0.2);
check('the field is full bleed, not one column', bothSides.left && bothSides.right);
check('the field settles rather than filling solid', Math.abs(late - settled) / settled < 0.25);
check('still alive after eight minutes', late > 0);

// --- the pointer ---------------------------------------------------------
//
// Everything above runs with the pointer parked in the middle. These move it
// and check the field actually answers, which is the whole point of it.

function brightnessNear(x, y, radius) {
  let sum = 0;
  for (const d of draws) {
    if (Math.hypot(d.x - x, d.y - y) < radius) sum += d.a;
  }
  return sum;
}

const settle = n => { for (let i = 0; i < n; i++) step(); };

// Four spots the field actually reaches: outside the words, above the bottom
// fade. The pointer is parked on each in turn and the brightness at *every*
// spot is averaged over a stretch of frames, which gives a full matrix: each
// spot's brightness with the pointer on it, and its brightness on the
// occasions the pointer was somewhere else.
//
// Measuring one spot once was not enough. The pools drift through these
// positions on their own, so a single reading can be brighter for reasons that
// have nothing to do with the pointer — which is exactly what made the first
// version of this check fail on a field that was working.
const SPOTS = [[1150, 250], [420, 520], [1280, 560], [300, 200]];
const AVG_FRAMES = 40;

const grid = SPOTS.map(() => SPOTS.map(() => 0));
SPOTS.forEach((held, h) => {
  movePointer(held[0], held[1]);
  settle(150);
  for (let f = 0; f < AVG_FRAMES; f++) {
    step();
    SPOTS.forEach((at, a) => { grid[h][a] += brightnessNear(at[0], at[1], 140) / AVG_FRAMES; });
  }
});

const ratios = SPOTS.map((_, i) => {
  const on = grid[i][i];
  const off = SPOTS.reduce((sum, __, h) => h === i ? sum : sum + grid[h][i], 0) / (SPOTS.length - 1);
  return { on, off, ratio: on / off };
});

const poolsRight = (movePointer(1150, 250), settle(150), pools.map(p => p.x));
const poolsLeft = (movePointer(240, 520), settle(150), pools.map(p => p.x));

// how far each pool slid between those two pointer positions, and whether
// they slid by *different* amounts — sliding as one sheet would be no better
// than not sliding at all
const slides = poolsRight.map((x, i) => Math.abs(x - (poolsLeft[i] || 0)));
const slideSpread = Math.max(...slides) - Math.min(...slides);

console.log(`with a pointer:`);
ratios.forEach((r, i) => console.log(
  `  spot ${i + 1} at ${String(SPOTS[i]).padEnd(10)}  ${r.on.toFixed(1)} lit / ${r.off.toFixed(1)} unlit  =  ${r.ratio.toFixed(2)}x`));
console.log(`  pools slid            ${slides.map(v => Math.round(v)).join(', ')}px`);
console.log(`  spread between them   ${Math.round(slideSpread)}px\n`);

check('the pointer lights the field under it, wherever it goes',
      ratios.every(r => r.ratio > 1.4));
check('the pools are dragged by the pointer', Math.max(...slides) > 20);
check('and dragged by different amounts, so they slide over each other',
      slideSpread > 20);

// --- look at it ----------------------------------------------------------
if (WANT_FRAMES) {
  const CROP = 620;   // the part of the region the hero actually occupies
  const GLOW = 5;     // bg.js paints its light into a buffer this much smaller

  function save(name) {
    const px = Buffer.alloc(W * CROP * 3);
    // the ground, then the pools of light additively — the same ones bg.js
    // painted into its buffer this frame
    for (let y = 0; y < CROP; y++) {
      for (let x = 0; x < W; x++) {
        const i = (y * W + x) * 3;
        let r = 10, g = 10, b = 10;
        for (const p of pools) {
          const d = Math.hypot(x - p.x * GLOW, y - p.y * GLOW);
          const rad = p.rad * GLOW;
          if (d >= rad) continue;
          const f = (1 - d / rad) * p.a;
          r += p.r * f; g += p.g * f; b += p.b * f;
        }
        px[i] = Math.min(255, Math.round(r));
        px[i + 1] = Math.min(255, Math.round(g));
        px[i + 2] = Math.min(255, Math.round(b));
      }
    }
    for (const d of draws) {
      for (let y = Math.max(0, d.y | 0); y < Math.min(CROP, (d.y + d.h) | 0); y++) {
        for (let x = Math.max(0, d.x | 0); x < Math.min(W, (d.x + d.w) | 0); x++) {
          const i = (y * W + x) * 3;
          px[i] = Math.round(px[i] * (1 - d.a) + d.r * d.a);
          px[i + 1] = Math.round(px[i + 1] * (1 - d.a) + d.g * d.a);
          px[i + 2] = Math.round(px[i + 2] * (1 - d.a) + d.b * d.a);
        }
      }
    }

    const row = W * 3, pad = (4 - (row % 4)) % 4, size = 54 + (row + pad) * CROP;
    const bmp = Buffer.alloc(size);
    bmp.write('BM'); bmp.writeUInt32LE(size, 2); bmp.writeUInt32LE(54, 10);
    bmp.writeUInt32LE(40, 14); bmp.writeInt32LE(W, 18); bmp.writeInt32LE(-CROP, 22);
    bmp.writeUInt16LE(1, 26); bmp.writeUInt16LE(24, 28);
    for (let y = 0; y < CROP; y++) {
      for (let x = 0; x < W; x++) {
        const s = (y * W + x) * 3, t = 54 + y * (row + pad) + x * 3;
        bmp[t] = px[s + 2]; bmp[t + 1] = px[s + 1]; bmp[t + 2] = px[s];
      }
    }
    fs.writeFileSync(`/tmp/${name}.bmp`, bmp);
    execSync(`sips -s format png /tmp/${name}.bmp --out /tmp/${name}.png`, { stdio: 'ignore' });
    fs.unlinkSync(`/tmp/${name}.bmp`);
    console.log(`  /tmp/${name}.png`);
  }

  console.log('\nframes:');
  save('field-quiet');
  for (let i = 0; i < 4000 && draws.filter(isBlue).length <= 28; i++) step();
  save('field-burst');
  for (let i = 0; i < 25; i++) step();
  save('field-burst-fading');
}

process.exit(failed ? 1 : 0);
