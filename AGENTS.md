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
swift test                  # ~310 tests, ~30 s; RealEngineTests drive real libtorrent offline
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

**Never hardcode where the build puts its products.** Ask:
`swift build -c <config> --show-bin-path`. `Scripts/make-app.sh` and
`.github/workflows/ci.yml` both do. They used to hardcode
`.build/arm64-apple-macosx/<config>/Current`, and once the toolchain defaulted
to swiftbuild (Swift 6.4; products in `.build/out/Products/<Config>`) the old
folder stayed
behind — so `make-app.sh` kept finding a `Current` there and bundled a binary
weeks out of date, with no error. `.build/debug` and `.build/release` are
symlinks to the right place under either build system, so they're fine for
running by hand.

swiftbuild also bakes an absolute rpath to this machine's
`.build/out/Products/<Config>/PackageFrameworks` into the executable, and
Homebrew's libtorrent carries one to its own Cellar folder. `make-app.sh`
strips every absolute rpath from what it bundles, and its closing check now
fails the bundle if one is left, the same way it fails on an absolute library
path.

**Every bundled library has to load on the oldest macOS the app promises**
(`LSMinimumSystemVersion`, 26.0). Homebrew installs the build made for the Mac
it's on, so once this Mac moved to macOS 27, the next OpenSSL update arrived
built for 27 only — and a release made then would not have opened on macOS 26
at all. Nothing failed; the linker printed one warning among dozens.
`make-app.sh` now refuses a release bundle holding any binary that needs a
newer macOS than the app claims (a debug bundle only warns).

The fix is `HOMEBREW_FAKE_MACOS=26.0 brew reinstall <formula>`, which pours
Homebrew's own macOS 26 build. **Not `--build-from-source`**: Homebrew
discards any deployment target you set, so the compiler takes the SDK's
version instead — 26.5 here — and that still locks out 26.0–26.4. Expect to
redo this every time Homebrew updates OpenSSL or libtorrent. Homebrew marks
`HOMEBREW_FAKE_MACOS` for removal from late 2027; when it goes, building
releases on a macOS 26 machine is the way out.

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
*after* the gate passes. "Shared with another torrent" means two torrents that
unpack into the same place (`ContentLocation.contentKey`), **not** two torrents
in the same folder — keyed on the folder, the gate excluded every torrent in
the default download folder and cleanup could never remove anything. A cleanup
that moves nothing to the Trash doesn't remove the torrent either, or a storage
budget would eat the library without freeing a byte.

**Deleting takes the torrent's files, never its name.** Both deletes — "Remove
and delete files" and cleanup — go through `ContentTrash`, which trashes what
`ContentLocation.trashPlan` names: the files in the torrent's own metadata,
each proved to sit inside the save folder, and the root folder whole only when
everything in it belongs to the torrent. No metadata means it wrote nothing,
so nothing is touched. The version this replaced trashed `saveDirectory/name`,
plus a second candidate built with `appendingPathExtension` — which Foundation
returns *unchanged* for a name ending in a full stop, so "delete files" on a
torrent called `Something.` put the whole download folder in the Trash. That
shipped in every release up to 1.2.0. `DeletionSafetyTests` holds the strings.
Tests replace `contentTrash.moveToTrash`; nothing in the suite may touch the
real Trash.

**Nothing downloads before someone says yes.** Anything headed for the
confirm card is added **held** (`add(_:saveDirectory:held:)`): a magnet runs in
libtorrent's upload mode, not auto-managed — it trades metadata but never
requests a piece — and the shim pauses it the moment its metadata arrives; a
held .torrent file is simply added paused. `lt_resume` clears upload mode, so
every resume is a decision to download. This replaced the app pausing torrents
*after* their metadata reached the UI, by which time they'd been downloading
since they were added — and a second magnet arriving while the card was busy
was never paused at all. The card belongs to one torrent (`awaitedID`); a
download that can't have it waits, held, with a "Start" toast. Magnets are
always held. .torrent files are held only when they get the card.

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

