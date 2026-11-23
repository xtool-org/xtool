import Dependencies
import Foundation
import Testing
import XUtils
@testable import XToolSupport

@Test func swiftPMDirectoryUsesXDGConfigHome() throws {
    let directory = try DarwinSDK.swiftPMDirectory(
        environment: ["XDG_CONFIG_HOME": "/xdg/config"],
        homeDirectory: URL(fileURLWithPath: "/home/test")
    )

    #expect(directory.path == "/xdg/config/swiftpm")
}

@Test func swiftPMDirectoryFallsBackToHomeDirectory() throws {
    let directory = try DarwinSDK.swiftPMDirectory(
        environment: [:],
        homeDirectory: URL(fileURLWithPath: "/home/test")
    )

    #expect(directory.path == "/home/test/.swiftpm")
}

@Test func swiftPMDirectoryRejectsRelativeXDGConfigHome() {
    #expect(throws: StringError.self) {
        try DarwinSDK.swiftPMDirectory(
            environment: ["XDG_CONFIG_HOME": "relative/config"],
            homeDirectory: URL(fileURLWithPath: "/home/test")
        )
    }
}

@Test func temporaryDarwinSDKBundleUsesXtoolDirectory() throws {
    let homeDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DarwinSDKTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: homeDirectory) }

    try withDependencies {
        $0.persistentDirectory = homeDirectory.appending(path: "persistent")
    } operation: {
        let directory = homeDirectory.appending(path: "persistent")
        let temporaryURL = directory.appendingPathComponent("darwin.xtoolsdk.tmp", isDirectory: true)
        let installedBundle = directory.appending(path: "darwin.xtoolsdk")
        try FileManager.default.createDirectory(at: installedBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: false)

        do {
            let temporaryBundle = try DarwinSDK.prepareTemporaryBundle()
            #expect(temporaryBundle.url == temporaryURL)
            #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))

            try FileManager.default.createDirectory(at: temporaryBundle.url, withIntermediateDirectories: false)
            #expect(DarwinSDK(bundle: temporaryBundle.url)?.version == "develop")
        }

        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
        #expect(FileManager.default.fileExists(atPath: installedBundle.path))
    }
}

@Test(arguments: [false, true])
func installsDarwinSDKInXtoolDirectory(legacy: Bool) async throws {
    let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: homeDirectory) }

    try await withDependencies {
        $0.persistentDirectory = homeDirectory.appending(path: "persistent")
    } operation: {
        let temporaryBundle = try DarwinSDK.prepareTemporaryBundle()
        let temporaryURL = temporaryBundle.url
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: false)
        if !legacy {
            try Data("test\n".utf8).write(to: temporaryURL.appendingPathComponent("darwin-sdk-version.txt"))
        }
        try await temporaryBundle.install()

        let sdk = try #require(try DarwinSDK.current(environment: [:], homeDirectory: homeDirectory))
        #expect(sdk.bundle.path == homeDirectory.appending(path: "persistent/darwin.xtoolsdk").path)
        #expect(sdk.version == (legacy ? "develop" : "test"))
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
        #expect(!FileManager.default.fileExists(atPath: homeDirectory.appending(path: ".swiftpm").path))
    }
}

@Test func installStripsAppleDoubleMetadataFiles() async throws {
    let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: homeDirectory) }

    try await withDependencies {
        $0.persistentDirectory = homeDirectory.appending(path: "persistent")
    } operation: {
        let temporaryBundle = try DarwinSDK.prepareTemporaryBundle()
        let platforms = temporaryBundle.url.appending(path: "Xcode.app/Contents/Developer/Platforms")
        try FileManager.default.createDirectory(at: platforms, withIntermediateDirectories: true)
        try Data("test\n".utf8).write(to: temporaryBundle.url.appending(path: "darwin-sdk-version.txt"))
        try Data("junk".utf8).write(to: platforms.appending(path: "._iPhoneOS.platform"))
        try Data("real".utf8).write(to: platforms.appending(path: "iPhoneOS.platform"))
        try await temporaryBundle.install()

        let installedPlatforms = homeDirectory.appending(
            path: "persistent/darwin.xtoolsdk/Xcode.app/Contents/Developer/Platforms"
        )
        #expect(!FileManager.default.fileExists(atPath: installedPlatforms.appending(path: "._iPhoneOS.platform").path))
        #expect(FileManager.default.fileExists(atPath: installedPlatforms.appending(path: "iPhoneOS.platform").path))
    }
}

