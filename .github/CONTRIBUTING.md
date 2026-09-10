# Contributing to Current

Thanks for helping make Current better. The bar here is craft, not feature
count — please read the short rules below before opening a PR.

## Principles

1. **Quiet by default.** If an animation or notification doesn't help the user
   understand something, it doesn't ship.
2. **Automation must explain itself.** Any automatic behavior writes a
   human-readable reason to the decision log.
3. **Cleanup is reversible.** Automatic paths may only move files to Trash.
4. **Engine complexity stays in engines.** UI code never imports LTShim.
5. **Keyboard parity.** Every mouse interaction needs a keyboard path, and
   keyboard actions never wait on decorative animation.

## Development

```sh
brew install libtorrent-rasterbar
swift build
swift test
Scripts/make-app.sh --release
```

Run the deterministic demo with `-simulate` — useful for screenshots and UI
work without touching real networks.

## Pull requests

- Keep diffs focused; one behavior per PR.
- Add tests for anything in `CurrentCore` (it must stay pure and 100%
  logic-tested).
- New motion: justify frequency and duration in the PR description.
  UI animations stay under ~300 ms; springs are critically damped unless a
  gesture justifies bounce; Reduce Motion must degrade gracefully.
- Update `docs/ARCHITECTURE.md` when moving boundaries.

## Issues

Please use the templates. For bugs include: macOS version, Mac model,
steps to reproduce, expected vs actual, and whether `-simulate` reproduces it.