**A setting explains itself or says nothing.** Most controls in Settings are a
label and a switch, and that is the finished state — no `detail` line, no group
`footer`. Every one of them used to carry a sentence, and the effect was the
opposite of helpful: "Ask where to save each download" was followed by a
paragraph saying it asks where to save each download, and the two or three
settings that genuinely can't be guessed were buried in the noise. The bar a
sentence has to clear is that it says something neither the label nor the
control can — what the app will do on its own, what a switch deliberately
leaves alone, a cross-reference to another pane, or a consequence that isn't
reversible. Network clears it on nearly every row, and the automatic-cleanup
switch clears it because it moves files without being asked. Notifications,
Updates, Magnet links and Appearance clear it nowhere, and now say nothing.

The other half of this: **the app's privacy position is not a settings row.**
"No accounts, no analytics, no tracking" sat in the bottom corner of the
settings rail, where it was a slogan on a piece of furniture — the website is
where a claim like that belongs, and it is still there.

**Colour carries state and outcome. It never decorates.**

| Hue | Means |
|---|---|
| accent | this is happening, or this is on — an active download, an engaged switch, the focus ring, a drop target, the one primary action on a surface |
| teal | seeding |
| green | it worked |
| amber | something you can still act on — a rare swarm, a budget about to run out |
| red | it broke, or this control destroys something |

Three rules keep that from becoming a rainbow. The first two came from getting
it wrong in opposite directions; the third is one Alan set outright:

1. **Never colour a number.** Rates, sizes, counts and ETAs are data and are
   always drawn from the grey ramp. The first pass painted every download rate
   accent blue; six downloads meant six loud blue numbers and a real failure had
   nothing to stand out against.
2. **At most two coloured elements per row, saying the same thing.** A library
   row states itself with a tinted glyph and a tinted progress bar. It used to
   also carry a filled tinted circle, a coloured rate and a coloured glow —
   four voices for one fact. For the same reason a state pill *inside a row*
   goes fully grey (`StatePill(quiet:)`) unless the row has nothing else
   carrying that colour — "No connection" is the one that keeps its amber.
3. **Ink or surface, never both.** A colour goes in the glyph *or* in the fill
   behind it. A green tick on grey is fine; white on solid red is fine; a green
   tick on a pale green wash is not. That last shape was everywhere — state
   pills, callouts, the VPN shield, the selected radio row and theme card, the
   drop target, a destructive button under the cursor — and every one of them
   now puts its colour in one place. There is no `tint.opacity(…)` background
   left in the app and no `accentSoft` token to make one with; don't add either
   back. A destructive button under the cursor fills with `Theme.destructive`,
   a deeper red than `failure`, because white on the text red is unreadable.

The correction to that briefly went too far the other way: everything neutral,
states distinguished only by a word. A torrent monitor whose whole job is
showing state at a glance should not have to be *read*. The line to hold is
"coloured where it identifies something, grey everywhere else" — not "as little
colour as possible".

**The exception is menus, and it is deliberate.** `Menu`, `.contextMenu` and the
app's menu bar menus stay native. A menu has to be able to leave the window,
traverse by keyboard, and behave like every other menu on the machine; a
hand-drawn one is strictly worse at all three. Native menus are also the one
place `Divider()` and `.pickerStyle(.inline)` are still correct.

**The status item's panel is not a menu, and that's why it's ours.**
`StatusPanelView` is a real panel hanging under the menu bar icon: live
progress bars, a per-transfer pause button, a rate readout. `NSMenu` cannot
draw any of that — the version that tried was a column of disabled text items,
one of which said "6 active", which is strictly less than the icon beside it
already told you. The test for whether something may be hand-drawn here is not
"does it hang off the menu bar" but "is it a list of commands". If it is, it's
a menu and it stays native.

## Layout

| Path | Holds |
|---|---|
| `Sources/CurrentCore/` | Pure domain: models, `SeedPolicy`, `CleanupPlanner`, `FileTree`, `DecisionLog`, `SwarmHealth`, `RateHistory`, formatting, parsing |
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

## The grid

Every panel and screen is laid out on **an 8pt base grid with a single 4pt
half-step**, and the split between the two is not a fudge — it is how these
systems are used:

- **Spacing snaps to 8.** Gaps between things, padding inside surfaces. The
  scale is `Space`: **4 / 8 / 12 / 16 / 24 / 32**, and that is all of it.
- **Component sizing gets the 4pt half-step.** `Size.controlS/M/L` are 24 / 28 /
  32. Forcing controls onto multiples of 8 would coarsen the app rather than
  order it; a 28pt button is a real height.

