# Releasing Current

Direct download, not the Mac App Store. That decision is made and it shapes
everything here: nobody reviews the app, so nothing blocks a bad build but us —
and nobody pushes updates for us either, so shipping without a way to update is
shipping a bug you can never take back.

This is the runbook and the state of it. Tick things off as they land.

---

## Decisions to make before the work starts

### 1. How old a Mac should this run on?

**Decided: macOS 26, for now.**

Worth writing down what that costs, because the option stays open. The app
*builds* clean targeting macOS 14 — measured, not guessed: zero errors at 14,
and 155 at 13 from SwiftUI APIs that arrived in 14 (`onChange(of:initial:)`,
`focusEffectDisabled`, `TransitionPhase`). So nothing in the code requires 26.

macOS 26 shipped this year, so the floor is the audience limit: early adopters
only. That is a defensible place to start a v1 — fewer OS versions to test
against, and the newest platform behaviour to rely on — and it is reversible
later at the cost of a real test pass on the older OS. Revisit when there is a
reason to want the reach.

### 2. Apple Silicon only?

The build is arm64. Universal would mean building libtorrent *and* OpenSSL for
Intel too, which is real work for a shrinking audience.

- [ ] Decide. Recommendation: **Apple Silicon only**, stated plainly on the
      download page so nobody wastes a download.

### 3. Apple Developer Program — $99/year

**Already have it.** Team 8JG887CZZ6. This was a non-question that looked like
a blocker for a while: the account existed the whole time, and what was
actually missing was one certificate type.

### 4. Where the download lives

GitHub Releases is free, handles large files, and gives a stable URL for the
update feed to point at.

- [ ] Decide. Recommendation: **GitHub Releases**, with a simple landing page.

---

## Phase 1 — Make it installable

Nothing here is optional; this is the difference between a build and a product.

- [x] **Self-contained bundle.** Done. Every library the app needs travels
      inside it, and the build fails if that ever stops being true.
- [x] **Developer ID certificate.** Done — a Developer ID Application G2
      certificate for team 8JG887CZZ6, valid to 2031. Not "Apple Distribution",
      which is the App Store one and does not work here; that confusion cost an
      afternoon.
- [x] **Hardened runtime.** Done in `Scripts/release.sh`. Libraries are signed
      before the bundle; the reverse invalidates the outer signature and shows
      up later as a confusing notary rejection. Library validation needed no
      disabling — the bundled libraries carry the same team identity.
- [x] **Notarise and staple.** Done, for the app *and* the disk image — a
      stapled app inside an unnotarised image still warns on the download,
      which is the first thing anyone sees. Credentials live in a keychain
      profile, never in the repo.
- [x] **Package as a DMG** with an Applications symlink so the install is a
      drag. Not yet done: a background image and window layout that make it
      obvious not to run the app from inside the image.
- [x] **Version numbering.** Done. `Scripts/make-app.sh` stamps the marketing
      version from `git describe --tags` and the build number from the commit
      count. An untagged checkout gets `0.0.0-dev`, which is deliberately
      obvious so a fallback can never be mistaken for a release.

**Verified, not assumed.** A copy of the finished image carrying the
quarantine flag a browser attaches comes back from Gatekeeper as
`accepted — source=Notarized Developer ID`. Every build before this one was
`rejected`. The remaining unknown is a Mac that has never had Xcode or
Homebrew on it, which is still worth testing before anyone else downloads this.

## Phase 2 — Stop shipping switches that lie

Done. Four, in the end, not three — the sweep that found the first three found
a fourth of the same kind.

- [x] **Automatic cleanup**, now on the automation tick and only with a budget
      set. "No budget" means "everything eligible" to the manual command, which
      is right when a person asked and catastrophic on a timer.
- [x] **Prevent sleep while downloading**, now a real idle-sleep assertion,
      confirmed with `pmset` in both directions. It deliberately doesn't fight
      the lid.
- [x] **Storage budget notifications**, now fired only when the app can't fix
      the problem itself, once per crossing.
