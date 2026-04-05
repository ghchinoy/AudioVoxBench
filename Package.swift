// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioVoxBench",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AudioVoxBench", targets: ["AudioVoxBench"]),
        .executable(name: "TrackSeeder", targets: ["TrackSeeder"]),
        .executable(name: "TrackIngestor", targets: ["TrackIngestor"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.3")
    ],
    targets: [
        .executableTarget(
            name: "AudioVoxBench",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "sqlite_vec"
            ],
            swiftSettings: [.define("CLI")]
        ),
        .executableTarget(
            name: "TrackSeeder",
            dependencies: [],
            swiftSettings: [.define("CLI")]
        ),
        .executableTarget(
            name: "TrackIngestor",
            dependencies: [],
            swiftSettings: [.define("CLI")]
        ),
        .target(
            name: "sqlite_vec",
            dependencies: [],
            path: "Sources/sqlite_vec",
            publicHeadersPath: ".",
            cSettings: [
                .define("SQLITE_CORE"),
            ]
        )
    ]
)
