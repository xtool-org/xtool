// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DemoAudioUnit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "DemoAudioUnit", targets: ["DemoAudioUnit"]),
        .library(name: "DemoAudioUnitExtension", targets: ["DemoAudioUnitExtension"]),
    ],
    dependencies: [
        .package(path: "../ExampleSupport"),
    ],
    targets: [
        .target(name: "DemoAudioUnit", dependencies: ["ExampleSupport"]),
        .target(name: "DemoAudioUnitExtension"),
    ]
)
