// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "ExampleSupport",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "ExampleSupport",
            targets: ["ExampleSupport"]
        ),
        .library(
            name: "ExampleDynamicLibrary",
            type: .dynamic,
            targets: ["ExampleDynamicLibrary"]
        ),
    ],
    targets: [
        .target(name: "ExampleSupport"),
        .target(
            name: "ExampleDynamicLibrary",
            resources: [
                .process("response.txt"),
            ]
        ),
    ]
)
