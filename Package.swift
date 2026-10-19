// swift-tools-version: 6.1
import PackageDescription
import Foundation

let includesVLC = FileManager.default.fileExists(atPath: "Vendor/VLCKit.xcframework")
var playbackDependencies: [Target.Dependency] = ["AudilseCore"]
var optionalTargets: [Target] = []
if includesVLC {
    playbackDependencies.append("VLCKit")
    optionalTargets.append(.binaryTarget(name: "VLCKit", path: "Vendor/VLCKit.xcframework"))
}

let package = Package(
    name: "Audilse",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AudilseCore", targets: ["AudilseCore"]),
        .library(name: "AudilsePlayback", targets: ["AudilsePlayback"]),
        .executable(name: "Audilse", targets: ["Audilse"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/socketio/socket.io-client-swift.git", exact: "16.1.1")
    ],
    targets: [
        .target(name: "AudilseCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "SocketIO", package: "socket.io-client-swift")
        ]),
        .target(name: "AudilsePlayback", dependencies: playbackDependencies),
        .executableTarget(name: "Audilse", dependencies: ["AudilseCore", "AudilsePlayback"],
                          resources: [.process("Resources")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "AudilseCoreTests", dependencies: ["AudilseCore"]),
        .testTarget(name: "AudilsePlaybackTests", dependencies: ["AudilsePlayback"])
    ] + optionalTargets,
    swiftLanguageModes: [.v6]
)
