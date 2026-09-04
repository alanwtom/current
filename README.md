<div align="center">

# Current

**A torrent client that behaves.**

Native macOS · Swift 6 · SwiftUI · libtorrent 2.x · macOS 26+

</div>

---

Current is a native macOS BitTorrent client built around one insight:
**torrenting is mostly a background activity.** The most useful interface is
not a permanently-open dashboard — it's excellent background automation,
glanceable activity, and fast intervention when something needs you.

So Current is quiet when nothing is happening, informative when something is
happening, and delightful when you interact with it.

## Highlights

- **The magnet flow** — click a magnet link and a card at the top of the
  library acknowledges it ("Resolving magnet…"), grows into the file summary
  when metadata arrives, and hands off to live progress the moment you press
  **Download 8.3 GB**. One continuous interaction instead of three dialogs,
  and it happens in the window, where the library it's about already is.
- **Smart Seed** — four plain-language policies (Balanced, Helpful, Archive,
  Temporary). Helpful mode keeps rare torrents alive even after their
  goal is met. Every automated decision is explained in the Rules tab:
  *why did this happen?*
- **Smart Cleanup** — set a storage budget; Current ranks completed downloads
  by how safely they can go. Eligibility is a strict safety gate (complete +
  seed goals met + not pinned + not active + healthy swarm); ranking then puts
  old, large, inactive content first. Cleanup moves files to the **Trash** —
  always reversible, never destructive by default.
- **Swarm health in plain words** — "Only a few complete sources are available.
  Keeping this torrent seeded helps preserve it." Never shame, never nag.
- **Keyboard-first** — `⌘N` add magnet · `␣` pause/resume · `⌘⌫` remove ·
  `⌘F` search · `⌘K` command palette · arrows/⇧/⌘ for selection.
- **Menu bar panel** — click the icon and a panel drops under it with combined
  speeds, every active transfer's progress, and a pause button on each one.
  Everything you'd reach for without opening the app, and nothing else.
- **You choose where each download goes** — the confirm card offers a folder
  before anything starts, and remembers it if you say so. After that they go
  straight there, and the switch to start asking again is in Settings beside
  the folder itself.
- **Private by construction** — no accounts, no analytics, no tracking.
  Torrent history stays local.

## Building

Requirements: macOS 26+, Xcode 26+, Homebrew.

```sh
brew install libtorrent-rasterbar
swift build            # debug build
Scripts/make-app.sh    # produces .build/Current.app
open .build/Current.app
```

Run without touching real networks:

```sh
.build/debug/Current -simulate     # deterministic demo library
```

Tests:

```sh
swift test
```

## Project layout

| Path | What lives there |
| --- | --- |
| `Sources/CurrentCore` | Domain models, engine protocol, seeding policies, cleanup planner, file-tree logic — pure Swift, fully tested |
| `Sources/LTShim` | Thin C API over libtorrent 2.x |
| `Sources/CurrentEngine` | Swift actor wrapping the shim |
| `Sources/CurrentSim` | Deterministic simulation engine behind the same protocol |
| `Sources/CurrentApp` | SwiftUI/AppKit application |
| `docs/ARCHITECTURE.md` | How it all fits together |

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening pull requests.

## License

MIT — see [LICENSE](LICENSE).
