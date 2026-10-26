# Release audit — 25 October 2026

Status: source fixes are local. Release approval is still blocked by the final
artifact and device checks below. No release or website deployment was made.
A later [speed and motion pass](PERFORMANCE-AND-MOTION-2026-10-25.md) expands
the scope at the user's request. Visual style was excluded from this initial audit. Existing working-tree changes were
preserved.

## Fixed

- Deletion uses torrent metadata, checks file ownership and links, and keeps
  unrelated files and folders. Shared metadata files block deletion even when
  torrent names differ. Cleanup rechecks eligibility after an engine call and
  removes a record only after all expected content reaches the Trash.
- Damaged or unreadable settings block transfers until the user chooses a
  connection. The block survives a relaunch. The original damaged file is kept.
- Held downloads wait for approval. Request IDs stop an old add or folder move
  from taking a newer card. Cancel does not delete existing content.
- Folder moves await the engine's disk result. Failure keeps the old folder and
  leaves the download held. Duplicate adds keep the original folder.
- Metadata carries separate file paths, so a newline cannot split a path and
  shift file sizes. Transfer totals use saved lifetime counters.
- Engine sessions start without incoming or outgoing network access until the
  app applies the selected connection.
- Simulation uses an in-memory database and cannot load or save real library
  records or resume data. This also keeps saved VPN settings out of demos.
- The updater requires signed feeds and verifies the archive before extraction.
  Release scripts check the live version and build, check signing keys, verify
  the feed signature, and stamp website metadata from the release file.
- Website copy states the system requirements and the limits of torrent privacy,
  DNS confinement, update requests, and automatic cleanup. The download metadata
  matches the verified live 1.3.0 build 104 file. This is the old release; it does
  not contain these new fixes.

## Checks

Logs are in `.build/release-audit/`.

- Full offline suite: 340 tests, seven skipped, no failures on the final
  source. See `tests-final.log`.
- Release script checks: seven offline tests pass; shell syntax and plist pass.
- Cyclomatic complexity: no violations, strict limit 10.
- Release bundle builds and passes strict recursive code signature validation.
  It is locally signed for testing and still stamps the local tag 1.2.0 (97).
  It is not a distributable release.
- Command palette focus was fixed after a compact-window test showed typing
  reached the library search. The rebuilt palette and add-link field now take
  focus. Settings opens by keyboard at compact size.
- Window soak: 193 seconds with active simulated transfers and a completion
  into seeding. Compact and expanded layouts worked. Keyboard commands still
  worked at the end. No new Current crash reports. See `soak-result.json`.

## Required before release

1. Review and commit the accumulated changes. Choose a new version above 1.3.0
   and a build above 104. The local commit count is 97, so set
   `CURRENT_BUILD_VERSION` explicitly or use a later valid count.
2. Build and notarize the final tagged artifact. Verify its stapled ticket and
   Gatekeeper result. Run the signed updater end to end, including rejection of
   a changed feed and a changed archive. The current live feed is unsigned;
   deploy the new signed feed with the new app.
3. Test the final bundle on a clean second Mac. Check first-run prompts and an
   upgrade from the live app with a saved library.
4. Check cold-launch magnet delivery, a real VPN disconnect and reconnect, DNS
   behavior, sleep and wake, disk-full errors, keyboard file selection, VoiceOver,
   and an overnight transfer on that final bundle.
5. Deploy the website and matching download/feed together only after those
   gates pass. Update the Homebrew cask from the same artifact.

## Known limits

DNS uses the macOS resolver and is not confined to the chosen device. Literal
local targets are filtered, but hostnames that resolve to local addresses are
not fully covered. Do not claim anonymity or a system-wide kill switch.
Path checks cannot stop another local process from replacing a path between a
check and the Trash operation. Tests never use the real Trash.

## Sources

The owning code, tests, live appcast, and downloaded release file were checked.
Update requirements were checked against
[Sparkle documentation](https://sparkle-project.org/documentation/).
Old checked items in `docs/RELEASE.md` are historical evidence, not validation
of this working tree or the next release artifact.
