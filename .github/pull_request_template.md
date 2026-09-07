<!--
The bar here is craft, not feature count. CONTRIBUTING.md has the long version
and AGENTS.md has the rules the code is actually held to.

Delete any section below that doesn't apply — an honest short PR beats a
padded template.
-->

## What this changes

<!-- What someone using the app would notice, in plain language. Not the name
     of the property that changed. -->

## Why

<!-- What was wrong, or what this makes possible. If it fixes something, say
     what the symptom looked like from the outside — that's what makes this
     findable in six months. -->

## How it was verified

<!-- `swift test` alone is not verification for anything with a UI. Say what
     you actually did. -->

- [ ] `swift build` and `swift test` pass
- [ ] Tried it in the app (`-simulate` is fine for UI work)
- [ ] Touched window frames, column widths or list content? Soak-tested for
      three minutes against `-simulate`, and checked
      `~/Library/Logs/DiagnosticReports/` after. This app has died twice from a
      layout loop that takes 10–35 seconds to show up, so ten seconds of
      looking fine proves nothing.

## Rules this had to clear

<!-- Only tick what's relevant. These are the five that get broken most. -->

- [ ] **Anything new in `CurrentCore` has tests.** It stays pure — no AppKit,
      no SwiftUI, no I/O.
- [ ] **No `import LTShim` outside `CurrentEngine`.**
- [ ] **Nothing from the system's design language** — no `NavigationSplitView`,
      `.toolbar`, `.inspector`, `.sheet`, stock `Toggle`/`Picker`/`Slider`,
      `.secondary`, `Divider()`. Menus are the deliberate exception.
- [ ] **Colours, sizes, durations and type styles come from
      `Sources/CurrentApp/Design/`,** not typed inline. New motion justifies
      its duration below.
- [ ] **Every mouse interaction has a keyboard path.**
- [ ] **Any new automatic behaviour returns a human-readable reason,** and
      automatic cleanup still only moves files to the Trash.

## Motion

<!-- New or changed animation only. What plays, how often, how long, and why
     that duration. Nothing exceeds ~300 ms; springs are critically damped
     unless a physical gesture justifies bounce; Reduce Motion has to degrade
     gracefully. -->

## Anything I'm unsure about

<!-- Genuinely useful. Say where you guessed. -->
