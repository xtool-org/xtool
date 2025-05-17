// swift-tools-version:6.0

import PackageDescription

let gitCommit: String? = Context.gitInformation?.currentCommit
let gitTag: String? = Context.gitInformation?.currentTag

let cSettings: [CSetting] = [
    .define("_GNU_SOURCE", .when(platforms: [.linux])),
    .define("XTL_GIT_COMMIT", to: gitCommit.map { "\"\($0)\"" } ?? "NULL"),
    .define("XTL_GIT_TAG", to: gitTag.map { "\"\($0)\"" } ?? "NULL"),
]

let package = Package(
    name: "xtool",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "XKit",
            targets: ["XKit"]
        ),
        .library(
            name: "XToolSupport",
            targets: ["XToolSupport"]
        ),
        .executable(
            name: "xtool",
            targets: ["xtool"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/xtool-org/xtool-core", .upToNextMinor(from: "1.3.0")),
        .package(url: "https://github.com/xtool-org/SwiftyMobileDevice", .upToNextMinor(from: "1.4.0")),
        .package(url: "https://github.com/xtool-org/zsign", .upToNextMinor(from: "1.4.0")),

        .package(url: "https://github.com/apple/swift-system", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.3.1"),
        .package(url: "https://github.com/apple/swift-certificates", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.9.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.77.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),

        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-async-http-client", from: "1.0.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),

        .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", from: "1.3.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.6.2"),

        .package(url: "https://github.com/attaswift/BigInt", from: "5.5.0"),
        .package(url: "https://github.com/mxcl/Version", from: "2.1.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.3"),
        .package(url: "https://github.com/saagarjha/unxip", from: "3.1.0"),

        // TODO: just depend on tuist/XcodeProj instead
        .package(url: "https://github.com/yonaskolb/XcodeGen", from: "2.43.0"),
    ],
    targets: [
        .systemLibrary(name: "XADI"),
        .target(
            name: "CXKit",
            dependencies: [
                .product(name: "OpenSSL", package: "xtool-core")
            ],
            cSettings: cSettings
        ),
        .target(
            name: "DeveloperAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            exclude: ["openapi-generator-config.yaml", "openapi-overlay.yaml"]
        ),
        .target(
            name: "XKit",
            dependencies: [
                "DeveloperAPI",
                "CXKit",
                .byName(name: "XADI", condition: .when(platforms: [.linux])),
                .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SwiftyMobileDevice", package: "SwiftyMobileDevice"),
                .product(name: "Zupersign", package: "zsign"),
                .product(name: "SignerSupport", package: "xtool-core"),
                .product(name: "ProtoCodable", package: "xtool-core"),
                .product(name: "Superutils", package: "xtool-core"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "HTTPTypesFoundation", package: "swift-http-types"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(
                    name: "OpenAPIAsyncHTTPClient",
                    package: "swift-openapi-async-http-client",
                    condition: .when(platforms: [.linux])
                ),
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
            name: "XToolTests",
            dependencies: [
                "XToolSupport",
            ]
        ),
        .testTarget(
            name: "XKitTests",
            dependencies: [
                "XKit",
                .product(name: "SuperutilsTestSupport", package: "xtool-core")
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
            name: "XToolSupport",
            dependencies: [
                "SwiftyMobileDevice",
                "XKit",
                "PackLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Version", package: "Version"),
                .product(name: "libunxip", package: "unxip"),
            ],
            cSettings: cSettings
        ),
        .target(
            name: "PackLib",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "XcodeGenKit", package: "XcodeGen", condition: .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "xtool",
            dependencies: [
                "SwiftyMobileDevice",
                "XKit",
                "XToolSupport",
            ],
            cSettings: cSettings
        ),
    ]
)
