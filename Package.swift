// swift-tools-version:6.2

import CompilerPluginSupport
import PackageDescription

let (xtoolVersion, hasUncommittedChanges): (String?, Bool) = {
    if let explicitVersion = Context.environment["XTOOL_VERSION"] {
        // when building with an explicit version, consider the tree clean.
        // we never want "-dirty" in a CI build.
        return (explicitVersion, false)
    } else if let info = Context.gitInformation {
        let gitCommit = info.currentCommit
        let gitTag = info.currentTag
        let gitRef = gitTag ?? "commit \(gitCommit)"
        return (gitRef, info.hasUncommittedChanges)
    } else {
        return (nil, false)
    }
}()

let cSettings: [CSetting] = [
    .define("_GNU_SOURCE", .when(platforms: [.linux])),
]

let cxkitCSettings: [CSetting] = cSettings + [
    .define("XTOOL_HAS_UNCOMMITTED_CHANGES", to: hasUncommittedChanges ? "1" : "0"),
] + (
    xtoolVersion
        .map { [.define("XTOOL_VERSION", to: "\"\($0)\"")] }
        ?? []
)

let swiftSettings: [SwiftSetting] = {
    var settings: [SwiftSetting] = []
    if Context.environment["XTL_CI"] == "1" {
        settings.append(.treatAllWarnings(as: .error))
    }
    return settings
}()

let package = Package(
    name: "xtool",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "XPIF", targets: ["XPIF"]),
        .library(name: "XcodePIFConversion", targets: ["XcodePIFConversion"]),
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
        .package(url: "https://github.com/xtool-org/xtool-core", .upToNextMinor(from: "1.5.1")),
        .package(url: "https://github.com/xtool-org/SwiftyMobileDevice", .upToNextMinor(from: "1.7.0")),
        .package(url: "https://github.com/xtool-org/swift-rcodesign", .upToNextMinor(from: "0.2.0")),
        .package(url: "https://github.com/xtool-org/swift-build", branch: "release/6.4.x"),

        .package(url: "https://github.com/apple/swift-system", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.3.1"),
        .package(url: "https://github.com/apple/swift-certificates", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.7.3"),
        .package(url: "https://github.com/apple/swift-crypto", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.7.1"),
        .package(url: "https://github.com/apple/xcode-project-format.git", .upToNextMinor(from: "0.1.0")),

        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "604.0.0"),

        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-async-http-client", from: "1.0.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),

        .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", from: "1.3.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.6.2"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.3"),
        // we don't use this but need the explicit dependency to keep the lockfile stable.
        // TODO: remove once https://github.com/pointfreeco/combine-schedulers/issues/120 is fixed
        .package(url: "https://github.com/OpenCombine/OpenCombine.git", from: "0.14.0"),

        .package(url: "https://github.com/attaswift/BigInt", from: "6.0.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.0.0"),
        .package(url: "https://github.com/saagarjha/unxip", from: "3.2.0"),

        // NB: this should only be imported from XcodeProjects
        .package(url: "https://github.com/tuist/XcodeProj.git", from: "9.17.5"),
    ],
    targets: [
        .target(
            name: "XPIF",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            exclude: ["LICENSE.txt", "README.md"],
            swiftSettings: swiftSettings,
        ),
        .target(
            name: "XcodePIFConversion",
            dependencies: [
                "XPIF",
                "XcodeProjects",
                "XToolMacros",
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            swiftSettings: swiftSettings,
        ),
        .macro(
            name: "XToolMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ],
            swiftSettings: swiftSettings,
        ),
        .target(
            name: "CXKit",
            dependencies: [
                .product(name: "OpenSSL", package: "xtool-core")
            ],
            cSettings: cxkitCSettings
        ),
        .target(
            name: "DeveloperAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            exclude: ["openapi-generator-config.yaml", "patch.js"],
            swiftSettings: swiftSettings,
        ),
        // common utilities shared across xtool targets
        .target(
            name: "XUtils",
            dependencies: [
                "CXKit",
                .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(
                    name: "Subprocess",
                    package: "swift-subprocess",
                    condition: .when(platforms: [.linux, .macOS])
                ),
            ],
            swiftSettings: swiftSettings,
        ),
        .target(
            name: "XKit",
            dependencies: [
                "DeveloperAPI",
                "CXKit",
                "XUtils",
                .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "SwiftyMobileDevice", package: "SwiftyMobileDevice"),
                .product(name: "RCodesign", package: "swift-rcodesign"),
                .product(name: "ProtoCodable", package: "xtool-core"),
                .product(name: "Superutils", package: "xtool-core"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
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
            cSettings: cSettings,
            swiftSettings: swiftSettings,
        ),
        .testTarget(
            name: "XToolTests",
            dependencies: [
                "XPIF",
                "XcodePIFConversion",
                "XcodeProjects",
                "XKit",
                "XToolSupport",
                "XCLIUtils",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
                .product(name: "SwiftBuild", package: "swift-build"),
            ],
            exclude: ["Fixtures"],
            swiftSettings: swiftSettings,
        ),
        .target(
            name: "XCLIUtils",
            dependencies: [
                "XUtils",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
            ],
            swiftSettings: swiftSettings,
        ),
        .target(
            name: "CFileSystemMonitoring",
            dependencies: []
        ),
        .target(
            name: "FileSystemMonitoring",
            dependencies: [
                "CFileSystemMonitoring",
                "XUtils",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),
        .target(
            name: "XToolSupport",
            dependencies: [
                "XPIF",
                "XcodePIFConversion",
                "XcodeProjects",
                "FileSystemMonitoring",
                "SwiftyMobileDevice",
                "XKit",
                "XCLIUtils",
                "XUtils",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "libunxip", package: "unxip"),
                .product(name: "SWBBuildService", package: "swift-build"),
                .product(name: "SwiftBuild", package: "swift-build"),
                .product(name: "SWBUtil", package: "swift-build"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "Superutils", package: "xtool-core"),
                .product(name: "Yams", package: "Yams"),
            ],
            cSettings: cSettings,
            swiftSettings: swiftSettings,
        ),
        .target(
            name: "XcodeProjects",
            dependencies: [
                .product(name: "XcodeProj", package: "XcodeProj"),
                .product(name: "XcodeProjectFormat", package: "xcode-project-format"),
            ],
        ),
        .executableTarget(
            name: "xtool",
            dependencies: [
                "SwiftyMobileDevice",
                "XKit",
                "XToolSupport",
            ],
            cSettings: cSettings,
            swiftSettings: swiftSettings,
        ),
    ]
)
