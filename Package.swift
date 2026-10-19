// swift-tools-version: 6.1
import PackageDescription
import Foundation

let includesVLC = FileManager.default.fileExists(atPath: "Vendor/VLCKit.xcframework")
var playbackDependencies: [Target.Dependency] = ["ShelfCore"]
var optionalTargets: [Target] = []
if includesVLC {
    playbackDependencies.append("VLCKit")
    optionalTargets.append(.binaryTarget(name: "VLCKit", path: "Vendor/VLCKit.xcframework"))
}

let package = Package(
    name: "ShelfMac",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ShelfCore", targets: ["ShelfCore"]),
        .library(name: "ShelfPlayback", targets: ["ShelfPlayback"]),
        .executable(name: "ShelfMac", targets: ["ShelfMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/socketio/socket.io-client-swift.git", exact: "16.1.1")
    ],
    targets: [
        .target(name: "ShelfCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "SocketIO", package: "socket.io-client-swift")
        ]),
        .target(name: "ShelfPlayback", dependencies: playbackDependencies),
        .executableTarget(name: "ShelfMac", dependencies: ["ShelfCore", "ShelfPlayback"],
                          resources: [.process("Resources")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "ShelfCoreTests", dependencies: ["ShelfCore"]),
        .testTarget(name: "ShelfPlaybackTests", dependencies: ["ShelfPlayback"])
    ] + optionalTargets,
    swiftLanguageModes: [.v6]
)
