# Architecture

## The one-sentence version

A thin libtorrent engine behind a strict Swift protocol, an app-level brain
that turns engine truth into decisions and explanations, and a SwiftUI
presentation layer that never talks to the engine directly.

```
┌──────────────────────────────────────────────────────────┐
│ CurrentApp (SwiftUI + AppKit)                            │
│  Design/ — the design system every surface draws from    │
│  AppShell · ChromeBar · SidebarView · LibraryList        │
│  InspectorPanel · SettingsSurface · CommandPalette       │
│  MagnetFlow surfaces · Toasts                            │
└──────────────┬─────────────────────────────┬─────────────┘
               │                             │
        LibraryStore (MainActor)      MagnetFlowCenter
        CleanupCenter                 (stage machine)
        AutomationCoordinator
               │
┌──────────────▼──────────────────────────────────────────┐
│ TorrentEngine protocol (actor, Sendable events)          │
└──────────┬───────────────────────────┬──────────────────┘
           │                           │
   LibtorrentEngine             SimulationEngine
   (LTShim C API → libtorrent)  (deterministic dev/test)
```

## Layers

### CurrentCore — pure domain

No AppKit, no SwiftUI. Everything here is deterministic and unit-tested:

- `TorrentSnapshot` — cheap value type the engine emits at ~1 Hz.
- `SeedPolicy` / `SeedEvaluator` — Smart Seed as pure functions. Given a
  snapshot they return *shouldStop* **and human-readable reasons**. The same
  strings that decide behavior appear in the Rules tab.
- `CleanupPlanner` — eligibility gate + weighted ranking, also pure. Rare
  swarms are excluded from automatic cleanup entirely; pinned, active,
  incomplete, goal-unmet and cross-seeded torrents are kept with explanations.
- `FileTreeBuilder` — flat file lists ↔ hierarchical nodes, tri-state
  selection, priority aggregation, search filtering.

### Engines

`TorrentEngine` (actor) emits `EngineEvent`s through a single
`AsyncStream`. Two implementations exist:

- **LibtorrentEngine** wraps a C shim (`LTShim`) exposing a minimal C API:
  create session, add magnet/file/resume-data, pause/resume/remove,
  file priorities, fetch resume data. The shim translates libtorrent alerts
  into four event kinds on a worker thread; payloads are copied into Sendable
  values immediately and handed to the actor via `Task`.
- **SimulationEngine** implements the identical protocol deterministically —
  used for UI development, demos (`-simulate`), and tests. Engine complexity
  can't leak into UI when the whole app runs against a simulation.

### The app brain

- **LibraryStore** (MainActor) owns presentation state: snapshots keyed by id,
  user records (pin/policy), metadata cache, selection, filters. High-frequency
  stats live in a plain dictionary; rows read only their own snapshot so list
  updates stay local instead of invalidating everything.
- **AutomationCoordinator** ticks every 15 s: enforces seed goals (logging
  every stop/keep decision), pauses downloads on battery and resumes them,
  watches for magnets that never resolve.
- **CleanupCenter** recomputes the plan on demand and performs reversible
  cleanup: remove from engine → move content to Trash → record event → toast.

### The presentation layer

`Design/` is the whole visual vocabulary and nothing bypasses it: `Theme`
(colour, two values per token so light and dark resolve automatically), `Typo`
(type styles that carry their own letter-spacing), `Space`/`Radius`/`Size`/
`Chrome` (metrics), `Motion` (durations and springs), and `Controls/` (buttons,
switch, checkbox, segmented picker, radio group, fields, stepper, slider,
progress track, chips, empty states).

None of it comes from the system's design. `AppShell` replaces
`NavigationSplitView` + `.toolbar` + `.inspector` with columns it sizes itself;
`ChromeBar` replaces the title bar; `LibraryList` replaces `List(selection:)`
and reimplements click / ⌘-click / ⇧-click / arrow keys on top of
`ListSelection` in CurrentCore; `SettingsSurface` replaces the `Settings` scene
with an in-window panel. The reason is plain: those APIs *are* the stock-Mac
look, and none of them can be restyled far enough to stop being it.

The side benefit is structural. Column widths are now plain `frame(width:)`
calls driven by app state rather than a negotiation with AppKit — and that
negotiation is what turned a once-per-second sidebar badge into a crash. See the
layout-churn section of `AGENTS.md`.

### The signature interaction

`MagnetFlowCenter` is a five-state machine
(`resolving → selecting → starting → completed → idle`). It presents in exactly
one place: `MagnetFlowOverlayView`, a card at the top of the library. On
metadata arrival the torrent is paused, all priorities default to selected;
confirming applies priorities and resumes; cancelling removes quietly.

There used to be a second presentation — a borderless panel pinned to the
camera housing, with the in-window card as its fallback on Macs with no notch —
and the state machine existed partly to keep the two in agreement. The panel is
gone. Anything that asks the user a question asks it in the window, where the
answer can be reached by keyboard and sits next to the library it changes.

## Performance notes

- Engine batches arrive at ~1 Hz and are coalesced; per-row views depend only
  on their own snapshot.
- All motion uses springs (interruptible by construction) or short ease-outs;
  keyboard-initiated surfaces (command palette) do not animate at all.
- Numbers that change continuously render with monospaced digits everywhere.

## Testing strategy

CurrentCore is fully covered (policies, planner, file trees, formatting,
parser). SimulationEngine covers the add→resolve→download lifecycle without
network access. The libtorrent path is exercised manually via
`Scripts/make-app.sh` builds.
