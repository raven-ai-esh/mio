// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mio",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MioCore", targets: ["MioCore"]),
        .library(name: "MioBridge", targets: ["MioBridge"]),
        .library(name: "MioCloud", targets: ["MioCloud"]),
        .library(name: "MioEmbeddings", targets: ["MioEmbeddings"]),
        .executable(name: "Mio", targets: ["Mio"]),
        .executable(name: "MioBench", targets: ["MioBench"])
    ],
    targets: [
        .target(name: "CSQLite", path: "Sources/CSQLite", publicHeadersPath: "include", cSettings: [.define("SQLITE_ENABLE_FTS5"), .define("SQLITE_THREADSAFE", to: "1")]),
        .target(name: "MioCore", dependencies: ["CSQLite"]),
        .target(name: "MioBridge", dependencies: ["MioCore"]),
        .target(name: "MioCloud", dependencies: ["MioCore"]),
        .target(name: "MioEmbeddings", dependencies: ["MioCore"], resources: [.copy("ModelManifest.json")]),
        .executableTarget(name: "Mio", dependencies: ["MioCore", "MioBridge", "MioCloud", "MioEmbeddings"], resources: [.process("Resources")]),
        .executableTarget(name: "MioBench", dependencies: ["MioCore", "MioBridge", "MioEmbeddings"]),
        .testTarget(name: "MioCoreTests", dependencies: ["MioCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MioBridgeTests", dependencies: ["MioBridge", "MioCore"]),
        .testTarget(name: "MioCloudTests", dependencies: ["MioCloud", "MioCore"]),
        .testTarget(name: "MioEmbeddingsTests", dependencies: ["MioEmbeddings", "MioCore"]),
        .testTarget(name: "MioAppTests", dependencies: ["Mio", "MioCore"])
    ],
    swiftLanguageModes: [.v5]
)