`Space` used to carry a `hair` of 2 and an `s` of 6. Neither sat on any grid,
and between them they were 45 of the app's gaps — so the app was off-grid nearly
everywhere while having a scale that claimed otherwise. They are folded into 4
and 8.

**Type is four sizes and three weights: 11 / 13 / 16 / 22.** Where two styles
share a size they are told apart by weight — `body`, `label` and `heading` are
all 13 at regular, medium and semibold; `overline` and `caption` are both 11,
and the overline is told apart by caps and tracking. The scale used to run
10 / 11 / 12.5 / 13 / 16 / 22, and three of those steps sat inside two points of
each other, which is not a hierarchy: nobody can see the difference, so it does
no work while still costing a decision every time something is written.

**No more than three sizes and three weights in one component.** This is the
rule worth keeping, because it is the one that makes hierarchy legible. All
fourteen screens hold to it; four of them did not before. When you add a
component, count.

**Radii nest concentrically: an inner radius is the outer radius minus the gap
between them.** A 12pt card with 8pt padding wants 4pt corners inside it, or the
two curves fight. `Chrome.contentInset` is 10 for exactly this reason — it is
`Radius.window`, so the library's well is concentric with the window's own
corner.

### The exceptions, and why they outrank the grid

Three numbers are deliberately off it. Each is measured against something
physical, and a future tidy-up that snaps them will break something:

- **`Size.iconColumn` = 18.** Sized to the widest SF Symbol the app puts in a
  row. 16 clipped `internaldrive`; SwiftUI frames don't clip, so it spilled.
- **`Size.row` = 58.** 56 fits, but the two points are the difference between
  the sub-line's descenders clearing the row fill and grazing it.
- **`Chrome.barHeight` = 44.** The three window buttons are centred on half of
  it. It answers to AppKit, not to the grid.

And one trap that already cost a test failure: **`Chrome.modalMargin` is not
`SettingsChrome.inset`.** One is the gap outside a card, the other the margin
inside it. They were the same token by coincidence, so when the scale moved and
that token went 20 to 24, it silently took 8pt off the settings card — which in
the 380pt window the app supports pushed the pane under the width where a
download path stops wrapping one character per line. `WindowLayoutTests` caught
it. They are separate values now.

## Motion and numbers

