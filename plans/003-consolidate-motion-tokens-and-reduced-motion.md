# 003 — Put every animation back on the Motion scale and unify reduced-motion handling

- **Status**: DONE
- **Commit**: 50eeaec
- **Severity**: MEDIUM
- **Category**: Cohesion & tokens (7), Accessibility (6)
- **Estimated scope**: 5 files, ~15 lines

## Problem

### A. The Motion scale is almost entirely unused

`Sources/CurrentApp/Support/Theme.swift:5-36` defines the app's motion vocabulary:

```swift
enum Motion {
    static let instant: TimeInterval = 0.12
    static let quick: TimeInterval = 0.18
    static let standard: TimeInterval = 0.28
    static let expressive: TimeInterval = 0.38

    static func spring(_ response: TimeInterval = 0.3) -> Animation {
        .spring(response: response, dampingFraction: 1)
    }

    static func gestureSpring(_ response: TimeInterval = 0.34) -> Animation {
        .spring(response: response, dampingFraction: 0.82)
    }

    static let easeOut = Animation.easeOut(duration: Self.standard)

    static func adaptive(_ duration: TimeInterval, reduceMotion: Bool) -> Animation { … }

    static func spring(_ response: TimeInterval = 0.3, reduceMotion: Bool) -> Animation { … }
}
```

`AGENTS.md` states: "Durations live in `Motion` in `Theme.swift` — `instant` .12 / `quick` .18 / `standard` .28 / `expressive` .38. **Never type a duration inline.**"

In practice, a repo-wide grep shows:

- `Motion.instant`, `Motion.quick`, `Motion.expressive`, `Motion.easeOut`, `Motion.gestureSpring` — **zero call sites each**.
- `Motion.standard` — one call site, `NotchWindowController.swift:343`, where it has no effect (see plan 002).
- `Motion.spring(_:reduceMotion:)` — **zero call sites**, despite existing specifically to standardise the reduced-motion branch.

Every real animation instead hand-types a spring response, and the four values are near-identical:

```swift
// Sources/CurrentApp/UI/Components.swift:25
.animation(reduceMotion ? nil : Motion.spring(0.35), value: fraction)

// Sources/CurrentApp/UI/Inspector/InspectorView.swift:440
.animation(reduceMotion ? nil : Motion.spring(0.22), value: isSelected)

// Sources/CurrentApp/Toasts/ToastsOverlay.swift:36
.animation(reduceMotion ? Motion.adaptive(0.2, reduceMotion: true) : Motion.spring(0.3), value: toasts.toasts)

// Sources/CurrentApp/Magnet/MagnetFlowViews.swift:26
.animation(reduceMotion ? Motion.adaptive(0.2, reduceMotion: true) : Motion.spring(0.32), value: animationToken)
```

0.22, 0.30, 0.32 and 0.35 are four hand-typed values within 130 ms of each other doing the job of at most two. This is the classic consolidation finding: a scale exists, and nothing uses it.

### B. Three different reduced-motion idioms, two of which drop feedback entirely

The four sites above use three different patterns for the same decision:

- `reduceMotion ? nil : …` — `Components.swift:25`, `InspectorView.swift:440`
- `reduceMotion ? Motion.adaptive(0.2, reduceMotion: true) : …` — `ToastsOverlay.swift:36`, `MagnetFlowViews.swift:26`
- `Motion.spring(_:reduceMotion:)` — the helper built for exactly this, never called

The `nil` variant means **no animation at all** under Reduce Motion. Reduced motion should mean gentler and shorter, not absent — the value change should still be perceptible, just without the travel. `AGENTS.md` agrees: "Reduce Motion must degrade gracefully — use the `reduceMotion:` overloads, which keep the feedback and drop the movement." Two of the four sites do the opposite of the documented rule.

### C. Two unused reduced-motion reads

`Sources/CurrentApp/Magnet/MagnetFlowViews.swift:124` (`ResolvingCard`) and `:208` (`StartingIndicator`) each declare:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
```

Neither view uses the value anywhere in its body. These are dead reads — harmless, but they suggest reduced-motion handling was intended and dropped, and they make a grep for reduced-motion coverage misleading.

## Target

### Theme.swift — anchor the spring defaults to the scale

```swift
/// Critically damped — the default. No overshoot anywhere in the app.
/// Response defaults to `standard` so springs sit on the same scale as
/// durations rather than drifting into hand-typed values.
static func spring(_ response: TimeInterval = Self.standard) -> Animation {
    .spring(response: response, dampingFraction: 1)
}

/// Slight bounce, reserved for physical gestures (drag releases).
static func gestureSpring(_ response: TimeInterval = Self.expressive) -> Animation {
    .spring(response: response, dampingFraction: 0.82)
}

/// Reduced Motion variant of the shared springs.
static func spring(_ response: TimeInterval = Self.standard, reduceMotion: Bool) -> Animation {
    reduceMotion ? .easeOut(duration: min(response, 0.2)) : Self.spring(response)
}
```

### The four call sites — all routed through the reduced-motion overload

```swift
// Sources/CurrentApp/UI/Components.swift:25 — target
.animation(Motion.spring(reduceMotion: reduceMotion), value: fraction)

// Sources/CurrentApp/UI/Inspector/InspectorView.swift:440 — target
.animation(Motion.spring(Motion.quick, reduceMotion: reduceMotion), value: isSelected)

// Sources/CurrentApp/Toasts/ToastsOverlay.swift:36 — target
.animation(Motion.spring(reduceMotion: reduceMotion), value: toasts.toasts)

