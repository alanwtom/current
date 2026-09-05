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

There is no way around this. Unsigned, un-notarised apps show a dialog telling
the user the app is damaged and should be moved to the Trash. Most people stop
there, and the ones who don't have to be talked through right-click → Open.

- [ ] Enrol. Everything in Phase 1 is blocked on it.

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
- [ ] **Version numbering.** `Info.plist` is hardcoded to 1.0.0 build 1. The
      build should take the version from the git tag and the build number from
      something that always increases, or the updater in Phase 3 cannot tell
      two releases apart.

**Verified, not assumed.** A copy of the finished image carrying the
quarantine flag a browser attaches comes back from Gatekeeper as
`accepted — source=Notarized Developer ID`. Every build before this one was
`rejected`. The remaining unknown is a Mac that has never had Xcode or
Homebrew on it, which is still worth testing before anyone else downloads this.

## Phase 2 — Stop shipping switches that lie

Three settings are drawn, saved, and read by nothing. Found by checking every
setting against whether any code anywhere consumes it.

- [ ] **Automatic cleanup.** The switch does nothing. Cleanup only ever runs
      when triggered by hand, so the automatic half of a headline feature does
      not exist. Either wire it into the 15-second automation tick or take the
      switch out and stop advertising it.
- [ ] **Prevent sleep while downloading.** Does nothing. Needs a real power
      assertion held while transfers are active and released when they stop.
- [ ] **Storage budget notifications.** Never fire.
- [ ] **Re-run the sweep** after fixing these, and keep running it. A setting
      with no reader is invisible in review and obvious to a user.

## Phase 3 — Be able to fix things after release

- [ ] **Auto-update.** Sparkle is the standard. It needs an EdDSA key pair, an
      appcast feed hosted somewhere stable, and the private key kept somewhere
      safe — losing it means no existing install can ever be updated again.
      **Ship this in 1.0, not 1.1.** Without it, the first bad build is
      permanent for everyone who has already downloaded it.
- [ ] **A way to hear about crashes.** The privacy promise rules out telemetry,
      and it should stay ruled out. The honest version is a "Report a problem"
      item that opens a prefilled issue and tells the user exactly which file to
      attach.
- [ ] **Release automation.** Tag → build → sign → notarise → DMG → upload.
      Doing this by hand is how an unsigned or unstapled build gets published at
      midnight.

## Phase 4 — The open-source side of v1.0

The repository is already public and MIT licensed, so this is not "open
sourcing" — it is making the open part hold up. Two different audiences arrive
here and neither is served yet: someone deciding whether to download, and
someone deciding whether to build it.

- [ ] **Screenshots in the README.** The single highest-leverage item on this
      page. The whole pitch is that this doesn't look like a stock Mac utility,
      and there is currently no way to see that without compiling it. A
      design-led app with no screenshots reads as abandoned.
- [ ] **Third-party licence notices.** The bundle now redistributes libtorrent
      (BSD-3-Clause) and OpenSSL (Apache-2.0). Both require their notices to
      travel with a binary distribution. A `THIRD-PARTY-NOTICES.md` in the repo
      and a copy in the app bundle covers it. This became a real obligation the
      moment the bundling work made those libraries ship with the app, and it
      is cheap.
- [ ] **Make it buildable by someone who isn't you.** `Package.swift` hardcodes
      `/opt/homebrew`, so the build fails on an Intel Mac and anywhere Homebrew
      isn't at the default prefix. Read the prefix from `brew --prefix` or an
      environment variable and fall back to the current default. Right now the
      honest README line would be "builds on Apple Silicon with Homebrew at the
      default location", which is a small audience for contributors.
- [ ] **A README written for a person landing cold.** What it is, one
      screenshot, requirements stated plainly (Apple Silicon, macOS 26),
      download link, build instructions, licence. The current one opens with a
      philosophy paragraph and a feature list.
- [ ] **`SECURITY.md`.** This app parses untrusted files and talks to untrusted
      peers over the network. A stated disclosure route is basic hygiene for
      anything with a socket.
- [ ] **`CHANGELOG.md`**, starting at 1.0.0.
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

## A. The clean machine — do this first

The whole point of the bundling work, and the only test that proves it.

- [ ] A Mac that has **never had Homebrew or Xcode**. Download the DMG in a
      browser, drag to Applications, double-click.
- [ ] It opens **without** right-click → Open, without any "damaged" or
      "unidentified developer" dialog.
- [ ] Same, with **the Mac offline** on first launch. This is what proves the
      notarisation ticket was stapled.
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