@Test(arguments: [false, true], ["develop", "normal", "slim"])
func migratesDarwinSDKToXtoolDirectory(usesXDG: Bool, flavor: String) throws {
    let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: homeDirectory) }

    try withDependencies {
        $0.persistentDirectory = homeDirectory.appending(path: "persistent")
    } operation: {
        let environment = usesXDG ? ["XDG_CONFIG_HOME": homeDirectory.appending(path: "xdg").path] : [:]
        let legacyBundle = try DarwinSDK.swiftPMDirectory(environment: environment, homeDirectory: homeDirectory)
            .appending(path: "swift-sdks/darwin.artifactbundle")
        try FileManager.default.createDirectory(
            at: legacyBundle.appending(path: "Xcode.app/Contents/Developer"),
            withIntermediateDirectories: true
        )
        if flavor != "develop" {
            try Data("test".utf8).write(to: legacyBundle.appendingPathComponent("darwin-sdk-version.txt"))
        }
        if flavor == "slim" {
            try Data().write(to: legacyBundle.appendingPathComponent("slim-marker"))
        }
        let payload = legacyBundle.appending(path: "toolset/bin")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("tool".utf8).write(to: payload.appendingPathComponent("clang"))

        for _ in 0..<2 {
            let sdk = try #require(try DarwinSDK.current(environment: environment, homeDirectory: homeDirectory))
            #expect(sdk.bundle.path == homeDirectory.appending(path: "persistent/darwin.xtoolsdk").path)
            #expect(sdk.version == (flavor == "develop" ? "develop" : "test"))
            #expect(sdk.flavor == (flavor == "develop" ? .legacy : flavor == "slim" ? .slim : .normal))
            #expect(FileManager.default.fileExists(atPath: sdk.developerDirectory.path))
            #expect(try Data(contentsOf: sdk.bundle.appending(path: "toolset/bin/clang")) == Data("tool".utf8))
        }
        #expect(!FileManager.default.fileExists(atPath: legacyBundle.path))
    }
}

@Test func currentDarwinSDKPrefersXtoolDirectory() throws {
    let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: homeDirectory) }

    try withDependencies {
        $0.persistentDirectory = homeDirectory.appending(path: "persistent")
    } operation: {
        let installedBundle = homeDirectory.appending(path: "persistent/darwin.xtoolsdk")
        let legacyBundle = homeDirectory.appending(path: ".swiftpm/swift-sdks/darwin.artifactbundle")
        for bundle in [installedBundle, legacyBundle] {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        }
        try Data("new".utf8).write(to: installedBundle.appendingPathComponent("darwin-sdk-version.txt"))

        let sdk = try #require(try DarwinSDK.current(environment: [:], homeDirectory: homeDirectory))
        #expect(sdk.version == "new")
        #expect(FileManager.default.fileExists(atPath: legacyBundle.path))
    }
}

@Test func currentDarwinSDKReturnsNilWhenNotInstalled() throws {
    let homeDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: homeDirectory) }

    try withDependencies {
        $0.persistentDirectory = homeDirectory.appending(path: "persistent")
    } operation: {
        let sdk = try DarwinSDK.current(environment: [:], homeDirectory: homeDirectory)
        #expect(sdk == nil)
        #expect(!FileManager.default.fileExists(atPath: homeDirectory.path))
    }
}

@Test func slimMarkerIdentifiesSDKWithXcodeApp() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let bundle = temporary.appendingPathComponent("darwin.xtoolsdk")
    let developer = bundle.appendingPathComponent("Xcode.app/Contents/Developer", isDirectory: true)
    try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
    try Data().write(to: bundle.appendingPathComponent("slim-marker"))
    try Data("test".utf8).write(to: bundle.appendingPathComponent("darwin-sdk-version.txt"))

    let sdk = try #require(DarwinSDK(bundle: bundle))
    #expect(sdk.flavor == .slim)
    #expect(sdk.developerDirectory == developer)
}
