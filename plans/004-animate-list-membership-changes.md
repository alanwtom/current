# 004 — Stop the torrent list teleporting when its membership changes

- **Status**: DONE
- **Commit**: 50eeaec
- **Severity**: MEDIUM (additive — this adds motion that does not currently exist)
- **Category**: Missed opportunities (8)
- **Estimated scope**: 1 file, ~6 lines

> **Read the Boundaries section before writing any code.** This plan touches
> the exact layout machinery that caused a reproducible app-killing crash
> fixed in commit `50eeaec`. It has a mandatory soak test.

## Problem

`Sources/CurrentApp/UI/TorrentListView.swift:12-23` — current:

```swift
var body: some View {
    List(selection: $store.selection) {
        ForEach(torrents) { snapshot in
            TorrentRowView(
                snapshot: snapshot,
                record: store.record(for: snapshot.id),
                failure: app.failures[snapshot.id]
            )
            .tag(snapshot.id)
            .contextMenu { RowContextMenu(snapshot: snapshot) }
        }
    }
    .listStyle(.inset(alternatesRowBackgrounds: true))
    …
}
```

There is no animation anywhere on this view. The `torrents` array is supplied by `RootView.filteredTorrents` (`Sources/CurrentApp/UI/RootView.swift:16-21`), which changes membership whenever the user:

- switches sidebar section (All → Downloading → Seeding → …),
- types or clears the search field,
- adds or removes a torrent.

In every one of those cases the entire list contents are replaced instantly. This is the app's primary surface and its most jarring moment — a full-list teleport with nothing explaining that the set was filtered rather than replaced. `AUDIT.md` §8 calls this out directly: "State changes that teleport (content swaps, layout jumps) where a brief transition would prevent a jarring change."

## Target

Animate **membership changes only** — never per-tick value changes.

```swift
// Sources/CurrentApp/UI/TorrentListView.swift — target
struct TorrentListView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let torrents: [TorrentSnapshot]

    /// Identity only. The snapshots themselves change every engine tick
    /// (rates, progress, ETA); keying the animation on the whole array would
    /// animate the list once a second forever, which is both pointless and
    /// the exact per-tick layout churn that crashed this app before. Rows
    /// should only move when the *set* of rows changes.
    private var membership: [TorrentID] { torrents.map(\.id) }

    var body: some View {
        List(selection: $store.selection) {
            …unchanged…
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .animation(Motion.spring(reduceMotion: reduceMotion), value: membership)
        …unchanged…
    }
}
```

The critical detail is `value: membership` (an array of `TorrentID`) rather than `value: torrents` (an array of `TorrentSnapshot`). `TorrentSnapshot` carries `downloadRate`, `progress`, `eta` and similar fields that change on every engine batch, roughly once per second. Keying on the snapshot array would re-run this animation continuously.

## Repo conventions to follow

- Motion values come from `Motion` in `Sources/CurrentApp/Support/Theme.swift`. Use `Motion.spring(reduceMotion:)` — no hand-typed response.
- Reduced motion is read with `@Environment(\.accessibilityReduceMotion)`. Exemplar: `Sources/CurrentApp/UI/TorrentRowView.swift:10`.
- Exemplar of animating a coalesced identity rather than raw high-frequency state: `Sources/CurrentApp/Magnet/MagnetFlowViews.swift:29-37`, where `animationToken` reduces a rich state machine to a small `Int` precisely so the animation fires on meaningful change only.
- `AGENTS.md`, "Performance shape worth preserving": "engine batches arrive at ~1 Hz and are coalesced, rows read only their own snapshot so list updates stay local".

## Steps

1. In `Sources/CurrentApp/UI/TorrentListView.swift`, add the reduced-motion environment read below the two existing `@EnvironmentObject` properties:
   ```swift
   @Environment(\.accessibilityReduceMotion) private var reduceMotion
   ```

2. Add the `membership` computed property with the doc comment exactly as written in **Target** above. The comment is load-bearing — it is the reason this is safe.

3. Add `.animation(Motion.spring(reduceMotion: reduceMotion), value: membership)` immediately after `.listStyle(.inset(alternatesRowBackgrounds: true))` on line 24.

4. Do not modify the `ForEach`, the row, the `.tag`, the `.contextMenu`, the empty-state overlay, or `TorrentKeyCatcher`.

## Boundaries

- **Do NOT key the animation on `torrents`.** It must be `value: membership`. If you find yourself writing `value: torrents`, stop — that reintroduces the per-tick layout churn that crashed this app.
- Do NOT add `.transition(...)` to the rows. `List` on macOS supplies its own row insert/remove behaviour; adding an explicit transition on top of it in an `NSTableView`-backed list is a known source of layout instability, and this plan is not scoped to validate that.
- Do NOT add `.animation(...)` to `Sidebar`, `RootView`, or anything inside `TorrentRowView`.
- Do NOT change `RootView.filteredTorrents`.
- Do NOT add dependencies.
- If the code at `TorrentListView.swift:12-24` does not match what is quoted above (drift since commit `50eeaec`), STOP and report rather than improvising.

## Verification

- **Mechanical**:
  - `swift build` — expect `Build complete!` with no new warnings.
  - `swift test` — expect `Executed 38 tests, with 0 failures`.
- **Mandatory soak — this plan does not pass without it.** This repository has a history of AppKit constraint-loop crashes caused by view content changing on every engine tick; the app previously died 13 seconds after launch, then 30 seconds after a partial fix (see commit `50eeaec`). Run:
  ```bash
  Scripts/make-app.sh
  open .build/Current.app --args -simulate
  ```
  Leave it running for **at least 3 minutes**, then check:
  ```bash
  ls -t ~/Library/Logs/DiagnosticReports/ | grep -i current | head -3
  ```
  No crash report may be newer than the start of the run. If one appears, revert this change and report — do not attempt to tune around it.
- **Feel check**:
  - Click through the sidebar sections (All → Downloading → Seeding → Completed). Rows should settle into place rather than snapping. The motion should be quick enough that rapid clicking through sections never feels like waiting.
  - Type into the search field one character at a time. The list should narrow smoothly, and typing fast must never queue up a backlog of animations — each keystroke should retarget from wherever the previous one got to.
  - **Watch an idle list for 30 seconds with no interaction.** The rows must be completely still. Progress bars and numbers update, but no row may shift, fade or re-layout. If the list animates on its own, the animation is keyed on the wrong value — go back to step 3.
  - Enable Reduce Motion and repeat the section switching: rows should change with a short ease and no travel.
- **Done when**: switching sidebar sections animates, an untouched list is visually still for 30 seconds, and a 3 minute soak produces no new crash report.
