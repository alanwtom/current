# Changelog

What changed in each release, in plain language. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The release script reads the section for a tag and uses it as that release's
notes, so this file is the single place release notes are written.

## [Unreleased]

## [1.2.0] — 2026-09-07

### Added

- **Help → Report a Problem…** Opens a bug report with the details already
  filled in — which version and build you're running, which macOS, which Mac.
  If Current has crashed in the last two weeks it also finds the crash report,
  reveals it in Finder and names it in the report, so attaching it is a drag
  rather than a hunt through a folder you've never opened.

  Still no telemetry, and there isn't going to be any. Nothing is sent unless
  you choose to file the report.

- **A laid-out install window.** Double-clicking the download now opens a
  window sized for the job, with the app on the left, the Applications folder on
  the right, and a blue current running between them — instead of two icons
  dropped in a default window at whatever size Finder felt like. It follows
  your Mac's light or dark appearance, because everything except the arrow is
  transparent.

- **Uninstall instructions**, on the download page and in the README. Three
  files stay behind when you drag Current to the Trash; now they're written
  down. Your downloads are never touched.

## [1.1.1] — 2026-09-06

### Fixed

- **Updates downloaded but never installed.** 1.1.0's updater checked, found a
  new version, downloaded it and verified it — then did nothing with it, ever.
  The update sat on disk while the app stayed on the old version, which from
  the outside is the same as having no updater at all.

  If you are on 1.1.0, this is the one release you have to install by hand.
  Every release after it will arrive on its own.

## [1.1.0] — 2026-09-06

### Added

- **Automatic updates.** Current can now tell you when a new version is out and
  install it. It asks once, on first launch, before it ever checks — and the
  switch is in Settings if you change your mind. Nothing is sent but a request
  for a version file.
- **Third-party licence notices**, in the repository and inside the app bundle,
  for the libraries Current redistributes.
- **A security policy** with a private route for reporting vulnerabilities.

### Changed

- Version numbers now come from the release tag rather than being hardcoded, so
  two builds can finally be told apart.
- The project builds on Intel Macs and non-default Homebrew prefixes.

### Fixed

- **Cancelling a magnet could delete files you already had.** Cancelling the
  "which files?" card removed the torrent with a flag that erases everything in
  its file list under the save folder — so re-adding a magnet for something
  already downloaded, then cancelling, deleted the copy you had. It no longer
  deletes anything.
- **Network features you had turned off were on at every launch.** Port
  mapping, NAT-PMP and local discovery were enabled when the session was
  created and only corrected once your settings were read, which meant a router
  mapping you never asked for and, briefly, LAN broadcasts you had disabled.
- **Your library was readable by other accounts on the Mac.** The database and
  its folder are now private to you.
- Torrent names from magnet links are length-limited and stripped of characters
  that can make a name display as something it isn't.

### Changed (interface)

- Every panel is on an 8pt grid now, and the type scale is four sizes rather
  than seven — three of the old steps sat within two points of each other,
  which reads as noise rather than hierarchy.

## [1.0.0] — 2026-09-06

First public release.

### Added

- Native macOS BitTorrent client built on libtorrent 2.1, drawing its own
  window chrome and every one of its own controls.
- **Magnet flow** — a magnet link raises one card asking what it is, how big,
  which files and where it goes, with the option to remember the location.
- **Smart Seed** — four plain-language policies, each explaining its decisions
  in words rather than a log line.
- **Smart Cleanup** — a storage budget that ranks completed downloads by how
  safely they can go, behind a strict gate, and only ever moves them to the
  Trash.
- **Swarm health in plain words**, and rare torrents excluded from automatic
  cleanup entirely.
- **A menu bar panel** with combined speeds, per-transfer progress and a pause
  button on each — the only surface available while the window is closed.
- Keyboard paths for every action, and a command palette.
- Signed with a Developer ID and notarised by Apple.

[Unreleased]: https://github.com/alanwtom/current/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/alanwtom/current/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/alanwtom/current/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/alanwtom/current/releases/tag/v1.0.0
