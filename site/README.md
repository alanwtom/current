# The download page

One static HTML file, no build step, no framework, no external requests — not
even a web font. `index.html` carries its own CSS and reuses the app's real
design tokens, so the site and the product look like the same object.

Live at **https://current.alantom.dev**.

## Deploying

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
