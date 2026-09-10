# Security policy

Current parses files it did not create, accepts links from any web page, and
talks to peers it has never met. That is the job, but it means the attack
surface is real and reports are welcome.

## Reporting a vulnerability

**Please do not open a public issue.**

Use GitHub's private reporting: **[Report a vulnerability][report]** on the
Security tab. It is private to the maintainer, and it gives us somewhere to talk
before anything is public.

[report]: https://github.com/alanwtom/current/security/advisories/new

If that isn't working for you, open a normal issue saying only that you have a
security report and how to reach you — no details — and we'll move it somewhere
private.

**What to expect.** This is a solo-maintained project, so: an acknowledgement
within a few days, an honest assessment of whether it's exploitable, and a fix
released as fast as it can be built, signed and notarised. If a report turns out
to be serious, credit in the advisory and the changelog unless you'd rather not.
There is no bug bounty.

## What's in scope

- **The app itself** — anything reachable from a magnet link, a `.torrent` file,
  a dropped or pasted URL, or a peer on the wire.
- **`Sources/LTShim`** — the C++ shim over libtorrent. It is the boundary
  between untrusted data and the app, and it is the code most worth your time.
- **The update channel** — the appcast, its signature checking, and anything
  that could cause the app to install something it shouldn't.
- **Distribution** — the disk image, its signature, its notarisation, and the
  download page at `current.alantom.dev`.

Particularly interested in: anything that writes outside the chosen save folder,
anything that deletes a file the user didn't ask to delete, and anything that
makes a network call the app doesn't document.

## What's out of scope

- **Vulnerabilities in libtorrent, OpenSSL or Boost themselves.** Report those
  upstream — they'll be fixed properly there and reach us in a release. If a
  known upstream flaw is exploitable *specifically because of how Current uses
  it*, that is in scope and we want to know.
- **That BitTorrent exposes your IP address to peers.** That is how the protocol
  works, not a flaw in this client. Current is not a privacy tool and does not
  claim to be one.
- **Findings from an automated scanner with no demonstrated impact.** A report
  needs to say what an attacker actually gets.
- **Anything about what a third party is hosting.** Current ships no trackers,
  no indexes and no content sources; it cannot search and does not host
  anything. See the scope note in the README.

## Supported versions

The most recent release gets fixes. Given the project's age that is currently
just `1.0.x`, and there is no long-term support branch.

**Please keep the app updated.** Current has a built-in updater, and it is
there for exactly this: a flaw found in libtorrent or OpenSSL is a flaw in every
copy already downloaded, and the updater is the only way to reach them.

## What the app does to reduce the surface

Stated plainly so a reviewer knows what to expect, and so a regression is
obvious:

- **Nothing the app removes on its own bypasses the Trash.** Automatic cleanup
  and automatic removal both go there. There is no automated path that unlinks.
- **The session starts with every outward-facing feature off** — port mapping,
  NAT-PMP and local discovery are enabled only after your settings are read, so
  a switch you turned off is never briefly on.
- **The library database is `0600` in a `0700` directory.** Your torrent history
  is not readable by other accounts on the machine.
- **Display names from magnets are length-bounded and stripped** of control
  characters and bidi overrides before they reach a view.
- **Trust is the bundled CA file, not the system's**, because the bundled
  OpenSSL's compiled-in path does not exist on a Mac without Homebrew — see
  `LibtorrentEngine.useBundledCertificates`.
- **The app is signed with a Developer ID, notarised, and stapled.** It ships
  with the hardened runtime and claims no entitlements.
- **Updates are signed with an EdDSA key and refused if the signature does
  not verify**, so control of the download page alone is not enough to ship
  anyone an update. The app makes no update request at all until the user
  has been asked.
