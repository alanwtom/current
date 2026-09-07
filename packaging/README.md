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

## It is live in a personal tap

<https://github.com/alanwtom/homebrew-tap>

```
brew install --cask alanwtom/tap/current
```

That single command taps the repo and installs; no `brew tap` step needed. No
approval and no notability rule applies to a personal tap. When Current clears
one of the three thresholds above, the identical cask goes to homebrew-cask and
the shorter `brew install --cask current` starts working — nothing in the file
needs to change.

Verified: `brew info --cask alanwtom/tap/current` resolves and reports
"Required: arm64 architecture, macOS >= 26", which also confirms the
`depends_on macos: :tahoe` semantics. `brew fetch --cask` downloads and matches
the pinned checksum. CI passes on the published repo.

**Not** verified: the actual install on a clean machine, because this one
already has Current in /Applications from the update test and a cask install
would refuse or overwrite it.

## How the tap is hardened

A tap is a place people run installs from, so the threat is someone changing a
URL and a checksum together and every `brew install` fetching whatever they
like. What is in place:

- **Nothing in the repo can write to the repo.** One workflow, `contents: read`,
  and the default workflow token is read-only at the repository level. Actions
  cannot approve or open pull requests.
- **`brew tap-new`'s scaffolding was deleted.** It ships a daily autobump and a
  bottle publisher, both needing write access, for formulae this tap does not
  have. Bumping stays manual on purpose: a bot that can bump a cask is a bot
  that can rewrite a URL and a checksum in one commit, on a schedule.
- **Only vetted actions can run** — GitHub's own plus `Homebrew/actions/*`, and
  every use is pinned to a commit hash rather than a tag.
- **`main` is protected**: no force pushes, no deletion, linear history, and CI
  must pass. The required check is named `test` and the workflow's job is named
  `test` — worth checking they match, because a required check that never
  reports blocks every merge forever.
- **Secret scanning and push protection are on**, and wiki and projects are off.
- **CI re-audits each cask against its live download**, not just its syntax, so
  an upstream release re-cut under an existing tag fails in CI rather than on
  someone's laptop.

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
  `1.2.0,85` (version and build) while the download URL only carries `1.2.0`.
  Without the modifier the audit reports the cask as out of step with its own
  update feed.
- **The `zap` list is the real set of paths the app writes**, read off a running
  install rather than guessed: the library database and the DHT routing table
  in Application Support, plus the usual per-app plists and caches under the
  `org.current.torrent` bundle identifier.

## Regenerating it for a new release

Version and checksum are the only two lines that change:

```bash
shasum -a 256 site/Current.dmg | cut -d' ' -f1   # -> sha256
```

`brew bump-cask-pr` automates this once the cask is in a tap.

**Nothing does this for you, and that is how it goes stale.** `Scripts/release.sh`
rebuilds the disk image, signs the appcast and copies both into `site/` — it does
not touch this file, and the "what's left to do" list it prints at the end did not
mention it either. So 1.2.0 shipped, the download page and the update feed were
correct, and the cask sat on 1.1.1 for a while: a fresh `brew install --cask`
handed people the previous version, which Sparkle then quietly updated out from
under them. `Scripts/release.sh` prints the reminder now.

**Bump it in two places, and the tap is the one that matters.** This copy is the
source of truth to read; `alanwtom/homebrew-tap` is what `brew install` actually
fetches. Send the tap a pull request rather than pushing to its `main` — branch
protection there lets an admin push straight through, but its CI re-audits the
cask against the *live* download, which is exactly the check that catches a
wrong checksum before somebody's install breaks instead of after.
