cask "current" do
  version "1.2.0"
  sha256 "ae731ffb6b1e744df48f4f910decc876df3e0ff72c91f80ae8dd321e6f83556a"

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
    # `&:short_version` because the download URL only carries "1.2.0". Without
    # it livecheck reads Sparkle's "1.2.0,85" and the audit reports the cask as
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