Durations live in `Motion` (`Design/Motion.swift`) — `instant` .12 / `quick` .18
/ `standard` .28 / `expressive` .38. **Never type a duration inline.** Springs
are critically damped (`Motion.spring`) unless a physical gesture justifies
bounce (`Motion.gestureSpring` — the switch knob's trailing edge, a checkbox
filling, a selected theme's tick landing, a toast arriving, the slider handle).
Nothing *moving between two states* exceeds ~300 ms; loops (the spinner, the
flowing bar, the drop target's march) are not transitions and aren't capped.
Reduce Motion must degrade gracefully — use the `reduceMotion:` overloads, which
keep the feedback and drop the movement.

**Motion has a vocabulary, the way colour does.** Five movements, one meaning
each — the long version is at the bottom of `Motion.swift`:

| Movement | Means | Where |
|---|---|---|
| flow | data is moving right now | a light running along a progress bar (`ProgressTrack.Flow`); the drop target's marching border; the VPN shield breathing while it waits |
| drop | it arrived, it's done | one `Ripple`: a finished download's row, a dropped file, the launch opening the window |
| shake | that didn't work | `.shake(trigger:)`: a failed row's glyph, a refused magnet link, the VPN shield when traffic isn't protected |
| stretch | you moved between choices | `StretchHighlight`: sidebar, segmented picker, palette; the switch knob |
| origin | it came from what you clicked | `PopTransition(origin:)`; the magnet card flying into its row |

A new animation should be one of these or have a stated reason it isn't.
Movement that means nothing in particular is decoration, and the colour rules
already say what this app thinks of that. Every one of these is offset, scale,
opacity or drawing inside a `Canvas`/shape — none of them changes a size, which
is what keeps them clear of the layout-churn hazard below.

Four implementation notes, each of which is the second way that was tried:

- **The flowing bar is a `TimelineView` + `Canvas`, not `repeatForever`.** The
  light's position is a pure function of the clock, so a speed change never
  restarts anything, and a `repeatForever` started in `onAppear` inside a lazy
  list is a known way for the list's own insertions to pick up the loop. It
  flows only while the rate is above zero — a stalled download is then the one
  bar standing still, which is the whole point — at one of three speeds
  (`Motion.flowPeriod(for:)`), because a speed derived straight from the rate
  would restart every tick.
- **Stretch can't be a `matchedGeometryEffect`.** That animates one frame with
  one animation. `StretchSpan` puts each edge in its own `Animatable` view, so
  the leading and trailing edges get separate `withAnimation` calls and separate
  springs. `StretchHighlight` only stretches when the *selection* changes; a
  seam drag or a resize snaps it, or it would lag behind what it marks.
- **A row's finish is detected, not replayed.** `LibraryRow` keeps the phase it
  last settled in, and only downloading → seeding/completed while on screen
  fires the ripple and the drawn-on tick. A torrent restored complete, or a row
  scrolled back into view, does nothing. The glyph changes *identity* only for
  a finish, so every other state change keeps the ordinary symbol replace.
- **The switch is a `Button` with a `ButtonStyle`.** The stretch hangs on the
  press, and `configuration.isPressed` is the one press signal that doesn't
  fight the click (see the `.pressable()` note below). It also made the switch
  reachable by keyboard, which the tap gesture it used to be was not.

**Every modal surface bubbles in, and they all share one entrance.** Dialogs,
settings, the palette, the add-magnet card, the file picker and the magnet-flow
cards all use `PopTransition` (`.popTransition()`) driven by
`Motion.pop(presenting:)`: from 92% with a little blur, springing a few percent
past full size before it settles, and out again fast and flat. This is the one
overshoot that isn't a physical gesture — a summoned surface should pop.

**It grows out of whatever you clicked.** `PresentationOrigin.current()` reads
the click AppKit is dispatching when the surface is created; each surface keeps
that point in `@State` and hands it to `.popTransition(from:)`, which anchors the
scale there (from 86% instead of 92%, so the direction is visible). A key press,
a click in a menu or another window, or anything stale gives nil, and the
surface pops from its centre as before — so ⌘K still opens the palette in the
middle. Nothing has to report its own position; that's why it reads the event
rather than asking each button.

The magnet flow's selection card leaves the other way: on Download it flies
into its torrent's row (`Landing`), which has been in the library since the
link arrived. **It is an animated state change, not a removal transition** —
the card keeps its identity from `.selecting` into `.starting` and is moved
there. A transition is fixed at a view's last render, and the card's last
render can't know whether Download or Cancel comes next; as a transition,
Cancel flew the card into the very row it was deleting. Rows report where they are into `RowFrames` — a plain
registry, not published state, because they report on every scroll. When the
row isn't on screen the card pops away and the "Starting download…" card
appears as before; when it is, that card is skipped, because the row is already
saying it.

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
(`StatusItemController`), which works on every Mac — and it now carries the
quick controls too: rates, per-transfer progress, pause/resume, reveal. That is
the *same* content the notch's hover card had, and it is fine here for the
reason it wasn't there: the panel exists on every Mac, takes the keyboard, and
is the only surface available when the window is closed. Everything that needs
an *answer* still belongs in the window.

## Confining transfers to one connection (the VPN binding)

The Network pane can restrict every transfer to one network device — a VPN
tunnel, or a named interface. `NetworkBinding` in `CurrentCore` is the pure
part; `NetworkMonitor` in the app lists interfaces and resolves the choice
against them; the shim applies it. Six things here are not obvious and all of
them were paid for:

- **Binding takes two libtorrent settings, not one.** `listen_interfaces`
  covers incoming connections, the DHT, UDP tracker announces and — in 2.x —
  HTTP tracker announces. Outgoing peer connections are bound *separately* by
  `outgoing_interfaces`. Set only the first and peers still get reached over
  whatever route the kernel prefers, which is the leak every comparable client
  has shipped at some point.
- **The unbound case is the bug, not just the absence of a feature.** Listening
  on `0.0.0.0` makes libtorrent open one listen socket per interface and
  announce from each — so with a VPN up, the tracker is told the tunnel address
  *and* the real one.
- **Never store the device name for "my VPN".** macOS renumbers `utun` on every
  reconnect and leaves the dead ones behind until reboot, so a saved `utun4` is
  wrong the first time the tunnel drops and returns. `NetworkBinding.activeVPN`
  stores the *intent* and is resolved against the current snapshot every time.
  Which tunnel counts is decided by the system's own routing (the primary
  interface), not by the name.
- **The indicator reads the engine, not the setting.** `listen_succeeded_alert`
  and `listen_failed_alert` are forwarded through the shim so the pane can show
  the address libtorrent actually bound to. Showing the user's *choice* back to
  them is unfalsifiable, and "the screen said bound while traffic went
  elsewhere" is the whole failure class here.
- **Addresses come back scoped.** A real bind reports its IPv6 link-local
  address as `fe80::…%en0`, and the interface list deliberately excludes
  link-local (every interface on macOS has one, so counting them would make
  "this connection has IPv6" true everywhere and kill the warning about an
  IPv4-only tunnel). `ListenState.confirms` therefore treats a `%device` suffix
  as evidence in itself. An earlier version compared addresses only and
  reported a leak on every single successful bind.
- **libtorrent posts listen alerts only when the setting actually changes.**
  Re-applying an identical `listen_interfaces` emits nothing, and a binding
  switched to a device that doesn't exist goes quiet rather than reporting a
  failure. So `NetworkMonitor` clears its listen state whenever the resolved
  outcome changes; otherwise the readout keeps showing sockets that were torn
  down.
- **Being blocked is a standing condition, not an event.** Stopping transfers
  when the connection goes is done in `LibraryStore` — on the way in, per
  snapshot — and not as a sweep at the moment the outcome flips. A sweep can
  only ever act on the library as it stands at that instant, and torrents keep
  arriving after that: restoring from disk happens well after the binding is
  resolved, so a Mac that launched with the VPN down stopped *nothing*. Those
  torrents were rewritten to read as stopped by `blockedByNetwork()` and never
  told to stop, so the moment the tunnel came back they carried on — the one
  thing this feature promises can't happen. Two rules fall out of it: the
  engine's own state decides what to stop (a stored snapshot has already been
  rewritten to look stopped, so reading that finds nothing to do), and the
  number written to the decision log is what was *actually* stopped, reported
  by the store, because the count taken when the connection dropped is zero on
  exactly the launch that is about to stop six things.