- [x] **Default seed policy** — the picker saved your choice and every torrent
      came out Balanced regardless.
- [x] **The sweep is worth re-running** after any settings change. It is a
      one-liner: every setting, checked against whether anything outside the
      settings pane reads it.

## Phase 3 — Be able to fix things after release

- [x] **Auto-update.** Done, and deliberately unlike a stock Sparkle
      integration. Sparkle's engine is used; its interface is not — its windows
      are stock Mac chrome, which is the one thing this app is built to avoid,
      and they would be the only system UI it ever showed.
      `Sources/CurrentApp/Updates/UpdateController.swift` implements
      `SPUUserDriver` so the entire visible surface is one toast: *An update is
      ready — Relaunch*. A background check that finds nothing, or fails, is
      silent; only a check the user started from the menu talks back.

      **It asks before it ever checks.** A card on first launch, stored as two
      settings so "not asked" and "said no" are told apart. Until answered the
      app makes no update request at all, which is what keeps the claim on the
      download page true.

      The private EdDSA key is in the login keychain and **must be backed up**.
      Losing it means no existing install can ever be updated again. The public
      half is `SUPublicEDKey` in `Scripts/Info.plist`; the feed is
      `https://current.alantom.dev/appcast.xml`.

      Two things that bite when touching this:

      - **Sparkle is a framework, and it signs from the inside out.** Two XPC
        services, a helper app and a standalone `Autoupdate` binary each sign as
        their own unit. `codesign --deep` claims to handle this and is
        unsupported for submission. Get the order wrong and everything looks
        fine locally, then notarisation rejects the build with a message about a
        nested component — a long way from the cause. `Scripts/release.sh` does
        it in the right order.
      - **`make-app.sh` uses `ditto`, not `cp -R`,** to bring the framework in.
        A versioned framework is symlinks and its own signature, and flattening
        either produces a bundle that passes a casual look and fails
        notarisation.
- [ ] **A way to hear about crashes.** The privacy promise rules out telemetry,
      and it should stay ruled out. The honest version is a "Report a problem"
      item that opens a prefilled issue and tells the user exactly which file to
      attach.
- [x] **Release automation.** `Scripts/release.sh` refuses to run on a dirty
      tree or an untagged HEAD, then builds, signs (including Sparkle's nested
      binaries), notarises, staples, packages, notarises the image, signs the
      appcast with the EdDSA key, and stages both the image and the feed into
      `site/`. It stops one step short on purpose: the two commands that
      actually publish — the site deploy and `gh release create` — are printed
      for you to run, because a script that publishes as a side effect of being
      run is how a half-finished release goes out.

      Release notes come from `CHANGELOG.md` via `Scripts/changelog-section.py`,
      so the changelog and the release can't disagree, and a version with no
      changelog section fails the release rather than shipping empty notes.

## Phase 4 — The open-source side of v1.0

The repository is already public and MIT licensed, so this is not "open
sourcing" — it is making the open part hold up. Two different audiences arrive
here and neither is served yet: someone deciding whether to download, and
someone deciding whether to build it.

- [x] **Screenshots in the README.** Three, taken against `-simulate` so they
      can be reproduced: the library, the card a magnet raises, the menu bar
      panel.
- [x] **Third-party licence notices.** Done, and generated rather than written:
      `Scripts/make-notices.sh` reads the licences Homebrew actually installed,
      with versions and SPDX identifiers, so the file cannot quietly go stale
      when a dependency moves. It lands in the repo and inside
      `Contents/Resources`, since the obligation attaches to the binary.
- [x] **Make it buildable by someone who isn't you.** `Package.swift` and
      `make-app.sh` both resolve the prefix now: `CURRENT_BREW_PREFIX` if set,
      else whichever of `/opt/homebrew` and `/usr/local` actually has
      libtorrent's headers. They used to disagree, which would have compiled on
      a non-default prefix and then failed at the CA bundle.
