# Homebrew

`current.rb` is the cask, and it is finished and audited. Where it can go is
the only open question.

## It cannot go into homebrew-cask yet

`brew audit --cask --new` gives exactly one remaining failure:

```
GitHub repository not notable enough (<30 forks, <30 watchers and <75 stars)
```

That is a hard gate in their audit tool, and it is worth knowing that their
written policy does *not* mention numbers — the docs only say a new app "may
receive further consideration when there is substantial, independently
verifiable public interest". The tool is where the real threshold lives:

**75 stars, or 30 forks, or 30 watchers.** Any one of the three. The repo is
currently at 1 star, so this is a "come back later" rather than a "no".

## It can go into your own tap today

A tap is just a GitHub repo named `homebrew-<something>`, so:

1. Create a public repo `alanwtom/homebrew-tap`.
2. Put this file at `Casks/current.rb` in it.
3. Anyone can then install with:

```
brew install --cask alanwtom/tap/current
```

No approval, no notability rule, works immediately. Same command shape people
already expect, just with your name in it. When the repo clears one of the
three thresholds above, the identical file can be submitted to homebrew-cask
and the shorter `brew install --cask current` starts working.

## Things in here that were not obvious

- **The URL is the GitHub release asset, not the download page.** A cask pins a
  checksum to a URL, and `current.alantom.dev/Current.dmg` always serves the
  newest build — so its checksum would go stale the moment a release shipped,
  breaking installs for everyone who had not updated. The release asset is
  immutable. Both files are byte-identical today; that was checked, not assumed.
- **`depends_on macos: :tahoe` means macOS 26 *or newer*,** not exactly 26. The
  cask DSL passes a `>=` comparator, confirmed in Homebrew's own source. The
  `">= :tahoe"` string form that reads more obviously is deprecated.
- **`auto_updates true`** because Sparkle updates the app in place. Without it
  Homebrew would consider a self-updated copy out of date and reinstall over
  the top of it.
- **`strategy :sparkle, &:short_version`** because the appcast advertises
  `1.1.1,61` (version and build) while the download URL only carries `1.1.1`.
  Without the modifier the audit reports the cask as out of step with its own
  update feed.
- **The `zap` list is the real set of paths the app writes**, read off a running
  install rather than guessed: the library database and the DHT routing table
  in Application Support, plus the usual per-app plists and caches under the
  `org.current.torrent` bundle identifier.

## Regenerating it for a new release

Version and checksum are the only two lines that change:

```bash
V=1.1.2
shasum -a 256 site/Current.dmg | cut -d' ' -f1   # -> sha256
```

`brew bump-cask-pr` automates this once the cask is in a tap.
