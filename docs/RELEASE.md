# Releasing Current

Direct download, not the Mac App Store. That decision is made and it shapes
everything here: nobody reviews the app, so nothing blocks a bad build but us —
and nobody pushes updates for us either, so shipping without a way to update is
shipping a bug you can never take back.

This is the runbook and the state of it. Tick things off as they land.

---

## Decisions to make before the work starts

### 1. How old a Mac should this run on?

**The app declares macOS 26 and only needs macOS 14.** That was measured, not
guessed: it compiles clean targeting 14, and fails on 13 with 155 errors from
SwiftUI APIs that arrived in 14 (`onChange(of:initial:)`, `focusEffectDisabled`,
`TransitionPhase`).

macOS 26 shipped this year. Requiring it means most Macs in the world cannot run
this, for no benefit anyone can point at. Dropping the floor to 14 is a one-line
change in `Package.swift` and one in `Scripts/Info.plist`.

The cost is honest: **compiling for 14 is not the same as running on 14.** It
would need testing on a real Sonoma machine, and the window chrome and the menu
bar panel are the two places most likely to behave differently.

- [ ] Decide the floor. Recommendation: **macOS 14**, with a Sonoma test pass.

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
- [ ] **Developer ID certificate.** Create a *Developer ID Application*
      certificate. Not "Mac App Distribution" — that one is for the App Store
      and will not work here.
- [ ] **Hardened runtime.** Required for notarisation. Sign every bundled
      library first, then the app, with `--options runtime --timestamp`. The
      libraries are signed with the same identity, so library validation should
      not need disabling — if notarisation complains, that is the thing to look
      at first.
- [ ] **Notarise and staple.** `notarytool submit --wait`, then `stapler
      staple`. Stapling matters: without it, a Mac that is offline on first
      launch cannot verify the app and refuses to open it.
- [ ] **Package as a DMG** with the app and a shortcut to Applications, so the
      install is a drag. Running the app from inside the DMG is a classic
      support problem; the window layout should make it obvious not to.
- [ ] **Version numbering.** `Info.plist` is hardcoded to 1.0.0 build 1. The
      build should take the version from the git tag and the build number from
      something that always increases, or the updater in Phase 3 cannot tell
      two releases apart.

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

## Phase 4 — What people see before they download

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
