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

## If the app changes

The screenshots are `docs/images/*.png`, taken against `-simulate` so they are
reproducible. Recapture them there, copy them here, and update the SHA-256 on
the page — it is printed by `Scripts/release.sh` and the page states it as fact.
