# 002 — Make the notch panel resize non-blocking, interruptible, and actually use its own timing

- **Status**: DONE
- **Commit**: 50eeaec
- **Severity**: HIGH
- **Category**: Interruptibility (4), Performance (5), Cohesion & tokens (7)
- **Estimated scope**: 1 file, ~6 lines

## Problem

`Sources/CurrentApp/Notch/NotchWindowController.swift:330-348` — current:

```swift
private func applyFrame(animated: Bool) {
    guard let panel else { return }
    let target = targetFrame()
    guard target != panel.frame else {
        currentFrame = target
        return
    }
    currentFrame = target
    guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
        panel.setFrame(target, display: false)
        return
    }
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = Motion.standard
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        context.allowsImplicitAnimation = true
        panel.setFrame(target, display: true, animate: true)
    })
}
```

Three problems, all from the last line:

1. **The timing tokens are ignored.** `NSWindow.setFrame(_:display:animate:)` does not consult the surrounding `NSAnimationContext`. It derives its own duration from `NSWindow.animationResizeTime(_:)`, which scales with the size of the frame change. So `context.duration = Motion.standard` and the `easeOut` timing function on the two lines above have **no effect whatsoever**. This is the only use of `Motion.standard` in the entire app, and it does nothing.

2. **It blocks the main thread.** `setFrame(_:display:animate:)` runs its animation synchronously, spinning the run loop until the resize completes. Every notch state change stalls the UI for the duration of the resize.

3. **It cannot be interrupted or retargeted.** The magnet flow moves through `resolving → selecting → starting → completed` (see `MagnetFlowCenter`), and `refreshVisibility()` at `:291-303` calls `applyFrame(animated: true)` on each transition. Because each resize blocks to completion, a fast sequence of stage changes plays as a queue of discrete resizes instead of one continuous motion that retargets mid-flight.

There is a fourth, visible consequence: the panel's SwiftUI **contents** animate with `Motion.spring(0.32)` (`:295`, and `NotchSurfaceView` at `MagnetFlowViews.swift:26`), while the panel's **frame** animates on AppKit's own ease curve at AppKit's own duration. The window's shape and the content inside it move on different curves for different lengths of time, which reads as the content lagging or leading the window edge.

## Target

Use the animator proxy, which does respect `NSAnimationContext`, does not block, and retargets when a new value is set mid-animation:

```swift
NSAnimationContext.runAnimationGroup({ context in
    context.duration = Motion.standard
    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
    context.allowsImplicitAnimation = true
    panel.animator().setFrame(target, display: true)
})
```

The only change is `panel.setFrame(target, display: true, animate: true)` → `panel.animator().setFrame(target, display: true)`.

With this, `Motion.standard` (0.28 s) becomes the real duration of the panel resize, matching the ~0.3 s response of the spring driving its contents, so shape and contents move together.

## Repo conventions to follow

- Durations come from the `Motion` enum in `Sources/CurrentApp/Support/Theme.swift`. This call site already references `Motion.standard` correctly — the fix makes that reference meaningful rather than decorative.
- Reduced motion is handled by the early-return at `:338-341`, which snaps the frame with no animation. Keep that behaviour exactly as is.
- `AGENTS.md` ("Notch"): the controller owns one borderless non-activating panel; geometry comes from `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. Do not change how `targetFrame()` computes geometry.

## Steps

1. In `Sources/CurrentApp/Notch/NotchWindowController.swift`, inside the `NSAnimationContext.runAnimationGroup` closure at `:342-347`, replace:

   ```swift
   panel.setFrame(target, display: true, animate: true)
   ```

   with:

   ```swift
   panel.animator().setFrame(target, display: true)
   ```

2. Add a brief comment above the group explaining why the animator proxy is required, since the difference is invisible at a glance and easy to "simplify" back:

   ```swift
   // `animator()` is load-bearing: NSWindow.setFrame(display:animate:) ignores
   // this context's duration and timing entirely, blocks the main thread until
   // it finishes, and can't retarget if the state changes again mid-resize.
   // The animator proxy honours all three.
   ```

## Boundaries

- Do NOT change `targetFrame()` (`:305-328`) or any of the frame sizes it returns.
- Do NOT change `refreshVisibility()` (`:291-303`), the `withAnimation(Motion.spring(0.32))` inside it, or the `surfaceState` machine.
- Do NOT change the reduced-motion early return at `:338-341`.
- Do NOT change `Motion.standard`'s value in `Theme.swift`.
- Do NOT add dependencies.
- If the code at `:342-347` does not match what is quoted above (drift since commit `50eeaec`), STOP and report rather than improvising.

## Verification

- **Mechanical**:
  - `swift build` — expect `Build complete!` with no new warnings.
  - `swift test` — expect `Executed 38 tests, with 0 failures`.
- **Feel check** — this requires a Mac with a notch; the panel does not exist otherwise (`AGENTS.md`: "No notch means no panel"). Build and run:
  ```bash
  Scripts/make-app.sh && open .build/Current.app --args -simulate
  ```
  - Add a magnet (⌘N) and watch the notch panel through the `resolving → selecting → starting → completed` sequence. The panel should **grow and shrink continuously**, never freezing at a size before jumping to the next.
  - During a resize, the black panel background and the text inside it should arrive at the new size **together**. Before this fix the contents settle at a visibly different time from the window edge — that mismatch must be gone.
  - Interrupt mid-resize: trigger a second stage change while the first resize is still visibly running. The panel must smoothly redirect to the new size, not finish the old resize first and then start another.
  - Confirm the main thread is not stalling: while the panel resizes, the torrent list's per-second numbers should keep ticking. Before this fix they freeze for the length of the resize.
  - Enable Reduce Motion and repeat: the panel snaps to each size with no animation, and nothing else changes.
- **Soak requirement**: run the app for at least 2 minutes with the simulator and confirm no new crash reports appear:
  ```bash
  ls -t ~/Library/Logs/DiagnosticReports/ | grep -i current | head -3
  ```
  This app has a history of AppKit constraint-loop crashes originating in window layout (fixed in commit `50eeaec`); any change to window frame animation must be soak-tested rather than eyeballed.
- **Done when**: the panel resize visibly takes ~0.28 s regardless of how large the size change is (previously it scaled with distance), contents and window edge land together, and a 2 minute run produces no new crash report.
