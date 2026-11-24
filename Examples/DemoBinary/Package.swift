// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DemoBinary",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "DemoBinary",
            targets: ["DemoBinary"]
        ),
    ],
    dependencies: [
        .package(path: "../ExampleSupport"),
        .package(url: "https://github.com/krzyzanowskim/OpenSSL", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "DemoBinary",
            dependencies: [
                "ExampleSupport",
                "OpenSSL",
            ]
        ),
    ]
)
