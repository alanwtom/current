# 001 — Fix the toast auto-dismiss timer and give toast motion one source of truth

- **Status**: DONE
- **Commit**: 50eeaec
- **Severity**: HIGH
- **Category**: Purpose & frequency (1), Interruptibility (4), Cohesion & tokens (7)
- **Estimated scope**: 2 files, ~20 lines

## Problem

### A. Toasts dismiss after 5 nanoseconds instead of 5 seconds (HIGH)

`Sources/CurrentApp/Toasts/ToastCenter.swift:54-58` — current:

```swift
let task = Task { [weak self] in
    try? await Task.sleep(nanoseconds: UInt64(self?.displayDuration ?? 5 * 1_000_000_000))
    guard !Task.isCancelled else { return }
    self?.dismiss(toast.id)
}
```

`displayDuration` is declared at `ToastCenter.swift:33` as `private let displayDuration: TimeInterval = 5`.

In Swift, `*` (MultiplicationPrecedence) binds tighter than `??` (NilCoalescingPrecedence). So this parses as:

```swift
UInt64(self?.displayDuration ?? (5 * 1_000_000_000))
```

When `self` is non-nil — which is always, in practice — the result is `UInt64(5.0)`, i.e. **5 nanoseconds**. The multiply only applies to the fallback branch that never runs.

Verified numerically:

```
as written : 5 ns  = 5e-09 s
as intended: 5000000000 ns = 5.0 s
```

Consequence: every toast is dismissed before its 0.26 s entrance animation can play. There are 7 call sites (`Sources/CurrentApp/App/AppEnvironment.swift:79, 153, 178, 184, 190, 192, 194`) covering cleanup confirmations, add-failure warnings and duplicate-torrent notices. None of them are ever seen by the user. All the toast motion work in `ToastsOverlay.swift` is currently dead.

### B. Two competing animations drive the same state change (MEDIUM)

`ToastCenter.swift:59-61` and `:77-79` wrap the array mutation in an explicit transaction:

```swift
withAnimation(Self.animation()) {
    toasts.append(PresentedToast(toast: toast, dismissTask: task))
}
```

```swift
withAnimation(Self.animation(exit: true)) {
    _ = toasts.remove(at: index)
}
```

But `Sources/CurrentApp/Toasts/ToastsOverlay.swift:36` also attaches an implicit animation to the same array:

```swift
.animation(reduceMotion ? Motion.adaptive(0.2, reduceMotion: true) : Motion.spring(0.3), value: toasts.toasts)
```

A `.animation(_:value:)` modifier overrides the ambient transaction for its subtree, so the spring wins and the `withAnimation` easing never applies. The transaction is dead code that reads as intent, and the asymmetric enter/exit timing it encodes (0.26 in, 0.16 out) is silently discarded.

### C. Hover-to-pause is dead code (MEDIUM)

`ToastCenter.swift:32` declares `private var hoverPaused = Set<UUID>()`. It is written in two places:

```swift
func pauseHover(_ id: UUID) {
    hoverPaused.insert(id)
}

func resumeHover(_ id: UUID) {
    hoverPaused.remove(id)
}
```

It is **never read**. Confirmed: the only three references in the whole repo are the declaration and those two mutations. The dismiss task at `:54` does not consult it. So hovering a toast does not pause its timer, which directly contradicts the documented behaviour in the doc comment at `ToastsOverlay.swift:4-5`:

```swift
/// Bottom-trailing transient surface. Enters with a small rise + scale,
/// exits fast with a fade; hover pauses the auto-dismiss timer.
```

### D. Raw durations off the Motion scale (LOW)

`ToastCenter.swift:68-71`:

```swift
private static func animation(exit: Bool = false) -> Animation {
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    return Motion.adaptive(exit ? 0.16 : 0.26, reduceMotion: reduceMotion)
}
```

`0.16` and `0.26` are hand-typed and are not on the app's duration scale (`Motion.instant` 0.12 / `quick` 0.18 / `standard` 0.28 / `expressive` 0.38). `AGENTS.md` states: "Durations live in `Motion` in `Theme.swift` … **Never type a duration inline.**" This is the only place in the app that breaks that rule.

## Target

Toasts stay on screen for their full 5 seconds, pause while hovered, and animate from exactly one place.

`ToastCenter.swift` — the timer becomes a loop that re-checks the hover set, so hovering extends the life of the toast rather than only delaying the initial schedule:

