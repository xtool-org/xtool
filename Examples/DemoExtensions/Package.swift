// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DemoExtensions",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "DemoExtensions",
            targets: ["DemoExtensions"]
        ),
        .library(
            name: "DemoExtensionsWidget",
            targets: ["DemoExtensionsWidget"]
        ),
    ],
    dependencies: [
        .package(path: "../ExampleSupport"),
    ],
    targets: [
        .target(
            name: "DemoExtensions",
            dependencies: [
                "ExampleSupport",
            ]
        ),
        .target(name: "DemoExtensionsWidget"),
    ]
)
