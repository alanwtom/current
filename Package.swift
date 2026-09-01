// swift-tools-version: 6.2

import PackageDescription

let libtorrentInclude = "/opt/homebrew/include"
let libtorrentLib = "/opt/homebrew/lib"

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
                .define("TORRENT_USE_OPENSSL", to: "1"),
                .define("TORRENT_USE_LIBCRYPTO", to: "1"),
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
