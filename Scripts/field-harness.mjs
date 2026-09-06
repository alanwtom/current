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

const ctx = {
  _fill: 'rgba(0,0,0,0)',
  set fillStyle(v) { this._fill = v; },
  get fillStyle() { return this._fill; },
  setTransform() {}, clearRect() {}, beginPath() {},
  roundRect(x, y, w, h) { this._x = x; this._y = y; this._w = w; this._h = h; },
  fill() { record(this._x, this._y, this._w, this._h, this._fill); },
  fillRect(x, y, w, h) { record(x, y, w, h, this._fill); },
};

function record(x, y, w, h, style) {
  const p = style.slice(5, -1).split(',').map(Number);
  frameDraws.push({ x, y, w, h, r: p[0], g: p[1], b: p[2], a: p[3] });
}

const canvas = {
  width: 0, height: 0,
  getContext: () => ctx,
  getBoundingClientRect: () => ({ width: W, height: H, left: 0, top: 0 }),
};

let rafQueue = [];
global.document = {
  getElementById: id => (id === 'bg-field' ? canvas : null),
  querySelectorAll: () => [{ getBoundingClientRect: () => TEXT }],
};
global.performance = { now: () => clock };
global.requestAnimationFrame = fn => { rafQueue.push(fn); return 1; };
global.cancelAnimationFrame = () => { rafQueue = []; };
global.setTimeout = () => 0;
global.clearTimeout = () => {};
global.CanvasRenderingContext2D = function () {};
global.window = {
  matchMedia: () => ({ matches: false }),   // motion allowed, no pointer
  devicePixelRatio: 1,
  performance: global.performance,
  addEventListener: () => {},
  requestAnimationFrame: global.requestAnimationFrame,
};

eval(fs.readFileSync(SOURCE, 'utf8'));

/** Advances the animation by one frame. */
function step(ms = 16) {
  clock += ms;
  const due = rafQueue;
  rafQueue = [];
  frameDraws = [];
  due.forEach(fn => fn(clock));
  draws = frameDraws.slice();
}

const isBlue = d => d.b - d.r > 40;
const isLanding = d => d.a > 0.35;
const overText = () => draws.filter(
  d => d.x < TEXT.right && d.x + d.w > TEXT.left
    && d.y < TEXT.bottom && d.y + d.h > TEXT.top
).length;

// --- measure -------------------------------------------------------------
step();
const startedOverText = overText();

for (let i = 0; i < 2100; i++) step();      // let it settle, ~35s
const settled = draws.length;

let peakAlpha = 0, peakLit = 0, dead = 0, worstDead = 0;
let busy = 0, quiet = 0, sum = 0, textHits = 0;
let totalMin = Infinity, totalMax = 0;
const lightPath = [];                       // where the field's light sits

for (let i = 0; i < 3750; i++) {            // one minute, every frame
  step();
  const lit = draws.filter(isLanding).length;

  // the alpha-weighted centre of the whole field, and its total brightness
  let wsum = 0, wx = 0, wy = 0;
  for (const d of draws) { wsum += d.a; wx += d.x * d.a; wy += d.y * d.a; }
  totalMin = Math.min(totalMin, wsum); totalMax = Math.max(totalMax, wsum);
  if (i % 125 === 0) lightPath.push([wx / wsum, wy / wsum]);
  sum += lit;
  peakLit = Math.max(peakLit, lit);
  peakAlpha = Math.max(peakAlpha, draws.reduce((m, d) => Math.max(m, d.a), 0));
  textHits += overText();
  if (lit === 0) { dead += 16; worstDead = Math.max(worstDead, dead); } else dead = 0;
  if (lit > 12) busy++; else if (lit < 3) quiet++;
}

for (let i = 0; i < 26000; i++) step();     // out to roughly eight minutes
const late = draws.length;
const lateOverText = overText();

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
console.log(`  overall brightness    swings ${(100*(totalMax-totalMin)/totalMax).toFixed(0)}% between its dimmest and brightest`);
console.log(`  after eight minutes   ${late} pieces held\n`);

let failed = 0;
const check = (name, ok) => { if (!ok) failed++; console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}`); };

check('a landing piece is far brighter than a resting one', peakAlpha > 0.35);
check('it has a rhythm — busy moments and quiet ones', busy > 0 && quiet > 0);
check('the light drifts rather than sitting still', spanX[1] - spanX[0] > 30 || spanY[1] - spanY[0] > 30);
check('the field breathes', (totalMax - totalMin) / totalMax > 0.1);
check('never dead for longer than four seconds', worstDead < 4000);
check('nothing is ever drawn over the headline',
      startedOverText === 0 && textHits === 0 && lateOverText === 0);
check('the field settles rather than filling solid', Math.abs(late - settled) / settled < 0.25);
check('still alive after eight minutes', late > 0);

// --- look at it ----------------------------------------------------------
if (WANT_FRAMES) {
  const CROP = 620;   // the part of the region the hero actually occupies

  function save(name) {
    const px = Buffer.alloc(W * CROP * 3);
    for (let y = 0; y < CROP; y++) {
      for (let x = 0; x < W; x++) {
        // ground plus the CSS wash, roughly — enough to judge contrast against
        const dx = (x - W * 0.30) / (W * 0.62), dy = (y - CROP * 0.08) / CROP;
        const wash = Math.max(0, 1 - Math.min(1, Math.hypot(dx, dy))) * 0.16;
        const i = (y * W + x) * 3;
        px[i] = Math.round(10 + 63 * wash);
        px[i + 1] = Math.round(10 + 169 * wash);
        px[i + 2] = Math.round(10 + 255 * wash);
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
