// swift-tools-version:5.3

import PackageDescription

let cSettings: [CSetting] = [
    .define("_GNU_SOURCE", .when(platforms: [.linux])),
]

extension Product.Library.LibraryType {
    static var smart: Self {
        #if os(Linux)
        return .static
        #else
        return .dynamic
        #endif
    }
}

let package = Package(
    name: "Supersign",
    platforms: [
        .iOS("14.0"),
        .macOS("11.0"),
    ],
    products: [
        .library(
            name: "Supersign",
            type: .smart,
            targets: ["Supersign"]
        ),
    ],
    dependencies: [
        .package(path: "../SuperchargeCore"),
        .package(path: "../SwiftyMobileDevice"),
        .package(path: "../USBMuxSim"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),
        .package(url: "https://github.com/apple/swift-certificates", from: "1.0.0"),
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
                .product(name: "X509", package: "swift-certificates"),
                .product(
                    name: "AsyncHTTPClient",
                    package: "async-http-client",
                    condition: .when(platforms: [.linux])
                ),
                .product(
                    name: "WebSocketKit",
                    package: "websocket-kit",
                    condition: .when(platforms: [.linux])
                ),
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
    ]
)