```swift
/// Poll interval for the auto-dismiss countdown. Coarse on purpose — this
/// is a 5 second timer, not an animation.
private static let dismissPollInterval: TimeInterval = 0.25

private func scheduleDismissal(of id: UUID) -> Task<Void, Never> {
    Task { [weak self] in
        var remaining = self?.displayDuration ?? 5
        while remaining > 0 {
            try? await Task.sleep(
                nanoseconds: UInt64(Self.dismissPollInterval * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // Hovering holds the toast open instead of just delaying the start.
            if !self.hoverPaused.contains(id) {
                remaining -= Self.dismissPollInterval
            }
        }
        guard !Task.isCancelled else { return }
        self?.dismiss(id)
    }
}
```

Mutations are no longer wrapped in `withAnimation`; the overlay's `.animation(_:value:)` modifier is the single source of truth:

```swift
toasts.append(PresentedToast(toast: toast, dismissTask: task))
```

```swift
_ = toasts.remove(at: index)
```

The now-unused `animation(exit:)` helper and its raw `0.16` / `0.26` durations are deleted.

## Repo conventions to follow

- Motion tokens live in `Sources/CurrentApp/Support/Theme.swift` in the `Motion` enum. Never type a duration inline (`AGENTS.md`, "Motion and numbers").
- Reduced motion is read on the view side via `@Environment(\.accessibilityReduceMotion)`, not via `NSWorkspace` in a store. Exemplar: `Sources/CurrentApp/Toasts/ToastsOverlay.swift:8`.
- `ToastCenter` is `@MainActor`; all state touched by the dismiss task is already main-actor isolated, so no extra synchronisation is needed.
- Exemplar of a store that owns timing without owning animation: `Sources/CurrentApp/Automation/AutomationCoordinator.swift`.

## Steps

1. In `Sources/CurrentApp/Toasts/ToastCenter.swift`, add the `dismissPollInterval` static constant and the `scheduleDismissal(of:)` method exactly as written in **Target** above. Place them near `displayDuration` (around line 33).

2. In `show(_:title:message:actionTitle:coalesceKey:action:)`, replace the inline `let task = Task { … }` block (`:54-58`) with:

   ```swift
   let task = scheduleDismissal(of: toast.id)
   ```

3. In the same method, unwrap the mutation at `:59-61` — remove the `withAnimation(Self.animation()) { … }` wrapper, leaving:

   ```swift
   toasts.append(PresentedToast(toast: toast, dismissTask: task))
   ```

4. In `dismiss(_:)` (`:73-80`), remove the `withAnimation(Self.animation(exit: true)) { … }` wrapper, leaving:

   ```swift
   _ = toasts.remove(at: index)
   ```

5. Delete the now-unused `private static func animation(exit:)` helper entirely (`:68-71`). If `import SwiftUI` or the `NSWorkspace` usage becomes unused as a result, leave the imports alone — `Animation` types may still be referenced elsewhere in the file; only remove an import if the compiler warns.

6. Leave `pauseHover(_:)` and `resumeHover(_:)` exactly as they are. They now have a reader.

## Boundaries

- Do NOT change `ToastsOverlay.swift` in this plan — its transition and `.animation(_:value:)` are correct and become the single source of truth. Plan 003 revisits its reduced-motion idiom.
- Do NOT change the toast visual design, card layout, colours, or the `.transition(.asymmetric(...))` at `ToastsOverlay.swift:23-30`.
- Do NOT change `displayDuration` from 5 seconds.
- Do NOT add dependencies.
- If the code at the cited lines does not match what is quoted above (drift since commit `50eeaec`), STOP and report rather than improvising.

## Verification

- **Mechanical**:
  - `swift build` — expect `Build complete!` with no new warnings.
  - `swift test` — expect `Executed 38 tests, with 0 failures`.
- **Feel check** — build the bundle and run the simulator:
  ```bash
  Scripts/make-app.sh && open .build/Current.app --args -simulate
  ```
  Toasts fire on cleanup completion and on add failures. The most reliable trigger in simulator mode is to add a magnet with a malformed URI via the Add Magnet sheet (⌘N), which routes to `toasts.show(.warning, …)` at `AppEnvironment.swift:194`.
  - The toast is **visible for a full 5 seconds**, not a flicker. Time it.
  - It enters with a rise + slight scale from the bottom-trailing corner, and exits with a plain fade — no movement on exit.
  - **Hover over the toast and hold**: it must stay on screen indefinitely. Move the pointer away: it dismisses ~5 s later.
  - Trigger three toasts in quick succession: they stack, and the fourth evicts the oldest. Dismissing one mid-animation must not restart the others from zero — they should retarget smoothly.
  - Enable System Settings → Accessibility → Display → Reduce Motion, then repeat: the toast still appears and disappears with an opacity change, but does not slide. Feedback must remain — a toast that no longer appears at all is a regression.
- **Done when**: a toast is verifiably on screen for 5 seconds, hovering holds it open, and `grep -n "withAnimation" Sources/CurrentApp/Toasts/ToastCenter.swift` returns nothing.