Two supporting rules: the session now starts with **no listen sockets at all**
and the app's first `apply` opens them (same fail-closed reasoning as UPnP and
LSD — a test that creates an engine and skips `apply` has no networking), and
the OS port fallback is switched **off** while confined, because a bind that
fails has to fail rather than quietly land somewhere else.

**Known gap: name lookups are not confined.** Tracker and web-seed hostnames
are resolved by the system resolver, which is not bound to the device. The
connections themselves are, but with a split tunnel or a VPN that doesn't push
its own DNS, the ISP's resolver sees which trackers are being contacted.
Closing it needs a SOCKS proxy with `proxy_hostnames`; don't claim otherwise in
the UI or on the site.

`.unavailable` is a real instruction meaning "bind to nothing", and is not the
same value as `.unrestricted`. Keeping them as separate cases rather than an
optional device name is deliberate: they want opposite behaviour and an
optional lets a caller confuse them. There is no setting to carry on without
the connection you asked for, and there should not be one.

## The throughput meter

The inspector's Activity tab draws the last 90 seconds of one torrent's
traffic as bars either side of a zero line — downloads below, uploads above.
`RateHistory` in `CurrentCore` is the window and the arithmetic; `RateGraph`
draws it; `LibraryStore` feeds it one sample per engine tick.

- **Bars, not a curve with an area under it.** That was the first version and
  on real data it drew a solid gradient slab with a flat line on top: a steady
  transfer has no shape, so nothing about it read as time passing. Ninety
  discrete bars have rhythm at any density, and the zero line is legible
  because it shows *through* the gaps instead of being buried under the
  densest end of two gradients.
- **The zero line is not centred.** `RateHistory.baselinePosition` splits the
  frame in proportion to the two peaks. A centred line wastes most of the card
  — an upload at a tenth of the download leaves nine tenths of the upper half
  as dead black — and it costs nothing to move: because each side's height is
  proportional to its own peak, a point of height is worth the same number of
  bytes in both, so the comparison a shared scale exists for survives. The
  line's height then *is* the give-and-take ratio.
- **One scale for both directions.** `RateHistory.scale` is the sum of the two
  peaks with 11% headroom and an 8 KB/s floor. Scaling the halves
  independently is the obvious mistake and it destroys the only question a
  mirrored chart answers.