- [ ] **A README written for a person landing cold.** Screenshots and the
      Apple Silicon requirement are in. Still missing: a download link, and an
      opening that leads with what the app is rather than a philosophy
      paragraph.
- [x] **`SECURITY.md`.** Done, with GitHub private vulnerability reporting
      enabled so the route is a button rather than an address. Secret scanning
      and push protection are on too — there is a signing key in play now.
- [x] **`CHANGELOG.md`**, starting at 1.0.0, and read by the release script.
- [ ] **Tag `v1.0.0`** and cut a GitHub Release with the DMG and its checksum.
      Nothing before the tag is a version; it's just `main`.
- [ ] **Land or drop the in-flight swarm-health work** before tagging. A
      half-finished feature sitting uncommitted at tag time is the kind of thing
      that gets committed in a hurry and breaks the release build.
- [ ] `CODE_OF_CONDUCT.md` and a PR template. Conventional, quick, and GitHub
      asks for them.

### Saying what this is

Worth stating plainly on the README, because it is true and it is not true of
every client: **Current ships no trackers, no indexes, and no content sources.**
It has no search, it cannot find anything, and it does not suggest anything to
download. It is a client for a protocol that people use lawfully every day —
Linux images, Internet Archive collections, scientific datasets, game patches.

That is a positioning decision as much as a factual one, and it matters beyond
tone: hosting providers, package managers, press, and anyone deciding whether
to link to the project all read it. The seeding defaults say the same thing —
giving back a full share before stopping is what a good citizen of a swarm
does, and it is worth being explicit that the app is built that way on purpose.

None of this is legal advice, and none of it changes what a user does with the
app. It changes what the project looks like to someone deciding whether to
trust it.

## Phase 5 — What people see before they download

- [ ] Landing page or a README that opens with screenshots.
- [ ] Release notes.
- [ ] Say plainly: Apple Silicon, minimum macOS, and that it is a BitTorrent
      client — people should know what they are installing.
- [ ] Uninstall instructions. The app leaves a database and DHT state in
      `~/Library/Application Support/Current`, and dragging the app to the Trash
      does not remove them.

---

# Test plan

Run against a **release** build — signed, notarised, stapled, installed from the
DMG. Not `swift run`, and not the debug bundle. Several of the things most
likely to be broken only exist in that path.

## A. The clean machine

The whole point of the bundling work. A second Mac is still the only thing that
*proves* it, but most of what that Mac would tell us has now been established
another way, against the disk image downloaded from the live site — not a local
build.

**Established, on the shipped artifact:**

- [x] **Nothing outside the bundle is linked.** All four Mach-O binaries walked
      recursively, resolving `@rpath`/`@loader_path`/`@executable_path`: every
      dependency lands inside `Current.app` or in `/usr/lib` / `/System`.
- [x] **Nothing outside the bundle is opened at runtime.** The app was run under
      `sandbox-exec` with `/opt/homebrew` and `/usr/local/{Cellar,opt}` denied.
      The **real libtorrent engine** — not `-simulate` — loaded all three
      bundled dylibs and ran with **zero** Homebrew files open.
- [x] **The OpenSSL trust store is the one we ship.** This was the live hazard:
      `libcrypto`'s compiled-in `OPENSSLDIR` is `/opt/homebrew/etc/openssl@3`,
      so on a clean Mac its default trust store is *empty* — and the failure is
      silent, because HTTPS tracker announces just fail verification and magnets
      fall back to the DHT. `LibtorrentEngine.init` sets `SSL_CERT_FILE` to the
      bundled `cacert.pem` as its first statement, before the session exists.
      That bundle holds 192 certificates, none expired, and on its own verifies
      `tracker.opentrackr.org`, `torrent.ubuntu.com` and `archive.org`.
- [x] **Gatekeeper accepts a browser download.** The `.dmg` was given a real
      Safari quarantine attribute; both it and the app extracted from it assess
      as `accepted — source=Notarized Developer ID`. The ticket is stapled, so
      it opens with no network. The quarantined copy launches and draws its
      window; no crash reports.

