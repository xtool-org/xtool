// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DemoResources",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "DemoResources",
            targets: ["DemoResources"]
        ),
    ],
    dependencies: [
        .package(path: "../ExampleSupport"),
    ],
    targets: [
        .target(
            name: "DemoResources",
            dependencies: [
                "ExampleSupport",
            ],
            resources: [
                .process("bundled.txt"),
            ]
        ),
    ]
)