// Sources/CurrentApp/Magnet/MagnetFlowViews.swift:26 — target
.animation(Motion.spring(reduceMotion: reduceMotion), value: animationToken)
```

Resulting values: three surfaces at `standard` (0.28), and the policy-card selection tick at `quick` (0.18) because small selection feedback should be snappier than a surface change. Under Reduce Motion all four become `easeOut(0.2)` — feedback kept, travel dropped.

Net effect: four hand-typed responses become two named tokens, and three reduced-motion idioms become one.

## Repo conventions to follow

- All motion tokens live in `Sources/CurrentApp/Support/Theme.swift`. Do not create a second tokens file.
- The `reduceMotion` value is read via `@Environment(\.accessibilityReduceMotion)` in the view and passed down as a plain `Bool` parameter where a child needs it. Exemplar: `Sources/CurrentApp/UI/Components.swift:12` (`var reduceMotion: Bool = false`) with the value supplied at `Sources/CurrentApp/UI/TorrentRowView.swift:33`.
- `AGENTS.md`, "Motion and numbers": springs are critically damped (`Motion.spring`) unless a physical gesture justifies bounce (`Motion.gestureSpring`). Nothing exceeds ~300 ms.

## Steps

1. In `Sources/CurrentApp/Support/Theme.swift`, change the three default parameter values as shown in **Target**: `spring(_:)` default `0.3` → `Self.standard`; `gestureSpring(_:)` default `0.34` → `Self.expressive`; `spring(_:reduceMotion:)` default `0.3` → `Self.standard`. Update the doc comment on `spring(_:)` to the wording in **Target**.

2. In `Sources/CurrentApp/UI/Components.swift:25`, replace the line with:
   ```swift
   .animation(Motion.spring(reduceMotion: reduceMotion), value: fraction)
   ```

3. In `Sources/CurrentApp/UI/Inspector/InspectorView.swift:440`, replace the line with:
   ```swift
   .animation(Motion.spring(Motion.quick, reduceMotion: reduceMotion), value: isSelected)
   ```

4. In `Sources/CurrentApp/Toasts/ToastsOverlay.swift:36`, replace the line with:
   ```swift
   .animation(Motion.spring(reduceMotion: reduceMotion), value: toasts.toasts)
   ```

5. In `Sources/CurrentApp/Magnet/MagnetFlowViews.swift:26`, replace the line with:
   ```swift
   .animation(Motion.spring(reduceMotion: reduceMotion), value: animationToken)
   ```

6. In `Sources/CurrentApp/Magnet/MagnetFlowViews.swift`, delete the unused `@Environment(\.accessibilityReduceMotion) private var reduceMotion` declarations in `ResolvingCard` (`:124`) and `StartingIndicator` (`:208`). Confirm with a grep that `reduceMotion` is not referenced anywhere else inside those two structs before deleting.

7. Run `grep -rn "Motion.instant\|Motion.quick\|Motion.standard\|Motion.expressive\|Motion.easeOut\|Motion.gestureSpring" Sources/CurrentApp/` and report which tokens still have zero call sites. Do **not** delete them in this plan — just report, so the owner can decide.

## Boundaries

- Do NOT change `Motion.instant`, `Motion.quick`, `Motion.standard` or `Motion.expressive`'s numeric values. Only the spring functions' *defaults* change.
- Do NOT delete any token from `Motion`, even if unused. Report only (step 7).
- Do NOT change `Motion.adaptive(_:reduceMotion:)` — it stays for duration-based (non-spring) animations.
- Do NOT touch `NotchWindowController.swift` — plan 002 owns that file.
- Do NOT touch `ToastCenter.swift` — plan 001 owns that file.
- Do NOT change any transition, layout, colour or structural code. Motion values only.
- Do NOT add dependencies.
- If the code at any cited line does not match what is quoted above (drift since commit `50eeaec`), STOP and report rather than improvising.

## Verification

- **Mechanical**:
  - `swift build` — expect `Build complete!` with no new warnings. In particular there must be no "unused variable" warnings from step 6.
  - `swift test` — expect `Executed 38 tests, with 0 failures`.
  - `grep -rnE "Motion\.spring\([0-9]" Sources/CurrentApp/` must return **nothing** — no hand-typed spring responses remain.
- **Feel check** — build and run:
  ```bash
  Scripts/make-app.sh && open .build/Current.app --args -simulate
  ```
  - **Progress bars** (`ProgressTrack`, seen in every torrent row): they should still ease toward each new value once per second rather than snapping. Slightly slower than before (0.28 vs 0.35 response) — confirm it still reads as smooth and not sluggish.
  - **Policy cards** (select a torrent, open the inspector, switch seeding policy): the checkmark and tint should snap in noticeably faster than a surface transition — this is the one site deliberately set to `quick`. If it feels the same speed as everything else, the `Motion.quick` argument was dropped.
  - **Magnet flow** (⌘N, add a magnet) and **toasts**: unchanged in feel — 0.30/0.32 → 0.28 is a ~20-40 ms difference and should be imperceptible. If either now feels abrupt, report it rather than re-tuning.
  - **Reduce Motion** (System Settings → Accessibility → Display → Reduce Motion), then re-check all four:
    - Progress bars must still animate — a short ease, not an instant jump. **This is the behaviour change**: before this plan they snapped with no animation at all.
    - Policy card selection must still animate for the same reason.
    - Toasts and the magnet flow should be unchanged from before.
    - Nothing should slide or travel; only fades and value changes.
- **Done when**: `grep -rnE "Motion\.spring\([0-9]" Sources/CurrentApp/` is empty, all four call sites read `Motion.spring(… reduceMotion: reduceMotion)`, and under Reduce Motion the progress bar animates gently instead of snapping.
