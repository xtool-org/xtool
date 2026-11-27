// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DemoTCA",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "DemoTCA",
            targets: ["DemoTCA"]
        ),
    ],
    dependencies: [
        .package(path: "../ExampleSupport"),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture.git", from: "1.0.0"),
        // we don't use this but need the explicit dependency to keep the lockfile stable.
        // TODO: remove once https://github.com/pointfreeco/combine-schedulers/issues/120 is fixed
        .package(url: "https://github.com/OpenCombine/OpenCombine.git", from: "0.14.0"),
    ],
    targets: [
        .target(
            name: "DemoTCA",
            dependencies: [
                "ExampleSupport",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ],
        ),
    ]
)
