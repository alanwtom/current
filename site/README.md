# The download page

One static HTML file, no build step, no framework, no external requests — not
even a web font. `index.html` carries its own CSS and reuses the app's real
design tokens, so the site and the product look like the same object.

Live at **https://current.alantom.dev**.

## Deploying

**Do not connect this project to the GitHub repo in Vercel.** It was, briefly,
and it broke the site twice. Two separate reasons, and the second one is fatal:

1. Vercel's Root Directory defaults to the repo root, where there is no
   `index.html` — so every Git build deployed nothing and the domain served a
   404. Setting the root to `site` fixes that one.
2. **`Current.dmg` is not in git**, deliberately — it is a 9 MB build artifact
   that `Scripts/release.sh` regenerates. A build made from a GitHub checkout
   therefore cannot contain it, so the page ships with a download button that
   404s. No Root Directory setting fixes this.

The code lives in git as normal; it is only the *deploy* that has to come from
a local folder, because the folder has one file the repo does not.

A third, smaller reason: an app-only commit should not redeploy the website. On
a day of ordinary commits the Git link produced enough deployments to hit
Vercel's daily rate limit, after which every deploy came back `BLOCKED`.

If you ever do want push-to-deploy, the way to get it is to stop the site
serving the binary at all — point the download at the GitHub Release asset,
which already exists and carries the same file — and then a Git build has
nothing missing.



```bash
Scripts/release.sh            # rebuilds, signs, notarises, staples, makes the .dmg
cp .build/Current.dmg site/   # the download the page points at
cd site && vercel deploy --prod
```

`Current.dmg` is deliberately **not** in git — it is a 9 MB build artifact and
git history is forever. That is also why `.vercelignore` exists and is empty:
with no `.vercelignore`, Vercel falls back to `.gitignore`, which excludes the
disk image, and the page ships with a download button that 404s. It did exactly
that on the first deploy.

Two other things that cost time and are easy to hit again:

- **Deployment Protection.** The project defaulted to protecting every
  `vercel.app` URL behind Vercel SSO, so the page redirected to a login for
  anyone who wasn't Alan. It is set to `prod_deployment_urls_and_all_previews`
  now: the production URL is public, per-deployment and preview URLs stay
  private.
- **The address is `current.alantom.dev`**, a CNAME to `cname.vercel-dns.com`
  in Cloudflare with the proxy **off** — behind the orange cloud the TLS
  handshake with Vercel loops, and it looks exactly like a broken site. The
  certificate did not issue on its own and had to be ordered explicitly
  (`POST /v7/certs`) once DNS was answering.
- **`currentmac.vercel.app` 308-redirects here**, so links shared before the
  domain existed still work. It is claimed explicitly as a project domain
  because `current-mac.vercel.app` belongs to someone else, and without it
  Vercel falls back to `current-mac-alantomws-projects.vercel.app`.

## The interactive demo

The window in the hero is not a screenshot — it is a working replica built from
plain DOM (`demo.js`). Sections filter, search filters, rows select, pause
buttons pause, `+` raises the magnet card, and the meters tick. It is the same
approach Cursor's product page uses: real `<button>` elements inside a container
styled to look like a window.

Two things it must keep doing:

- **Fall back.** With JavaScript off it renders nothing, so a `<noscript>` block
  swaps in `library.webp` — the screenshot it is a live version of.
- **Stay out of the page's way.** Every class is prefixed `cd-` and every rule
  is scoped to `.cd-demo`. When it was first dropped in, one unscoped `body`
  rule from its standalone page centred the entire site.

`reveal.js` is separate from `demo.js` on purpose. They were briefly one file,
and a runtime fault in the demo stopped the reveal observer running, which left
every section below the hero at `opacity: 0` — a blank page. Separate files, and
a three-second failsafe in `reveal.js`, mean the text shows whatever happens.

## The hero's background

`ribbon.js` draws the dot field behind the headline: three slow waves running
left to right, with a grid of dots over them that answer with their size and
colour depending on how close they are to a wave. No dependency, no WebGL —
about a millisecond of Canvas 2D a frame.

It is the second attempt. The first was bursts of squares over drifting colour,
and it came out because it was the loudest thing on a page arguing that software
should be quiet. What keeps this one in: one hue family, a brightest dot that is
62% opaque and under 3px wide, twenty seconds for a full pass, and a mask that
ends it before the screenshot. If it ever starts feeling loud, the dial is the
colour ramp at the top of the file.

Four things it has to keep doing, each of which was a bug first:

- **Nothing on a phone.** Under 720px the hero's text runs wall to wall and
  there is no empty space for a background, so the dots landed in the words.
  `.ribbon` is `display:none` there and the script sees the zero-size canvas
  and never starts.
- **State the canvas height in CSS.** A canvas is a replaced element, so
  `height:auto` uses its own intrinsic aspect ratio and the `bottom` of an
  inset is ignored silently. It was 640px tall on a 511px hero, and since the
  script then matches its backing store to whatever it measured, the wrong size
  was self-consistent and looked intentional.
- **Draw after every resize.** Setting a canvas's width clears it, and there
  may be no next animation frame to redraw in — Reduce Motion has no loop, and
  the loop that exists stops when the hero scrolls away or the tab goes to the
  background.
- **Draw the first frame synchronously.** A page loaded in a background tab
  isn't rendered, so `requestAnimationFrame` never fires and an
  `IntersectionObserver` never reports anything — the same trap `reveal.js` has
  a failsafe for. Without it the hero visibly fills in when you switch to the
  tab.

Reduce Motion draws one frame and stops: no timer, and no pointer listener, so
there is nothing left that could move.

## Type and motion

Montserrat 500 with about -0.02em tracking for display, DM Sans for body, on a
near-black `#0a0a0a` ground — the app's own chrome colour is kept for the
window and the cards so they sit *on* the page rather than dissolve into it.
The entrance is a staggered rise-fade-unblur; sections repeat it on scroll.

## Assets

The three screenshots are served as **lossless WebP** — pixel-identical to the
PNGs and 57% smaller, which took the page from 1.5 MB to about 500 KB.
`library.png` stays on disk anyway because the Open Graph and Twitter tags point
at it: several link-preview crawlers still don't render WebP, and a blank share
card is worse than a file nobody downloads.

`icon.png` is 180x180, not the 1024x1024 original. It is drawn at 22px in the
header and 76px in the download card, and it was 425 KB — a quarter of the
page's weight, fetched ahead of the hero screenshot because it appears first in
the document.

```bash
cwebp -lossless -z 9 library.png -o library.webp
sips -Z 180 icon.png --out icon.png
```

## If the app changes

The screenshots are `docs/images/*.png`, taken against `-simulate` so they are
reproducible. Recapture them there, copy them here, and update the SHA-256 on
the page — it is printed by `Scripts/release.sh` and the page states it as fact.
