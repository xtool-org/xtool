// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DemoSimple",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "DemoSimple",
            targets: ["DemoSimple"]
        ),
    ],
    dependencies: [
        .package(path: "../ExampleSupport"),
    ],
    targets: [
        .target(
            name: "DemoSimple",
            dependencies: [
                "ExampleSupport",
            ]
        ),
    ]
)
