// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Proteles",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "MudCore", targets: ["MudCore"]),
        .library(name: "MudUI", targets: ["MudUI"]),
        .library(name: "MudOutputView_macOS", targets: ["MudOutputView_macOS"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-algorithms.git", from: "1.2.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Sparkle is consumed only by the XcodeGen app target (D-100), not by any
        // SwiftPM library/test target here. But because the app references this
        // package by path, the *root* Package.resolved is the lock file both
        // `swift build` and `xcodebuild` write to — and SwiftPM (no Sparkle) vs
        // Xcode (with Sparkle) wrote different pin sets + originHashes, so the
        // file flip-flopped on every alternation between the gates and an app
        // build. Declaring Sparkle here too makes both resolvers emit a
        // byte-identical Package.resolved (verified), ending the churn. No target
        // links it, so `swift build` prints a benign "dependency 'sparkle' is not
        // used by any target" warning — the accepted cost (D-112).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(
            name: "CLua",
            exclude: ["LICENSE.txt"],
            cSettings: [
                // Enables the macOS/POSIX feature set (dlopen-based
                // package loading, etc.). The Lua environment is
                // sandboxed at runtime (D-10), not at compile time.
                .define("LUA_USE_MACOSX")
            ]
        ),
        // The vendored `lsqlite3` Lua↔SQLite binding (Tiago Dionizio / Doug
        // Currie, MIT). Lets MUSHclient-compat plugins read the mapper DB and
        // keep their own SQLite stores; sandboxed to a per-profile dir at
        // runtime. Links the system SQLite (same one GRDB uses).
        .target(
            name: "CLSQLite3",
            dependencies: ["CLua"],
            exclude: ["LICENSE.txt"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "MudCore",
            dependencies: [
                "CZlib",
                "CLua",
                "CLSQLite3",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [
                // Nick Gammon's MUSHclient helper libs (wait/check) — bundled
                // for the compat shim + dinv; see Resources/MUSHHelpers/PROVENANCE.md.
                // (Search-and-Destroy's own Lua is NOT bundled — it's a separate,
                // user-installed download; see SearchAndDestroyInstaller.)
                .copy("Resources/MUSHHelpers"),
                // Vendored dinv inventory manager (MIT; run verbatim through
                // the MUSHclient compat shim — see Resources/dinv/PROVENANCE.md).
                .copy("Resources/dinv"),
                // Vendored leveldb leveling database (MIT; run verbatim through
                // the compat shim — see Resources/leveldb/PROVENANCE.md).
                .copy("Resources/leveldb"),
                // Aardwolf's command list (from `help commands`) — the base
                // first-word completion vocabulary (#31).
                .copy("Resources/aardwolf-commands.txt"),
                // Aardwolf's skill/spell list (from `allspells all`) — the
                // `cast <spell>` argument source (#32).
                .copy("Resources/aardwolf-spells.txt")
            ]
        ),
        .target(
            name: "MudUI",
            dependencies: ["MudCore"]
        ),
        .target(
            name: "MudOutputView_macOS",
            dependencies: ["MudCore"]
        ),
        .testTarget(
            name: "MudCoreTests",
            dependencies: [
                "MudCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "MudUITests",
            dependencies: ["MudUI"]
        ),
        .testTarget(
            name: "MudOutputView_macOSTests",
            dependencies: ["MudOutputView_macOS"]
        )
    ],
    swiftLanguageModes: [.v6]
)