- **Autoscaling is honest only because the scale is drawn.** The dotted guide
  sits level with the tallest bar and the header states what it was worth.
  Take either away and a torrent crawling at 30 KB/s looks exactly like one
  flying at 30 MB/s.
- **Three floors, each earned.** A bar is at least 2pt (`stub`) so a trickle
  reads as a trickle rather than as nothing; it starts 2pt clear of the line
  (`baselineGap`) or the two directions fuse into one stick with a green tip;
  and a moving direction gets at least 8% of the frame (`minimumShare`) so
  that stub has somewhere to go past about a 12:1 ratio. That last one is the
  only place the proportions are fudged.
- **Older bars fade** to 40% at the left edge, which is what makes the meter
  read as flowing rather than as a histogram. The scrub reads any of them
  exactly, so nothing is hidden.
- **The sample is recorded *after* `blockedByNetwork()`**, so a torrent cut off
  from its confined connection flatlines. Recording the engine's own figures
  would draw traffic over sockets the app had just shut.
- **Nothing is tweened between ticks.** The frame is fixed
  (`Size.rateGraph`) and the two live numbers sit in fixed-width slots, because
  this is the only view in the app whose content changes on *every* tick — see
  the layout-churn section.
- Hovering scrubs the readings back through the window. It has no keyboard
  path and doesn't need one: everything it reveals is already written out on
  the panel, so it adds detail rather than being the only way to reach it.

**The simulator produces wobbling rates now, and it has to.** Simulated speeds
were a constant per torrent, to the byte — invisible while every surface showed
one number at a time, and a dead straight line the moment something plotted
them. `speedFactor(for:step:)` is two sine waves at unrelated periods, phased
per torrent and driven by the tick count rather than by `random`, so `step()`
stays reproducible. `SimulationFidelityTests` guards it.

## Where a download goes

The save folder is chosen on the confirm card, not at add time, and that
ordering is forced: a magnet is an unresolved hash when it arrives, so there is
no name and no size to decide against yet. The torrent is added to the default
folder *held* (see the architecture rules), resolves, stops, and only then
does `applyMagnetSelection` move it — `engine.setSaveDirectory` before
`resume`, while nothing has touched the disk. Held is what makes "nothing has
touched the disk" true rather than hoped.

- **That needs `lt_set_save_path` in the shim** (`move_storage` with
  `dont_replace`). It is safe here precisely because the torrent hasn't written
  anything; on a torrent with data it would really move files, and the app has
  no path that does.
- **Some folders can't be chosen at all** (`SaveLocation.refusal`, enforced in
  the open panel by `SaveFolderValidator`): the home folder, `~/Library`, the
  top of a disk, system folders. libtorrent writes into files that already
  exist, so with home as the save folder a torrent called `.zshrc` replaces
  the shell's startup file.
- **Both the engine and the record have to learn the new folder.** The engine's
  `saveDirectories` map is what snapshots report, so Finder reveals the right
  place; `LibraryStore.updateSaveDirectory` is what survives a relaunch, since
  `restoreResumeData` re-adds from the record. Miss the second and the folder
  you picked lasts until you quit.
- **"Remember this location" sets the default *and* turns the question off**
  (`settings.asksForDownloadLocation`). Settings is the only way back on, which
  is why that switch has to stay next to the folder it falls back to.
- `.torrent` files go through the same card, so they get the same question —
  but only when the flow is idle. Opening ten of them at once asks about the
  first and sends the rest to the default, rather than queueing ten questions.
- The inspector's **Location** group already existed and now earns its keep:
  before this it said the same thing on every torrent in the library.

## The engine boundary — four things that were each silently broken

- **Resume data is not a .torrent file.** It is restored through
  `lt_add_resume_data` (`read_resume_data`) and saved with `save_info_dict`.
  Until this was fixed, restores went through the .torrent parser, which
  rejects resume data, and a `try?` swallowed it: **no torrent the engine was
  running ever came back after a relaunch**, in every release up to 1.2.0.
  Nothing noticed because the simulator's resume data is its own JSON.
  `RealEngineTests.testResumeDataRestoresTheTorrentInAFreshSession` is the
  guard. Restore failures are counted and shown, never swallowed. Resume data
  is saved on add, when metadata arrives, every five minutes and at quit —
  all at once, not one torrent at a time under the quit budget.
