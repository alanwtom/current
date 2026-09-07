cask "current" do
  version "1.1.1"
  sha256 "8d93873a0ffb4c4481a8bd0ed8d8011fb404610274a2ef2005dcb6b086da25be"

  # The GitHub release asset rather than the download page, because a cask needs
  # a URL that is pinned to a version and never changes under it. The page's
  # /Current.dmg always points at the newest build, so its checksum would go
  # stale the moment a release shipped. Both files are byte-identical today —
  # checked, same SHA-256.
  url "https://github.com/alanwtom/current/releases/download/v#{version}/Current.dmg"
  name "Current"
  desc "BitTorrent client that stays quiet when idle and explains its automation"
  homepage "https://current.alantom.dev/"

  livecheck do
    url "https://current.alantom.dev/appcast.xml"
    # `&:short_version` because the download URL only carries "1.1.1". Without
    # it livecheck reads Sparkle's "1.1.1,61" and the audit reports the cask as
    # out of step with its own update feed.
    strategy :sparkle, &:short_version
  end

  # Sparkle updates the app in place, so Homebrew should not treat a
  # self-updated copy as out of date and reinstall over the top of it.
  auto_updates true
  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "Current.app"

  # Everything the app writes. The library database and the DHT routing table
  # live in Application Support; the rest is the usual macOS per-app furniture.
  zap trash: [
    "~/Library/Application Support/Current",
    "~/Library/Caches/org.current.torrent",
    "~/Library/Preferences/Current.plist",
    "~/Library/Preferences/org.current.torrent.plist",
    "~/Library/Saved Application State/org.current.torrent.savedState",
  ]
end
