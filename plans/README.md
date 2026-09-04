# Animation plans

Produced by an animation audit of the app at commit `50eeaec`. Findings and
target values follow the audit playbook at
`~/.claude/skills/improve-animations/AUDIT.md`.

Two of these are correctness bugs rather than taste calls — they are here
because they are the reason existing animation work is never seen.

**Historical record, kept as written.** Plan 002's subject — the notch panel —
has since been removed from the app, so `Notch/NotchWindowController.swift`
doesn't exist any more. The reasoning about non-blocking, interruptible frame
animation still applies to anything that animates an `NSWindow` frame; nothing
currently does.

## Plans

| # | Title | Severity | Files | Status |
|---|---|---|---|---|
| [001](001-toast-timer-and-single-animation-source.md) | Fix the toast auto-dismiss timer and give toast motion one source of truth | **HIGH** | `Toasts/ToastCenter.swift` | DONE |
| [002](002-notch-panel-non-blocking-resize.md) | Make the notch panel resize non-blocking, interruptible, and actually use its own timing | **HIGH** | `Notch/NotchWindowController.swift` | DONE |
| [003](003-consolidate-motion-tokens-and-reduced-motion.md) | Put every animation back on the Motion scale and unify reduced-motion handling | MEDIUM | `Support/Theme.swift`, `UI/Components.swift`, `UI/Inspector/InspectorView.swift`, `Toasts/ToastsOverlay.swift`, `Magnet/MagnetFlowViews.swift` | DONE |
| [004](004-animate-list-membership-changes.md) | Stop the torrent list teleporting when its membership changes | MEDIUM (additive) | `UI/TorrentListView.swift` | DONE |

## Outcome

All four applied. `swift build` clean with no new warnings, `swift test` 38/38, and
a 3 minute simulator soak with no new crash report.

**Correction to plan 003.** Its "Done when" required
`grep -rnE "Motion\.spring\([0-9]" Sources/CurrentApp/` to come back empty, but
its own Boundaries forbade touching the two files that held the last two
hand-typed values — so as written the plan could never satisfy its own
completion check. That was an authoring error: the audit swept `.animation(`
call sites and missed the two `withAnimation(` ones.

Both were closed as a follow-up outside the plans:

- `Notch/NotchWindowController.swift:295` — `Motion.spring(0.32)` →
  `Motion.spring(reduceMotion: prefersReducedMotion)`, with a new
  `prefersReducedMotion` helper on the controller that also replaces the
  inline `NSWorkspace` read in `applyFrame`.
- `Magnet/MagnetFlowViews.swift:91` — `Motion.spring(0.3)` →
  `Motion.spring(reduceMotion: reduceMotion)` on the activity-card
  tap-to-expand.

The grep is now genuinely empty and the notch surface honours Reduce Motion for
its content, not just its frame.

**Still unused after 003** (reported, not deleted — the owner decides):
`Motion.instant`, `Motion.easeOut`. `Motion.expressive` is now referenced as
`gestureSpring`'s default; `Motion.quick` and `Motion.standard` each have one
call site.

## Recommended order

**001 → 002 → 003 → 004.**

The two HIGH plans first: 001 restores a feature that is currently invisible
(every toast in the app dismisses after 5 nanoseconds), and 002 removes a
main-thread block for a one-line change. 003 is cleanup that is easier to
judge once 001 and 002 have settled the behaviour. 004 is the only plan that
*adds* motion, so it goes last and carries the most verification.

## Dependencies and file ownership

There is no shared file between plans, so they can in principle run in
parallel — but each plan explicitly forbids touching the others' files, and
running them in order avoids ambiguity about which change caused a regression
in the shared soak test.

- **001** owns `Toasts/ToastCenter.swift`. It deliberately leaves
  `Toasts/ToastsOverlay.swift` alone; **003** changes one line in that file.
- **002** owns `Notch/NotchWindowController.swift`. **003** must not touch it,
  even though it references `Motion.standard`.
- **003** is the only plan permitted to change `Support/Theme.swift`.
- **004** must land after **003**, because it calls
  `Motion.spring(reduceMotion:)` with the default response that 003 re-anchors
  to `Motion.standard`.

## Risk note

Plans **002** and **004** both touch layout machinery implicated in a
reproducible crash fixed at commit `50eeaec` (an AppKit constraint-update loop
driven by view content changing on every ~1 Hz engine tick). Both carry a
mandatory multi-minute soak test with a crash-report check. Neither plan is
complete without it.

## Deliberately not planned

These were examined and judged correct as-is:

- **The command palette does not animate.** Documented decision in `AGENTS.md`
  ("keyboard actions never wait on decorative animation"). Correct.
- **Torrent rows have no hover or press motion.** Rows are seen and traversed
  constantly; per the audit playbook's frequency rule, high-frequency elements
  should not animate.
- **No rolling-digit transitions on the per-second rate, ETA and size numbers.**
  Adding them would animate something the user sees continuously, and would
  fight the repo's tabular-numerics rule that exists to stop those numbers
  jittering.
