# Current — agent guide

Single source of truth for AI coding agents (Claude Code, Codex, etc.).
`CLAUDE.md` is a stub that points here — edit this file, not that one.

Native macOS BitTorrent client. Swift 6, SwiftUI + AppKit, libtorrent 2.x,
macOS 26+. The premise: **torrenting is a background activity**, so the app is
quiet when idle, informative when active, and reversible when it acts on its own.

## Build

This is a **Swift Package**, not an Xcode project — there is no `.xcodeproj`.
libtorrent is a hard system dependency and `Package.swift` hardcodes Homebrew's
Apple Silicon paths (`/opt/homebrew/{include,lib}`), so an Intel Mac needs
`Package.swift` edits before anything compiles.

```bash
brew install libtorrent-rasterbar
swift build                 # debug
swift test                  # 35 tests, all in CurrentCore + CurrentSim
Scripts/make-app.sh         # bundles .build/Current.app (add --release for release)
open .build/Current.app
```

`Scripts/make-app.sh` and `.github/workflows/ci.yml` both hardcode
`.build/arm64-apple-macosx/<config>/Current`. If you change the build triple,
change it in both places.

**Run against the simulator, not the network:**

```bash
.build/debug/Current -simulate
```

`-simulate` swaps in `SimulationEngine` — deterministic, no peers, no disk churn.
Use it for every UI change, screenshot, and demo. The real libtorrent path has no
automated coverage and is only ever exercised by hand.

Tests are **XCTest**, not Swift Testing. (Kuma uses Swift Testing; don't carry the
habit across.)

## Architecture rules

**`CurrentCore` is pure and stays pure.** No AppKit, no SwiftUI, no I/O — only
deterministic value types and functions. It is the one part of the app with fast
feedback, and every addition to it needs tests. `docs/ARCHITECTURE.md` is the
long-form version of everything below; update it when you move a boundary.

**UI never imports `LTShim`.** Only `CurrentEngine` may. Engine complexity stays
behind the `TorrentEngine` actor protocol, which is why the entire app can run
against `SimulationEngine` unchanged. A `import LTShim` anywhere in `CurrentApp`
is a bug.

**Automation must explain itself.** `SeedEvaluator` and `CleanupPlanner` return
*shouldStop* **and** a human-readable reason, and those exact strings surface in
the Rules tab. Never add an automatic behavior that can't answer "why did this
happen?" — the reason string is part of the return value, not a log line bolted on
afterward.

**Automatic cleanup only moves files to Trash.** Never `unlink`, never
`removeItem`, never "delete originals" on an automated path. Eligibility is a
strict gate (complete + seed goals met + not pinned + not active + healthy swarm)
and rare swarms are excluded from automatic cleanup entirely. Ranking happens only
*after* the gate passes.

**Keyboard parity.** Every mouse interaction needs a keyboard path, and keyboard
actions never wait on decorative animation — the command palette does not animate
at all, deliberately.

**One state machine per flow.** `MagnetFlowCenter`
(`resolving → selecting → starting → completed → idle`) drives **both** the notch
panel and the in-window fallback, so the two presentations can't disagree. Don't
give a surface its own copy of flow state.

## Layout

| Path | Holds |
|---|---|
| `Sources/CurrentCore/` | Pure domain: models, `SeedPolicy`, `CleanupPlanner`, `FileTree`, `DecisionLog`, `SwarmHealth`, formatting, parsing |
| `Sources/LTShim/` | C++ shim exposing a minimal C API over libtorrent 2.x |
| `Sources/CurrentEngine/` | `LibtorrentEngine` — the only thing that imports `LTShim` |
| `Sources/CurrentSim/` | `SimulationEngine` — same protocol, deterministic |
| `Sources/CurrentApp/` | SwiftUI/AppKit app: stores, notch controller, magnet flow, UI |
| `Sources/CurrentApp/Support/Theme.swift` | **All** motion, layout and semantic-color tokens |
| `docs/ARCHITECTURE.md` | Layer diagram and rationale. Read before large changes. |

The app brain lives between the UI and the engine: `LibraryStore` (MainActor,
owns presentation state), `AutomationCoordinator` (15 s tick — seed goals, battery
pause/resume, stalled magnets), `CleanupCenter` (recomputes plans, performs
reversible cleanup).

## Motion and numbers

Durations live in `Motion` in `Theme.swift` — `instant` .12 / `quick` .18 /
`standard` .28 / `expressive` .38. **Never type a duration inline.** Springs are
critically damped (`Motion.spring`) unless a physical gesture justifies bounce
(`Motion.gestureSpring`). Nothing exceeds ~300 ms. Reduce Motion must degrade
gracefully — use the `reduceMotion:` overloads, which keep the feedback and drop
the movement.

Continuously-updating numbers (rates, sizes, ETAs) always get `.tabularNumerics()`
so widths don't jitter.

Performance shape worth preserving: engine batches arrive at ~1 Hz and are
coalesced, rows read only their own snapshot so list updates stay local, and the
notch controller throttles library observation to 2 Hz.

## Notch

`NotchWindowController` owns one borderless, non-activating panel pinned to the
camera housing, with geometry from `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`.
When idle it shrinks to exactly the notch rectangle and draws nothing. **No notch
means no panel** — the magnet flow presents in-window instead, so never assume the
panel exists.

## Repo state — read before committing

This repo has **no commits yet**, no `.gitignore`, and no git remote. The initial
commit is currently staged with **~4,900 `.build/` artifacts** in it, including the
compiled binary and vendored libtorrent dylibs.

Add a `.gitignore` covering `.build/` and `git rm -r --cached .build` before making
that first commit. Do not `git add -A` here until that is fixed.

## Conventions

- Swift 6 language mode is on for every target. New concurrent code should compile
  without `@unchecked Sendable` escape hatches.
- Engine events cross the actor boundary as `Sendable` values — payloads are copied
  out of libtorrent alerts on the worker thread, never passed as references.
- Keep diffs focused: one behavior per PR. New motion gets its frequency and
  duration justified in the PR description.
- No accounts, no analytics, no tracking, no network calls beyond the torrent
  protocol itself. Torrent history stays local.
