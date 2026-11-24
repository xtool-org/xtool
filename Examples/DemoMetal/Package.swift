// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DemoMetal",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "DemoMetal",
            targets: ["DemoMetal"]
        ),
    ],
    dependencies: [
        .package(path: "../ExampleSupport"),
    ],
    targets: [
        .target(
            name: "DemoMetal",
            dependencies: [
                "ExampleSupport",
            ],
            resources: [
                .process("shaders.metal")
            ],
        ),
    ]
)