- **Nothing libtorrent throws may leave the shim.** It throws on a handle whose
  torrent was just removed, and removal races everything. The worker thread is
  a bare `std::thread` (an escaping exception is `std::terminate`), and every
  `extern "C"` function runs its body in `guarded`.
- **Events are lossless and in order.** One unbounded inbound stream with one
  consumer. It was a `Task` per event (unordered) into a stream that kept the
  newest 32, so restoring more than 32 torrents lost metadata events at launch.
  Removal ids come from `torrent_removed_alert::info_hashes` — the handle is
  already invalid and read as all zeros.
- **Stats are one call per tick**, `get_torrent_status`, not `status()` per
  handle; handles are found with `find_torrent`, not by scanning the session.

A magnet's trackers, web seeds and `x.pe` peers are text a web page wrote, and
libtorrent contacts them the moment it's added. `strip_local_targets` drops
any that point at a literal loopback, private or link-local address, or at
`localhost`/`.local` — otherwise a link is a way to make this Mac send
requests to the user's own router. Hostnames that *resolve* to the LAN are not
caught. Downloads are quarantined (`LSFileQuarantineEnabled`), so an app in a
torrent meets Gatekeeper before it runs.

`RealEngineTests` build torrents from local files, join two sessions over
`lo0` with `connectPeer` (test-only), and prove each of the above against the
real library — including that the fixes fail the old code. Engines in tests
take `statePath: ""` so they never read or overwrite the real client's DHT
table.

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
- **A window that opens with live content measures itself once.** The menu bar
  panel sets its frame from `fittingSize` at the moment it opens and never
  again, and `StatusPanelModel` freezes *which* transfers it lists for as long
  as it's on screen — only the numbers inside them move. Both halves are
  needed. Which torrents count as "active" flickers constantly in normal
  operation, so an unfrozen list would reshuffle and resize under a stationary
  cursor, and a window tracking its content would renegotiate its frame every
  second. The old notch card learned the first half the hard way; the panel
  gets both for free by inheriting the pattern.
- **Any change to window frames, column widths, or list content must be
  soak-tested for 3 minutes** against `-simulate`, checking
  `~/Library/Logs/DiagnosticReports/` for new `Current-*.ips` files. A build
  that passes tests and looks fine for ten seconds tells you nothing here.
  Resize the window across the compact thresholds while it soaks — idling at
  one size exercises none of this.

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

## Conventions

- Swift 6 language mode is on for every target. New concurrent code should compile
  without `@unchecked Sendable` escape hatches.
- Engine events cross the actor boundary as `Sendable` values — payloads are copied
  out of libtorrent alerts on the worker thread, never passed as references.
- Keep diffs focused: one behavior per PR. New motion gets its frequency and
  duration justified in the PR description.
- No accounts, no analytics, no tracking, no network calls beyond the torrent
  protocol itself. Torrent history stays local.

## Long tasks: when to keep going, when to stop

These came from Anthropic's Opus 5.5 guidance (Sep 2026). They hold for any agent.

- **Keep going when a step doesn't need me.** Put status notes in the same message as your next
  action. Stop and ask only when you can't continue without me, or before anything destructive
  or outward-facing: deleting data, force-pushing, deploying to production, sending anything
  external, or changing anything outside this repository.
- **Know what "done" is before you start.** If the request doesn't define it, write the finish
  line down first (what works, what's gone, which checks pass) and work to it.
- **Keep the task list in a file, not in the conversation.** For work longer than one sitting,
  use the active goal in `.claude/goals/` if there is one, otherwise a `TASKS.md` checklist at
  the repo root (don't commit it). Tick items off as you go; re-read it after the conversation
  is summarized.
- **Split big audits and migrations across subagents.** Give each independent area its own
  subagent. When one reports back, check its evidence before you accept it.
- **Review your own diff before calling it done.** List only problems you'd block the merge
  for — where, why it's wrong, how to show it fails — and fix them.
- **Mark anything you couldn't confirm**, and say where you looked.
- **Lead the final message with what needs me.** Anything waiting on my input comes first (or
  say plainly that nothing is), then the summary.
- **Don't write "think hard" / "think carefully" into prompts, skills, goals or instructions.**
  The model already thinks before it replies; those lines only slow it down.
