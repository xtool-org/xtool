// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DemoPlugin",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "DemoPlugin",
            targets: ["DemoPlugin"]
        ),
    ],
    dependencies: [
        .package(path: "../ExampleSupport"),
    ],
    targets: [
        .executableTarget(
            name: "GreetingGenerator"
        ),
        .plugin(
            name: "GreetingPlugin",
            capability: .buildTool(),
            dependencies: [
                "GreetingGenerator",
            ]
        ),
        .target(
            name: "DemoPlugin",
            dependencies: [
                "ExampleSupport",
            ],
            plugins: [
                "GreetingPlugin",
            ]
        ),
    ]
)
