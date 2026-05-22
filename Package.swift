// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Proteles",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
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
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
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
        .target(
            name: "MudCore",
            dependencies: [
                "CZlib",
                "CLua",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "GRDB", package: "GRDB.swift")
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
            dependencies: ["MudCore"],
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