**Still genuinely untested, and a second Mac is the only way:**

- [ ] A different machine — a different macOS build, different hardware, and a
      user account with no `~/Library/Application Support/Current` already in
      it. Everything above ran on the machine that built the app.
- [ ] First-run system permission prompts on an account that has never granted
      them to this app.
- [ ] If the floor drops to macOS 14: the whole pass again on Sonoma, paying
      attention to the window chrome and the menu bar panel.

## B. The real network — never been tested

Everything so far has run against the simulator. This is the biggest unknown in
the whole project.

- [ ] A large real torrent (a Linux ISO) start to finish, and **verify the
      checksum**. Downloading is not the same as downloading correctly.
- [ ] A torrent whose trackers are **HTTPS**. This is what the certificate
      bundling fixed and it has never been exercised — if announces fail, this
      is where it shows.
- [ ] A magnet whose trackers are all dead, so it must resolve over DHT alone.
- [ ] The first magnet **after a cold launch**, which is the case the persisted
      DHT routing table exists for.
- [ ] Quit mid-download, reopen: it resumes where it left off, in the same
      folder, without re-downloading.
- [ ] Leave something **seeding overnight**. Ratio climbs, the app is still
      alive and responsive in the morning.
- [ ] A torrent with **hundreds of files** — the picker should stay usable.
- [ ] Pull the network out mid-download and put it back.
- [ ] Fill the disk during a download and see what it says.

## C. The paths outside the app

- [ ] Click a magnet link in a browser with the app **closed**. It launches,
      opens a window, and starts the flow. This path has broken before.
- [ ] Click a magnet link with the app **open**, and with the window closed but
      the app running in the menu bar.
- [ ] `MAGNET:` in capitals.
- [ ] Double-click a `.torrent` in Finder; drag one onto the window; drag one
      onto an empty library.
- [ ] Open ten `.torrent` files at once — the first should ask where to save,
      the rest go to the default without ten dialogs.

## D. The features that make decisions

- [ ] Choose a folder for a download and confirm the files actually land there,
      not in the default.
- [ ] "Remember this location" makes it the default **and** stops the asking;
      Settings turns the question back on.
- [ ] Cleanup moves files to the **Trash** and they restore intact. Nothing is
      ever unlinked.
- [ ] A seed policy actually stops seeding when its goal is met, and the Rules
      tab explains why in words.
- [ ] Speed limits actually limit — measure it, don't trust the label.
- [ ] Unplug the charger: battery behaviour does what the switch claims.
- [ ] Whatever survives Phase 2, verify it does the thing it says.

## E. Stability

The failure mode this app has died from twice is a layout loop that takes
10–35 seconds to appear, so short smoke tests prove nothing.

- [ ] Three-minute soak with real transfers running, dragging the window across
      every width, checking `~/Library/Logs/DiagnosticReports/` after.
- [ ] Sleep the Mac with transfers running; wake it.
- [ ] Leave it running a full day.
- [ ] Open and close the menu bar panel repeatedly while transfers move.

## F. System integration and accessibility

- [ ] Light mode. The app was designed dark-first and light gets less use.
- [ ] Reduce Motion on — animations degrade, nothing breaks.
- [ ] Reduce Transparency on — this disables the window blur and has been
      mistaken for a bug before.
- [ ] A second display, and the menu bar panel opened from it.
- [ ] A Mac **with** a camera housing and one **without** — the panel positions
      itself relative to the menu bar icon either way.
- [ ] Keyboard only, no mouse: add a magnet, pick files, confirm, pause, remove.
- [ ] VoiceOver over the library and the menu bar panel.
- [ ] Close the window, confirm the app keeps running and reopens from the menu
      bar.

## G. Install and uninstall

- [ ] Install over an existing older version; settings and library survive.
- [ ] Drag to Trash, then reinstall: does it come back clean or confused?
- [ ] Know exactly what is left behind, and say so on the site.
