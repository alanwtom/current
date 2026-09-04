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
swift test                  # 50 tests, all in CurrentCore + CurrentSim
Scripts/make-app.sh         # bundles .build/Current.app (add --release for release)
open .build/Current.app
```

**libtorrent's compile definitions are load-bearing.** `Package.swift` passes a
list of `-D` defines to `LTShim` copied verbatim from
`INTERFACE_COMPILE_DEFINITIONS` in
`/opt/homebrew/lib/cmake/LibtorrentRasterbar/*.cmake`. Several of them —
`TORRENT_ABI_VERSION` and `TORRENT_SSL_PEERS` above all — change the memory
layout of structs like `torrent_status`.

Get them wrong and **nothing fails loudly**. Every call succeeds, torrents
download correctly and verify against their checksums, and every number the
shim reads back is garbage: `has_metadata` false on a complete torrent,
negative progress, a "downloaded" figure of 41 GB that changes each tick. The
app looks broken while the engine is perfect. This cost a long debugging
session; the shim now carries an `abi_canary()` that shouts once if
`torrent_status` looks impossible, and setting `CURRENT_SHIM_LOG=1` prints
every status row.

If you upgrade libtorrent, re-read that cmake file. Do not guess.

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

**Simulated torrents arrive from the engine, not from the add flow**, so nothing
calls `registerAdded` for them. That difference has already produced one bug that
only reproduced in the simulator: pinning wrote through `records[id]?`, which is a
no-op when the record is missing, and `applySnapshots` then overwrote the
snapshot's copy from that same missing record a second later. `LibraryStore`
creates records on demand now (`ensureRecord`), and doesn't persist them under
`-simulate` — fake torrents have no business in the real `library.sqlite`. When
something works in the real app and not in the simulator, or the reverse, suspect
the record.

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
actions never wait on decorative animation. The command palette used to be the
exception that proved it — it didn't animate at all — but the thing worth
avoiding there was *easing a panel into place*, not animating. It bubbles in with
every other modal surface now, and nothing waits on it: the field takes focus in
`onAppear`, so the first keystroke lands during the entrance.

**One state machine per flow.** `MagnetFlowCenter`
(`resolving → selecting → starting → completed → idle`) is the only place flow
state lives, and `MagnetFlowOverlayView` is the only thing that draws it. Don't
give a surface its own copy. It used to drive two presentations — this card and
a panel pinned to the camera housing — which is where the rule came from; the
panel is gone, but a second surface reading the stage is still how they start
disagreeing.

**Anything that asks the user a question asks it in the window.** That is the
whole reason the notch panel was removed: a magnet's "which files?" card lived
in a floating surface that couldn't be tab-navigated from the window, appeared
only on Macs with a camera housing, and hovered over other apps to demand an
answer about a library you couldn't see. Decisions belong next to the thing
they change.

**Nothing comes from the system's design.** No `NavigationSplitView`, no
`.toolbar`, no `.inspector`, no `Settings` scene, no `List(selection:)`, no
`Form`, no `.borderedProminent`, no stock `Toggle`/`Picker`/`Slider`, no
`Color.accentColor`, no `.secondary`, no `.regularMaterial`, no `Divider()`. The
app draws its own window chrome and its own controls, because those APIs are
precisely what made it look like a stock Mac utility and none of them can be
restyled far enough to stop. Reaching for one is how the old look comes back a
view at a time.

Everything visual goes through `Sources/CurrentApp/Design/`. If a colour, size,
duration or type style isn't in there, add it there — don't type it inline.

**Alignment gets measured, not eyeballed.** Two things in here are numbers
someone actually measured, and both were wrong before they were:

- `Size.iconColumn` (18) is the fixed slot a row's glyph sits in — sidebar rows,
  settings rail rows, palette rows — and it is sized to the widest symbol the app
  uses. SF Symbols are nothing like square: at `iconSmall` they run 14pt
  (`bell`) to 18 (`internaldrive`). The column used to be 16, and SwiftUI frames
  don't clip, so `battery.75` at 21pt wide hung outside it and the settings rail
  read as ragged. Add a symbol to a row list and you measure it first; anything
  over 18 gets swapped or the token moves and every label in the app moves too.
- `SettingsChrome` is the settings card's grid: **one** inside margin (20) for
  both columns and **one** header height (60) shared by the rail and the pane, so
  the two titles land on the same line. As eight inline numbers they disagreed —
  a 12pt margin on the left of the card against 20 on the right, a header 6pt
  taller on one side than the other, a row fill inset 4pt off the title above it.
  Icon buttons hang into their margin by their own slack
  (`SettingsChrome.headerTrailing`), because a 13pt glyph centred in a 26pt frame
  is optically 6.5pt further in than it measures.

**Colour carries state and outcome. It never decorates.**

| Hue | Means |
|---|---|
| accent | this is happening, or this is on — an active download, an engaged switch, the focus ring, a drop target, the one primary action on a surface |
| teal | seeding |
| green | it worked |
| amber | something you can still act on — a rare swarm, a budget about to run out |
| red | it broke, or this control destroys something |

Two rules keep that from becoming a rainbow, and both came from getting it wrong
in opposite directions:

1. **Never colour a number.** Rates, sizes, counts and ETAs are data and are
   always drawn from the grey ramp. The first pass painted every download rate
   accent blue; six downloads meant six loud blue numbers and a real failure had
   nothing to stand out against.
2. **At most two coloured elements per row, saying the same thing.** A library
   row states itself with a tinted glyph and a tinted progress bar. It used to
   also carry a filled tinted circle, a coloured rate and a coloured glow —
   four voices for one fact.

The correction to that briefly went too far the other way: everything neutral,
states distinguished only by a word. A torrent monitor whose whole job is
showing state at a glance should not have to be *read*. The line to hold is
"coloured where it identifies something, grey everywhere else" — not "as little
colour as possible".

**The exception is menus, and it is deliberate.** `Menu`, `.contextMenu` and the
menu bar stay native. A menu has to be able to leave the window,
traverse by keyboard, and behave like every other menu on the machine; a
hand-drawn one is strictly worse at all three. Native menus are also the one
place `Divider()` and `.pickerStyle(.inline)` are still correct.

## Layout

| Path | Holds |
|---|---|
| `Sources/CurrentCore/` | Pure domain: models, `SeedPolicy`, `CleanupPlanner`, `FileTree`, `DecisionLog`, `SwarmHealth`, formatting, parsing |
| `Sources/LTShim/` | C++ shim exposing a minimal C API over libtorrent 2.x |
| `Sources/CurrentEngine/` | `LibtorrentEngine` — the only thing that imports `LTShim` |
| `Sources/CurrentSim/` | `SimulationEngine` — same protocol, deterministic |
| `Sources/CurrentApp/` | SwiftUI/AppKit app: stores, magnet flow, menu bar item, UI |
| `Sources/CurrentApp/Design/` | **The design system.** `Theme` (colour), `Typo` (type), `Space`/`Radius`/`Size`/`Chrome`/`SettingsChrome` (metrics), `Motion`, `Interactions` (incl. `PopTransition`), `WindowChrome`, and `Controls/` (incl. `ModalSurface`, the app's own `.sheet`) |
| `docs/ARCHITECTURE.md` | Layer diagram and rationale. Read before large changes. |

The app brain lives between the UI and the engine: `LibraryStore` (MainActor,
owns presentation state), `AutomationCoordinator` (15 s tick — seed goals, battery
pause/resume, stalled magnets), `CleanupCenter` (recomputes plans, performs
reversible cleanup).

## Motion and numbers

Durations live in `Motion` (`Design/Motion.swift`) — `instant` .12 / `quick` .18
/ `standard` .28 / `expressive` .38. **Never type a duration inline.** Springs
are critically damped (`Motion.spring`) unless a physical gesture justifies
bounce (`Motion.gestureSpring` — the switch knob, a toast arriving, the slider
handle). Nothing exceeds ~300 ms. Reduce Motion must degrade gracefully — use the
`reduceMotion:` overloads, which keep the feedback and drop the movement.

**Every modal surface bubbles in, and they all share one entrance.** Dialogs,
settings, the palette, the add-magnet card, the file picker and the magnet-flow
cards all use `PopTransition` (`.popTransition()`) driven by
`Motion.pop(presenting:)`: from 92% with a little blur, springing a few percent
past full size before it settles, and out again fast and flat. This is the third
place allowed to overshoot and the only one that isn't a physical gesture —
a summoned surface should pop.

Two ways to get this wrong, both silent:

- **A transition needs an animated context.** The presenting `ZStack` carries
  `.animation(Motion.pop(presenting:), value:)`, because `isPresented` is set
  from menus, shortcuts and AppKit callbacks — never inside `withAnimation`.
  Without it the transition doesn't run and the surface appears fully formed.
- **Don't reach for `.sheet`.** It drops an AppKit card out of the title bar with
  a fade, and none of that is configurable. `ModalSurface` /
  `.modalSurface(isPresented:)` is the app's own presentation; because it's an
  overlay rather than a sheet, whatever is inside must claim the keyboard itself
  (`CurrentField(autofocus: true)`) or the library list keeps it and its arrow
  keys go on moving the selection behind the scrim.

Modal surfaces `.ignoresSafeArea()`. The window has no title bar but SwiftUI
still reserves ~33pt up there, so a stack that respects it centres 16pt low —
which clipped the bottom of the 540pt settings card in a short window.

Continuously-updating numbers (rates, sizes, ETAs) always get `.tabularNumerics()`
so widths don't jitter, and `.numericTransition()` so a changing value reads as
the same number moving rather than two numbers swapped.

**Press feedback comes from a `ButtonStyle`, never from an extra gesture.** Use
`.pressable()`. The first version of this was a `ViewModifier` that added its own
`DragGesture(minimumDistance: 0)` to track the press — it animated perfectly and
silently ate every click, because a zero-distance drag recognises on mouse-down
and wins the sequence, so the tap gesture outside it never fired. Rows hovered,
showed their press, and did nothing. If a thing is clickable, it is a `Button`.

Performance shape worth preserving: engine batches arrive at ~1 Hz and are
coalesced, rows read only their own snapshot so list updates stay local, and any
view that needs live engine data reads it through a coalesced model.

## There is no notch panel, and there shouldn't be one again

The app used to own a borderless panel pinned to the camera housing: idle it
collapsed into the notch and drew nothing, hover opened a card of active
transfers with pause/reveal buttons, and the magnet flow — including the
"which files?" decision — presented there instead of in the window.

It's gone, and adding it back means re-adding all of this:

- **Half the users never saw it.** It needed a camera housing, so the in-window
  card had to exist anyway as a fallback. Two presentations of one flow, one of
  which only some machines could render.
- **It asked questions the keyboard couldn't answer.** A non-activating panel
  doesn't take key focus, so Download / Choose files / Cancel were mouse-only,
  which the keyboard-parity rule above forbids.
- **It duplicated the library.** The hover card listed active transfers with
  pause and reveal — the same facts and the same two actions the list, the row
  context menu and the inspector already carry.
- **It was a second drop target,** and for a while the only one, while the
  library's empty state said "drop a torrent here" and meant nothing.

The at-a-glance-while-the-window-is-closed job belongs to the menu bar item
(`StatusItemController`), which works on every Mac. Everything that needs an
answer belongs in the window.

## Magnet links come from outside the app

Clicking a magnet link in a browser is the main way anyone adds a torrent, and
it is the path with the least code and the most ways to break. All of it goes
through `AppDelegate`, and none of it through SwiftUI:

- **`.onOpenURL` on a `WindowGroup` is wrong here, twice over.** With the app
  closed it never fires — LaunchServices delivers the URL the instant launching
  finishes, and `.onOpenURL` only reaches views that already exist, so the link
  was silently dropped and the app opened to an empty library. With the app open
  it fires, but a `WindowGroup` also reads the URL as a request for a *new*
  window, so a second empty one appeared beside the real one, once per click.
- **Implementing `application(_:open:)` receives the URL but does not stop
  SwiftUI acting on it too** — `NSApplicationDelegateAdaptor` wraps our delegate
  rather than replacing it. Taking the `'GURL'` Apple Event over in
  `applicationWillFinishLaunching` is what actually keeps the scene out of it.
  It has to be the *will* hook: at `didFinishLaunching` the launch URL has
  already been dispatched, which is exactly the case that matters.
- **`.handlesExternalEvents(matching: [])` is not the tidy version of this.** It
  also declines the launch event, so an app opened by a magnet link came up with
  no window at all.
- URLs that arrive before there is an engine wait in `AppDelegate.pending` and
  are drained at the end of `finishSetup`. On a cold launch that is every URL.
- What a delivered URL *means* is `DropParser.parse(url:)` — the same parser
  drops and pastes use, so all three routes agree. Schemes are compared
  case-insensitively, because `MAGNET:` links exist.

**Resolving a magnet is where "it doesn't work" usually comes from**, and it is
rarely the code:

- `announce_to_all_trackers` and `announce_to_all_tiers` are on. A magnet off
  the web ships a dozen trackers and most are long dead; tier by tier, resolving
  meant timing out on each corpse before reaching a live one.
- **The DHT routing table is persisted** (`dht.state`, beside the library
  database, written on a five-minute timer and at shutdown). Without it every
  launch bootstrapped the DHT from nothing, and a magnet whose trackers are all
  dead has only the DHT — so the first magnet after each launch paid for a cold
  start. The timer is not belt-and-braces: `lt_session_destroy` runs from
  `deinit`, and the object owning it lives until the process exits, so on a
  normal quit it never runs.
- A magnet that never resolves is removed after two minutes, and **says so** —
  a toast, plus the flow being taken down with it. It used to write a
  decision-log entry and nothing else, which from the outside is
  indistinguishable from the app ignoring the link; worse, the flow card went
  on saying "Resolving magnet…" about a torrent that no longer existed.

When testing this by hand, use a magnet with live trackers (Ubuntu's release
torrents are ideal, and `Scripts/` has no helper for it — build the magnet from
the `.torrent`'s info hash). A dummy hash never resolves, so it only exercises
delivery, and `CURRENT_SHIM_LOG=1` is how you tell the two apart.

## Window chrome — two traps that cost hours

The window has no system title bar and no toolbar. `WindowChrome` configures the
`NSWindow` (hidden title, transparent title bar, full-size content view, our own
background colour) and `ChromeBar` draws the bar. Both of these are load-bearing
and neither is obvious:

- **Do not add an `NSToolbar`, not even an empty one.** An empty unified toolbar
  is the supported trick for a taller title bar with the window buttons
  re-centred into it, and it does work. But SwiftUI content placed in that title
  bar region stops being offered the window's width: the chrome bar sized itself
  to its leading controls and everything from the search field rightwards was
  laid out past its edge. It looks exactly like those views failed to render, and
  an explicit `.frame(width:)` does not fix it.
- **`AppShell` must keep `.ignoresSafeArea(.container, edges: .top)`.** Without
  it SwiftUI reserves ~28pt at the top, the chrome bar sits below that strip, and
  the three window buttons are left stranded in an empty band of their own.

- **The three window buttons are moved by hand.** AppKit centres them for a 28pt
  title bar that no longer exists, which left the whole top row jammed against
  the window's edge with dead space under it — it read as clipped.
  `realignTrafficLights` centres them on `Chrome.barHeight / 2` instead. It
  grows the title bar container first: buttons moved outside their superview
  still *draw*, but stop receiving clicks, and a close button that does nothing
  is a bad day. After changing anything here, hover the buttons and check their
  glyphs appear — that is the cheap proof hit testing survived.
- **The blur is a SwiftUI `.background`, never an inserted `NSView`.** The
  window is translucent (`isOpaque = false`, clear background, `WindowBlur`
  underneath the shell). The first attempt added an `NSVisualEffectView` to the
  window's content view with `positioned: .below` — and the entire interface
  disappeared. An AppKit subview inside SwiftUI's hosting view composites *above*
  SwiftUI's own drawing whatever you position it relative to, so the blur simply
  painted over the app. Only the four base layers get the translucent tokens
  (`chromeVeil`, `canvasVeil`); anything floating on top stays opaque, or you get
  two blurs stacked and it reads as fog.
- **Only the library list is glass** (`Theme.canvasVeil`). The chrome bar,
  sidebar and inspector are solid, and so is everything floating above them. It
  follows that `AppShell` must paint **no** background of its own — an opaque
  fill there would sit between the list's glass and the blur, so the one
  translucent surface in the app would show that grey rather than the desktop.
- **Columns are not separated by lines.** The bar, sidebar, inspector and the
  gutter around the library are one continuous `Theme.chrome` plane, and the
  library is set into a rounded well cut out of it (`insetPane`). There is no
  hairline anywhere in the window's frame, and adding one back is how it starts
  looking like a 2013 Mac utility again. The seams that used to be there were a
  1pt line with 4pt of *unpainted* padding either side, and since the shell
  paints no background, what actually showed in that padding was the blurred
  desktop — a bright strip down each side of the list.
  The gutter has to be drawn as `PaneCutout` (a rectangle with the pane's shape
  punched out, filled even-odd) for the reason in the bullet above: a plain
  `.background(Theme.chrome)` on that column would put grey between the glass
  and the blur. Its hole is half a point tighter than the pane, because two
  coincident antialiased curves leave a sub-pixel gap and a gap here reads as a
  bright halo tracing the pane.
- **The material and the veil alpha have to be chosen together.** They multiply.
  `.underWindowBackground` is nearly opaque on its own, and pairing it with a
  0.7 tint produced a window that was translucent in code and a solid grey box
  on screen — the effect was there and completely invisible. Then `.hudWindow`
  at 0.35 made the list unreadable over a busy desktop. If you change one, look
  at the other. And check macOS's **Reduce Transparency** before debugging
  anything here: it disables the blur outright, and the app looks exactly as if
  the code were broken.

Modal surfaces need an **animated context to be presented in**. `ConfirmDialog`
carries its own transitions, but the state that shows it is set from an AppKit
callback, so there is no `withAnimation` at the source — the presenting overlay
wraps it in a `ZStack` with `.animation(_:value:)`. Without that the transitions
never run and the dialog simply appears fully formed.
- **Window close is intercepted with a forwarding delegate.** SwiftUI owns
  `window.delegate` and offers no close hook, so `CloseGuard` sits in front and
  passes everything except `windowShouldClose(_:)` straight through via
  `responds(to:)` / `forwardingTarget(for:)`. Taking the delegate over outright
  would silently disable whatever SwiftUI does with it.
- **The launch size is set in `WindowChrome`, not with `.defaultSize`.** SwiftUI
  ignores `.defaultSize` for this scene (the content is fully flexible, so it
  picks its own ~982×572), and `setFrameAutosaveName` doesn't stick either
  because SwiftUI installs its own afterwards. So `placeOnFirstLaunch` applies
  `Chrome.defaultWindowSize` once, guarded by a `UserDefaults` flag, and leaves
  every later launch to SwiftUI's own restoration.

## The layout-churn hazard — read before touching any view

This app has been killed twice by the same failure, and it is not obvious from
the code. **Any view whose content changes on every engine tick can crash the
app outright**, ten to thirty seconds after launch.

The mechanism: macOS re-measures a window a bounded number of times per layout
pass. Engine batches arrive at ~1 Hz, so a view that redraws differently on
every batch makes the window renegotiate its layout every second, forever. That
never converges, AppKit exceeds its own pass limit, and the process traps with:

> The window has been marked as needing another Update Constraints in Window
> pass, but it has already had more Update Constraints in Window passes than
> there are views in the window.

Two real instances, both fixed:

- **Sidebar section counts.** They were derived from per-tick data, so a count
  badge blinked in and out once a second. Fixed by `SidebarCounts`, which
  coalesces to a 2 s tick and publishes only on real change. (The worst
  offender was a `Rare Torrents` section keyed on connected seeds; that section
  has since been removed, but the coalescing is still what keeps this safe.)
- **The menu bar item.** SwiftUI's `MenuBarExtra` flushes its updates from
  inside the main window's layout pass. Nothing in our own view code could
  avoid it — a completely static label still crashed. Fixed by owning an
  `NSStatusItem` directly (`StatusItemController`).

Rules that follow from this:

- Animate on **identity, not values**. `LibraryList` keys its animation on
  `[TorrentID]`, never on `[TorrentSnapshot]`. Getting this wrong reintroduces
  the crash.
- A view that needs live engine data should read it through a coalesced model,
  not by observing `LibraryStore` directly. `SidebarCounts` (2 s) and
  `ActivityModel` (1 s) are the two that exist; the chrome bar's rate readout
  goes through the latter and is drawn at a **fixed width** so that even a real
  change can't resize anything.
- Rows and chrome controls have **fixed heights**. A row that grows by a point
  when an ETA appears re-measures the list on every tick.
- A view that opts *out* of observing the store must be handed its state as a
  **value**, not left holding an unobserved reference. `SidebarView` used to
  keep a plain `LibraryStore` reference to dodge the per-tick churn — and so
  never saw the section change: clicking "Seeding" switched the list while the
  highlight stayed on "All". It now takes `section` plus an `onSelect` closure
  and is `Equatable` on the section, which updates on real changes and on
  nothing else.

The custom shell helps here, and it is worth knowing why. `AppShell` sizes its
columns with plain `frame(width:)` calls driven by app state, so a width only
ever changes because the user dragged a seam or hit ⌘0. `NavigationSplitView`
negotiated those widths with AppKit, which is what turned a flickering sidebar
badge into a crash. The hazard is not gone — it just needs a view to misbehave
now, rather than merely to exist.

## Resizing — the bugs you can't see at one size

`WindowLayout` (`Design/WindowLayout.swift`) owns every number that decides
whether something fits, as pure functions with no views attached, covered by
`WindowLayoutTests`. That separation exists because two bugs lived in plain
sight for as long as nobody dragged a window edge:

- **A fixed-size card in a resizable window.** Settings is 760×540; in a smaller
  window it drew straight past all four edges — clipped everywhere, close button
  off screen, and the only way out was resizing a window whose controls were
  under the card. A modal states its size with **`.modalSize`, never `.frame`**:
  an inner fixed frame can't be capped from outside, so `ModalSurface` cannot
  save a card that uses `.frame`.
- **Stored column widths are requests, not results.** They're saved with no
  knowledge of the next window's size. Both seams at maximum in a 690pt window
  asked the library to be −50pt wide. `WindowLayout.columns` resolves them: the
  library gives up nothing until both panels have given up everything, and the
  inspector goes first.

The pattern in all of it: **degrade in a stated order, never in a jump, and
never below zero.** A panel spends its slack, then its minimum, then folds. The
settings rail shrinks 190 → 140 and then disappears entirely, its tabs moving
into the header — because clamping the card alone just moved the problem into the
pane, which at 380pt wrapped a download path one character per line. Same trade
the chrome bar makes when the sidebar folds away.

Two more things worth knowing before touching this:

- The window's minimum size is `Chrome.minimumWindowSize` (380×260 — a narrow
  strip is a shape this app supports), and it is enforced **only** from the
  scene's content in `CurrentApp`. `NSWindow.contentMinSize` alone does not
  survive: SwiftUI computes its own from the view tree and installs it after we
  run. Verified by dragging the corner, not by reading the docs.
- An unmeasured container means "don't shrink yet", everywhere. SwiftUI reports
  a zero size on the first layout pass, and treating that as "very small"
  collapses the chrome for a frame at launch.

New layout arithmetic goes in `WindowLayout` with a test, and the tests sweep
sizes rather than checking one. A single assertion at one comfortable size is
exactly what missed both bugs above.

`plans/README.md` has the full audit these came out of.

## Conventions

- Swift 6 language mode is on for every target. New concurrent code should compile
  without `@unchecked Sendable` escape hatches.
- Engine events cross the actor boundary as `Sendable` values — payloads are copied
  out of libtorrent alerts on the worker thread, never passed as references.
- Keep diffs focused: one behavior per PR. New motion gets its frequency and
  duration justified in the PR description.
- No accounts, no analytics, no tracking, no network calls beyond the torrent
  protocol itself. Torrent history stays local.
