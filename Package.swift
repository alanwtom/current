// swift-tools-version: 6.2

import PackageDescription
import Foundation

/// Where Homebrew put libtorrent.
///
/// This used to be `/opt/homebrew` written twice, which builds on exactly one
/// kind of machine: Apple Silicon with Homebrew at its default prefix. On an
/// Intel Mac (`/usr/local`) or any custom prefix the build failed at the first
/// `#include`, so "clone it and build" was untrue for anyone but the author —
/// a small pool to draw contributors from.
///
/// Probed rather than guessed, and overridable, in that order:
///
///   1. `CURRENT_BREW_PREFIX`, for a prefix in neither usual place.
///   2. The two standard prefixes, checked for libtorrent's headers rather than
///      for the directory — Homebrew being installed is not the same as this
///      dependency being installed, and failing on the missing header gives a
///      far better error than failing on a missing symbol at link time.
///
/// Falls back to the Apple Silicon default so the manifest still parses when
/// libtorrent is absent; the build then fails with a plain "file not found",
/// which is the right message.
let brewPrefix: String = {
    let manager = FileManager.default
    if let override = ProcessInfo.processInfo.environment["CURRENT_BREW_PREFIX"],
       !override.isEmpty {
        return override
    }
    for candidate in ["/opt/homebrew", "/usr/local"]
    where manager.fileExists(atPath: candidate + "/include/libtorrent") {
        return candidate
    }
    return "/opt/homebrew"
}()

let libtorrentInclude = brewPrefix + "/include"
let libtorrentLib = brewPrefix + "/lib"

let package = Package(
    name: "Current",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Current", targets: ["CurrentApp"]),
        .library(name: "CurrentCore", targets: ["CurrentCore"]),
    ],
    targets: [
        .target(
            name: "CurrentCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LTShim",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++20", "-I\(libtorrentInclude)"]),
                // These are NOT optional and NOT cosmetic. libtorrent bakes
                // several of them into its own build, and a few — notably
                // TORRENT_ABI_VERSION and TORRENT_SSL_PEERS — change the
                // layout of structs like `torrent_status`. Compiling the shim
                // without them made every field we read come back as garbage:
                // `has_metadata` false on a fully-downloaded torrent, negative
                // progress, and a "downloaded" figure in the tens of GB that
                // changed every tick. The engine worked fine; we were simply
                // reading the wrong bytes.
                //
                // This list is copied verbatim from
                // INTERFACE_COMPILE_DEFINITIONS in
                //   /opt/homebrew/lib/cmake/LibtorrentRasterbar/*.cmake
                // If you upgrade libtorrent, re-read that file — do not guess.
                .define("TORRENT_LINKING_SHARED"),
                .define("TORRENT_ABI_VERSION", to: "2"),
                .define("TORRENT_USE_OPENSSL", to: "1"),
                .define("TORRENT_USE_LIBCRYPTO", to: "1"),
                .define("TORRENT_SSL_PEERS"),
                .define("BOOST_ASIO_ENABLE_CANCELIO"),
                .define("BOOST_ASIO_NO_DEPRECATED"),
                .define("BOOST_SYSTEM_USE_UTF8"),
                .define("OPENSSL_NO_SSL2"),
                .define("OPENSSL_NO_SSL3"),
                .define("OPENSSL_NO_TLS1"),
                .define("OPENSSL_NO_TLS1_1"),
                .define("OPENSSL_NO_DTLS1"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(libtorrentLib)",
                    "-ltorrent-rasterbar",
                    "-L/opt/homebrew/opt/openssl@3/lib",
                    "-lssl",
                    "-lcrypto",
                ])
            ]
        ),
        .target(
            name: "CurrentEngine",
            dependencies: ["CurrentCore", "LTShim"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CurrentSim",
            dependencies: ["CurrentCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "CurrentApp",
            dependencies: [
                "CurrentCore",
                "CurrentSim",
                "CurrentEngine",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CurrentCoreTests",
            dependencies: ["CurrentCore", "CurrentSim", "CurrentApp"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
