// swift-tools-version:5.3

import PackageDescription

let cSettings: [CSetting] = [
    .define("_GNU_SOURCE", .when(platforms: [.linux])),
    // see comment in SupersignLdid
    .headerSearchPath("../../vendored/include", .when(platforms: [.macOS, .iOS])),
]

let package = Package(
    name: "Supersign",
    platforms: [
        .iOS("13.0"),
        .macOS("10.11")
    ],
    products: [
        .library(
            name: "Supersign",
            type: .dynamic,
            targets: ["Supersign"]
        ),
        .executable(
            name: "SupersignCLI",
            targets: ["SupersignCLI"]
        )
    ],
    dependencies: [
        .package(path: "../SuperchargeCore"),
        .package(path: "../SwiftyMobileDevice"),
        .package(path: "../USBMuxSim"),
        .package(path: "../SupersignLdid"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "CSupersign",
            dependencies: [
                .product(name: "OpenSSL", package: "SuperchargeCore")
            ],
            cSettings: cSettings
        ),
        .target(
            name: "Supersign",
            dependencies: [
                "CSupersign",
                "SwiftyMobileDevice",
                .product(name: "PortForwarding", package: "USBMuxSim", condition: .when(platforms: [.iOS])),
                .product(name: "USBMuxSim", package: "USBMuxSim", condition: .when(platforms: [.iOS])),
                .product(name: "SignerSupport", package: "SuperchargeCore"),
                .product(name: "ProtoCodable", package: "SuperchargeCore"),
                .product(name: "Superutils", package: "SuperchargeCore"),
                .product(
                    name: "AsyncHTTPClient",
                    package: "async-http-client",
                    condition: .when(platforms: [.linux])
                )
            ],
            cSettings: cSettings
        ),
        .testTarget(
            name: "SupersignTests",
            dependencies: [
                "Supersign",
                .product(name: "SuperutilsTestSupport", package: "SuperchargeCore")
            ],
            exclude: [
                "config/config-template.json",
            ],
            resources: [
                .copy("config/config.json"),
                .copy("config/test.app"),
            ]
        ),
        .target(
            name: "SupersignCLI",
            dependencies: [
                "SwiftyMobileDevice",
                "Supersign",
                "SupersignLdid"
            ],
            resources: [
                .copy("Supercharge.ipa")
            ],
            cSettings: cSettings
        )
    ]
)
