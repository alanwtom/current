# Speed, motion, and user-flow pass — 25 October 2026

Changes are local. No release or website deployment was made. The final
artifact/device gates in RELEASE-AUDIT-2026-10-25.md still apply.

## Measurements

Same Mac, release build, compact window, six simulated transfers. CPU was
sampled for 20 seconds with `ps`. These are single local samples, not network
throughput, frame-rate, or results for other Macs.

| Measurement | Before | After |
| --- | ---: | ---: |
| Mean sampled app CPU | 26.2% | 14.5% |
| Peak sampled resident memory | 135.3 MiB | 122.6 MiB |
| Bulk priority edit: 5,000 files, 1,000 selected (debug) | 0.868 s | 0.00212 s |

CPU was about 45% lower in these samples. The bulk file edit was about 409 times
faster in the first focused run. Later runs also showed the same large reduction.
The original paused app used about 0.41% CPU in a separate 15-second sample.
Logs and samples: `.build/polish-audit/`.

## Changes

- Window layout observes only section, selected torrent ID, and pause-command
  state. Live transfer updates stay in the list and inspector.
- The file picker filters and flattens rows once per render. Bulk priorities
  take one tree pass, one state update, and one engine update.
- Slow status paint runs at most 30 times per second. Native interaction springs
  retain their normal cadence. Indeterminate progress and spinners use a clock
  rather than persistent repeat animations.
- Reduce Motion stops continuous loops and snaps switch/selection geometry.
  Slider hover, radio scale, and symbol replacement follow this setting.
- Checkboxes are keyboard buttons. Sliders accept arrow keys and show focus.
  Keyboard focus holds a toast open and reveals its dismiss control.
- The file picker supports arrow selection, Space to include/skip, and Return
  to confirm. Empty selections cannot start. The filter remains available for
  typing. These keys are scoped to the modal picker.
- Cancel invalidates a pending approval before removal waits. Duplicate
  confirmation is refused. Old completion timers cannot dismiss new feedback.
- Uppercase magnet schemes now work in paste, drop, and add paths. The engine
  normalizes the scheme because libtorrent itself accepts only lowercase.
  Query text retains its original case. The extraction expression is cached.
- Default focus is explicit for modal fields. The palette no longer clears
  text in a late entrance callback. Fast typing reaches the command field.
- Simulation does not claim the system's magnet handler. Its file metadata and
  row sizes agree, and file layouts/sizes repeat across launches.

## Verification

- Final full suite: 354 tests, seven public-network tests skipped, no failures.
  See `tests-final.log`.
- Release bundle, strict complexity, and strict recursive signature checks pass.
- Native checks already verified uppercase input and direct cold-launch URL
  delivery through LaunchServices, held approval, file selection/cancel,
  keyboard command search, and matching card/row sizes.
- Final native checks passed keyboard confirmation, zero-selection blocking,
  pause/resume, search, live inspector/activity, cancellation, native torrent
  open, and close/reopen. The final app stayed responsive for 335 seconds with
  no new crash reports. See `final-soak-result.json`.
- Compact and expanded layouts were checked during the pass. The final drag
  resize attempt was rejected by the UI automation tool; layout math tests pass.
- Repeated file selection after a refused empty confirmation uses arrow keys
  to re-enter row navigation. Typing returns to the filter.

## Limits

The cold-launch check targets the test app through LaunchServices. It is not a
browser-default-handler test. Public network tests, true VoiceOver navigation,
OS Reduce Motion switching, a clean second Mac, and final signed updater
installation remain separate checks. No claim of perfect frame pacing is made.

Focus behavior was checked against
[Apple default-focus documentation](https://developer.apple.com/documentation/swiftui/view/defaultfocus(_:_:priority:)).
