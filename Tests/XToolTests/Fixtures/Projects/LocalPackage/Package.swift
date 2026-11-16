// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalPackage",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Library", targets: ["Library"]),
        .library(name: "DynamicLibrary", type: .dynamic, targets: ["DynamicLibrary"]),
    ],
    targets: [
        .target(name: "Library", dependencies: ["Helper"], resources: [.process("Message.txt")]),
        .target(name: "Helper"),
        .target(name: "DynamicLibrary"),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
    ]
)
