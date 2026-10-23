// swift-tools-version: 6.0
import PackageDescription

// The package carries the kit and its tests; the app, its extensions, and the watch app
// build through the Xcode project, which owns entitlements and embedding.
let package = Package(
    name: "skerry",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SkerryKit", targets: ["SkerryKit"])
    ],
    targets: [
        // The kit compiles optimized even in debug: the memory-hard KDF is unusably slow
        // at -Onone, and debug app builds are what gets dogfooded on the phone.
        .target(
            name: "SkerryKit",
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(name: "SkerryKitTests", dependencies: ["SkerryKit"]),
    ]
)
