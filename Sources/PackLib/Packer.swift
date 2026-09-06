import Foundation
import XUtils
import Subprocess

public enum PackerError: Swift.Error, LocalizedError {
    case missingXCTestFramework(String, searchedIn: [String])
    case missingXCTestDylib(String, searchedIn: [String])
    case staleBuildOutput(expected: String, buildDir: String)

    public var errorDescription: String? {
        switch self {
        case .missingXCTestFramework(let name, let searchedIn):
            "Could not find \(name).framework (searched: \(searchedIn.joined(separator: ", "))). "
                + "Is the installed Darwin SDK missing its iOS platform frameworks?"
        case .missingXCTestDylib(let name, let searchedIn):
            "Could not find \(name) (searched: \(searchedIn.joined(separator: ", "))). "
                + "Is the installed Darwin SDK missing its iOS platform frameworks?"
        case .staleBuildOutput(let expected, let buildDir):
            """
            Expected build output not found: \(expected)

            SwiftPM reported the build as complete, but this product wasn't actually produced -- a \
            known incremental-build inconsistency (confirmed against real hardware: the same build \
            directory can report "Build complete!" for a --build-tests invocation while silently \
            skipping the actual test product). Delete \(buildDir) and try again.
            """
        }
    }
}

public struct Packer: Sendable {
    public let buildSettings: BuildSettings
    public let plan: Plan

    public init(buildSettings: BuildSettings, plan: Plan) {
        self.plan = plan
        self.buildSettings = buildSettings
    }

    private func build() async throws {
        let xtoolDir = URL(fileURLWithPath: "xtool")
        let packageDir = xtoolDir.appendingPathComponent(".xtool-tmp")
        try? FileManager.default.removeItem(at: packageDir)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

        let runnerTargetDecl: String
        if let xcTest = plan.xcTest {
            // Unlike plan.allProducts, this target deliberately does NOT depend on RootPackage --
            // it's a synthesized XCTest runner, not one of the user's own products. Needs UIKit,
            // not just XCTest -- see `main.swift`'s doc comment below for why.
            runnerTargetDecl = """
            ,
                    .executableTarget(
                        name: "\(xcTest.runnerProduct)",
                        linkerSettings: [
                            .linkedFramework("XCTest"),
                            .linkedFramework("UIKit"),
                            .unsafeFlags([
                                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
                            ]),
                        ]
                    )
            """
        } else {
            runnerTargetDecl = ""
        }

        let packageSwift = packageDir.appendingPathComponent("Package.swift")
        let contents = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "\(plan.app.product)-Builder",
            platforms: [
                .iOS("\(plan.app.deploymentTarget)"),
            ],
            dependencies: [
                .package(name: "RootPackage", path: "../.."),
            ],
            targets: [
                \(
                    plan.allProducts.map {
                        """
                        .executableTarget(
                            name: "\($0.targetName)",
                            dependencies: [
                                .product(name: "\($0.product)", package: "RootPackage"),
                            ],
                            linkerSettings: \($0.linkerSettings)
                        )
                        """
                    }
                    .joined(separator: ",\n")
                )\(runnerTargetDecl)
            ]
        )\n
        """
        try Data(contents.utf8).write(to: packageSwift)

        for product in plan.allProducts {
            let sources: URL = packageDir.appendingPathComponent("Sources/\(product.targetName)", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data().write(to: sources.appendingPathComponent("stub.c", isDirectory: false))
        }

        if let xcTest = plan.xcTest {
            let sources = packageDir.appendingPathComponent("Sources/\(xcTest.runnerProduct)", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            // A bare `import XCTest` with no further code was tried first and confirmed broken
            // against real hardware: with nothing blocking, `main.swift`'s implicit top-level
            // code runs to completion and the process exits normally in well under a second --
            // observed in the device syslog as RunningBoard/FrontBoard flagging the process
            // "pending exit for reason: launch failed" and a clean "voluntary" exit, no crash
            // report, right after container/bootstrap setup finishes. `XCTestConfigurationFilePath`
            // triggers XCTest's test-execution machinery, but that still needs a live process (and
            // a real app-launch lifecycle RunningBoard considers valid) to run in -- real Xcode's
            // own `XCTRunner.app` is a genuine `UIApplicationMain`-based UIKit app, not a bare
            // script, which is what actually keeps it alive. Mirrors that instead of guessing
            // further: a minimal `UIApplicationDelegate` with no behavior of its own, entered via
            // `UIApplicationMain` the classic (non-`@main`) way so it works from a plain
            // `main.swift` without extra target configuration.
            // A static "tests are running" label, not a live-updating one -- an earlier version
            // of this hooked `XCTestObservationCenter` to show live suite/case progress, but real
            // hardware testing (this session) showed that specific hook coinciding with an
            // intermittent ~45s in-process hang right at `testSuiteWillStart`, severe enough that
            // testmanagerd gave up and the OS killed the runner mid-run. Never fully root-caused
            // (XCTest's observer-dispatch internals aren't visible to us), but it's the only
            // non-Apple code running inside that exact notification path, so it's not worth the
            // risk to core `xtool test` reliability for a cosmetic feature. This keeps *a* visible
            // screen (better than blank white) without touching XCTestObservation at all.
            let mainSwift = """
            import UIKit

            class AppDelegate: UIResponder, UIApplicationDelegate {
                var window: UIWindow?

                func application(
                    _ application: UIApplication,
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
                ) -> Bool {
                    let window = UIWindow(frame: UIScreen.main.bounds)
                    let label = UILabel()
                    label.translatesAutoresizingMaskIntoConstraints = false
                    label.text = "Running tests..."
                    label.textAlignment = .center
                    let viewController = UIViewController()
                    viewController.view.addSubview(label)
                    NSLayoutConstraint.activate([
                        label.centerXAnchor.constraint(equalTo: viewController.view.centerXAnchor),
                        label.centerYAnchor.constraint(equalTo: viewController.view.centerYAnchor),
                    ])
                    window.rootViewController = viewController
                    window.makeKeyAndVisible()
                    self.window = window
                    return true
                }
            }

            UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))

            """
            try Data(mainSwift.utf8).write(to: sources.appendingPathComponent("main.swift"))
        }

        let buildConfig = try await buildSettings.swiftPMInvocation(
            forTool: "build",
            arguments: [
                "--package-path", packageDir.path,
                "--scratch-path", ".build",
                // resolving can cause SwiftPM to overwrite the root package deps
                // with just the deps needed for the builder package (which is to
                // say, any "dev dependencies" of the root package may be removed.)
                // fortunately we've already resolved the root package by this point
                // in order to dump the plan, so we can skip resolution here to skirt
                // the issue.
                "--disable-automatic-resolution",
            ]
        )
        try await Subprocess.run(
            buildConfig,
            output: .currentStandardError,
            error: .currentStandardError,
        )
        .checkSuccess()

        if plan.xcTest != nil {
            // Builds every test target in the real package into one combined bundle (SwiftPM
            // doesn't support per-target test products -- confirmed by reading SwiftPM's own
            // BuildParameters.swift/LLBuildManifestBuilder+Product.swift, which also confirms it
            // emits a real `Info.plist` for Darwin destination triples -- but in the classic
            // macOS `Contents/` bundle layout regardless of target platform; `packXCTestRunner`
            // flattens this to the iOS-style flat layout real `.xctest` bundles need).
            let testBuildConfig = try await buildSettings.swiftPMInvocation(
                forTool: "build",
                arguments: [
                    "--scratch-path", ".build",
                    "--build-tests",
                ]
            )
            try await Subprocess.run(
                testBuildConfig,
                output: .currentStandardError,
                error: .currentStandardError,
            )
            .checkSuccess()
        }
    }

    /// Compiles the package (including test targets, when `plan.xcTest` is set) without
    /// packaging the main app into a `.app` bundle. `xtool test` builds+installs the test Runner
    /// and, for XCUITest, expects the target app to already be installed separately (via `xtool
    /// install`/`xtool dev`) -- it must never build or install the main app product itself.
    public func buildOnly() async throws {
        try await build()
    }

    public func pack() async throws -> URL {
        try await build()

        let output = try TemporaryDirectory(name: "\(plan.app.product).app")

        let outputURL = output.url

        let binDir = URL(
            fileURLWithPath: ".build/\(buildSettings.triple)/\(buildSettings.configuration.rawValue)",
            isDirectory: true
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for product in plan.allProducts {
                try pack(
                    product: product,
                    binDir: binDir,
                    outputURL: product.directory(inApp: outputURL),
                    &group
                )
            }

            while !group.isEmpty {
                do {
                    try await group.next()
                } catch is CancellationError {
                    // continue
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        }

        let dest = URL(fileURLWithPath: "xtool").appendingPathComponent(outputURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try output.persist(at: dest)
        return dest
    }

    /// The `XCTest`-family frameworks a Runner.app needs embedded in `Frameworks/` to actually
    /// launch on a real device, in `@rpath` dependency order. Confirmed via `llvm-objdump
    /// --macho --dylibs-used` against the real on-device `XCTest.framework` binary: it directly
    /// (non-weak) re-exports `XCTestCore` and `XCUIAutomation`, and weakly links
    /// `XCTAutomationSupport`; everything else it links against is a `/System/Library/...`
    /// framework already present on-device. None of these ship in `/System/Library` on iOS --
    /// unlike on macOS, where Xcode's command-line tools install them system-wide, real Xcode
    /// always embeds this same set into its own `XCTRunner.app`, which is why nothing device-side
    /// provides them. `XCTestCore`/`XCUIAutomation`/`XCTAutomationSupport` each transitively
    /// depend (non-weak, so required) on `XCTestSupport`; `XCTestCore` also non-weak-depends on
    /// the new (this iOS version) `Testing` framework (Swift Testing's own on-device runtime),
    /// which in turn requires `lib_TestingInterop.dylib` -- a raw `.dylib`, not a `.framework`,
    /// so it's handled separately from `xctestFrameworkNames` below rather than added to it. Full
    /// dependency set determined by running `llvm-objdump --macho --dylibs-used` against the real
    /// on-device binaries and walking non-weak `@rpath` edges to a fixed point, not guessed.
    private static let xctestFrameworkNames = [
        "XCTest", "XCTestCore", "XCUIAutomation", "XCTAutomationSupport", "XCTestSupport", "Testing",
    ]
    private static let xctestDylibNames = ["lib_TestingInterop.dylib"]

    /// Parses `llvm-objdump --macho --dylibs-used`'s output for `@rpath/Name.framework/Name`
    /// entries, returning just `Name`.
    private static func extraRPathFrameworkNames(inExecutable executable: URL) async throws -> [String] {
        let result = try await Subprocess.run(
            .path(resolveLLVMObjdumpPath()),
            arguments: .init(["--macho", "--dylibs-used", executable.path]),
            output: .string(limit: .max)
        ).checkSuccess()
        let output = result.standardOutput ?? ""

        var names: [String] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@rpath/") else { continue }
            guard let range = trimmed.range(of: ".framework/") else { continue }
            names.append(String(trimmed["@rpath/".endIndex..<range.lowerBound]))
        }
        return names
    }

    /// `llvm-objdump` ships as part of the Swift toolchain itself (a sibling of `swift-driver`
    /// under `lib/swift/bin/`), not as a standalone install, and unlike `swift` isn't necessarily
    /// on `PATH` -- confirmed against a real Swift.org Linux toolchain install layout (this
    /// session's own environment).
    private static func resolveLLVMObjdumpPath() -> FilePath {
        let candidates = ["/usr/lib/swift/bin/llvm-objdump"]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            return FilePath(candidate)
        }
        return FilePath("llvm-objdump") // last resort: hope it's on PATH
    }

    private static func requireBuildProduct(at url: URL, binDir: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        throw PackerError.staleBuildOutput(expected: url.path, buildDir: binDir.path)
    }

    /// Packages the `Runner.app` synthesized for `plan.xcTest` (SwiftPM's combined `.xctest`
    /// bundle for every test target in the package, embedded in `PlugIns/`). Returns `nil` if the
    /// package has no test targets.
    ///
    /// - Important: Must be called *after* `build()` (via `buildOnly()` or `pack()`) -- it doesn't
    ///   build anything itself, only packages what `build()` already produced (which builds the
    ///   test targets as a side effect whenever `plan.xcTest != nil`).
    ///
    /// - Parameter platformDeveloperDirectory: the installed Darwin SDK's
    ///   `Developer/Platforms/iPhoneOS.platform/Developer` directory (see `DarwinSDK` in
    ///   `XToolSupport`, which the caller resolves and passes in -- `PackLib` doesn't depend on
    ///   `XToolSupport`). Required, not optional: without the frameworks found here, the runner
    ///   crashes at launch before any test code runs (confirmed against real hardware).
    public func packXCTestRunner(platformDeveloperDirectory: URL) async throws -> URL? {
        guard let xcTest = plan.xcTest else { return nil }

        let output = try TemporaryDirectory(name: "\(xcTest.runnerProduct).app")
        let outputURL = output.url
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let binDir = URL(
            fileURLWithPath: ".build/\(buildSettings.triple)/\(buildSettings.configuration.rawValue)",
            isDirectory: true
        )

        // `build()` can report "Build complete!" while silently not having produced these --
        // a real SwiftPM/llbuild incremental-database inconsistency hit repeatedly against real
        // hardware (this project's own history), not just a stale-directory issue (targeted
        // directory deletion alone was insufficient at least once). Checking here turns that into
        // a clear, actionable error instead of a confusing "file doesn't exist" further down the
        // copy/codesign/install pipeline.
        try Self.requireBuildProduct(
            at: binDir.appendingPathComponent(xcTest.runnerProduct),
            binDir: binDir
        )
        try Self.requireBuildProduct(
            at: binDir.appendingPathComponent("\(xcTest.testProductName).xctest"),
            binDir: binDir
        )

        // the runner's own executable, built via the synthesized wrapper package (see build()).
        try FileManager.default.copyItem(
            at: binDir.appendingPathComponent(xcTest.runnerProduct),
            to: outputURL.appendingPathComponent(xcTest.runnerProduct)
        )

        // SwiftPM's own combined .xctest bundle for every test target in the package, built
        // directly from the real package (not the wrapper) -- copied wholesale.
        let plugins = outputURL.appendingPathComponent("PlugIns", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let xctestBundle = plugins.appendingPathComponent("\(xcTest.testProductName).xctest")
        try FileManager.default.copyItem(
            at: binDir.appendingPathComponent("\(xcTest.testProductName).xctest"),
            to: xctestBundle
        )

        // `swift build --build-tests` writes the bundle in the classic macOS layout
        // (`Contents/MacOS/<executable>`, `Contents/Info.plist`) regardless of target platform --
        // confirmed by inspecting the actual build output, not assumed. iOS bundles are flat
        // (executable and Info.plist directly inside the `.xctest` directory, no `Contents/`
        // subdirectory); real Xcode-produced `.xctest` bundles for iOS are already flat. Without
        // this, the on-device runner reports "Failed to load the test bundle" /
        // "the bundle's executable couldn't be located" -- confirmed against real hardware (this
        // session): the DTX/testmanagerd handshake completes fully, the runner reaches the point
        // of actually dlopen-ing the bundle, and only THEN fails, because it's looking for the
        // executable at the flat path this macOS-style layout doesn't have.
        let macOSExecutable = xctestBundle.appendingPathComponent("Contents/MacOS/\(xcTest.testProductName)")
        if FileManager.default.fileExists(atPath: macOSExecutable.path) {
            try FileManager.default.moveItem(
                at: macOSExecutable,
                to: xctestBundle.appendingPathComponent(xcTest.testProductName)
            )
            let macOSInfoPlist = xctestBundle.appendingPathComponent("Contents/Info.plist")
            if FileManager.default.fileExists(atPath: macOSInfoPlist.path) {
                try FileManager.default.moveItem(
                    at: macOSInfoPlist,
                    to: xctestBundle.appendingPathComponent("Info.plist")
                )
            }
            try? FileManager.default.removeItem(at: xctestBundle.appendingPathComponent("Contents"))
        }

        // testmanagerd/XCTest need an Info.plist to identify the bundle; synthesize one if
        // SwiftPM didn't emit it (or it was left behind by the flattening above not finding one).
        let xctestInfoPath = xctestBundle.appendingPathComponent("Info.plist")
        if !FileManager.default.fileExists(atPath: xctestInfoPath.path) {
            let xctestInfo: [String: Sendable] = [
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleDevelopmentRegion": "en",
                "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0.0",
                "MinimumOSVersion": xcTest.deploymentTarget,
                "CFBundleIdentifier": "\(xcTest.bundleID).\(xcTest.testProductName)",
                "CFBundleName": xcTest.testProductName,
                "CFBundleExecutable": xcTest.testProductName,
                "CFBundlePackageType": "BNDL",
                "CFBundleSupportedPlatforms": ["iPhoneOS"],
            ]
            let encoded = try PropertyListSerialization.data(fromPropertyList: xctestInfo, format: .xml, options: 0)
            try FileManager.default.createDirectory(
                at: xctestInfoPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoded.write(to: xctestInfoPath)
        }

        // The runner links against `@rpath/XCTest.framework/XCTest` (see `build()`'s
        // `runnerTargetDecl`) but nothing on-device provides it -- unlike macOS, iOS ships none
        // of the XCTest-family frameworks in `/System/Library`. Without embedding them here, the
        // runner crashes at launch before any test code runs (confirmed against real hardware via
        // a pulled `.ips` crash report: "Library not loaded: @rpath/XCTest.framework/XCTest").
        let frameworksDir = outputURL.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworksDir, withIntermediateDirectories: true)
        let searchDirs = [
            platformDeveloperDirectory.appendingPathComponent("Library/Frameworks", isDirectory: true),
            platformDeveloperDirectory.appendingPathComponent("Library/PrivateFrameworks", isDirectory: true),
        ]
        for name in Self.xctestFrameworkNames {
            let frameworkDirName = "\(name).framework"
            guard let source = searchDirs
                .map({ $0.appendingPathComponent(frameworkDirName, isDirectory: true) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else {
                throw PackerError.missingXCTestFramework(name, searchedIn: searchDirs.map(\.path))
            }
            try FileManager.default.copyItem(at: source, to: frameworksDir.appendingPathComponent(frameworkDirName))
        }
        let dylibSearchDirs = [platformDeveloperDirectory.appendingPathComponent("usr/lib", isDirectory: true)]
        for name in Self.xctestDylibNames {
            guard let source = dylibSearchDirs
                .map({ $0.appendingPathComponent(name) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else {
                throw PackerError.missingXCTestDylib(name, searchedIn: dylibSearchDirs.map(\.path))
            }
            try FileManager.default.copyItem(at: source, to: frameworksDir.appendingPathComponent(name))
        }

        // Beyond the fixed XCTest-family set above, the test bundle can depend on the app's *own*
        // binary framework dependencies too (e.g. a `.binaryTarget` like `GoogleCast.xcframework`
        // linked by a target the tests `@testable import`) -- these aren't in any fixed list, so
        // they're discovered by asking the linker what the built test executable actually needs
        // (`llvm-objdump --macho --dylibs-used`, the same tool/flag this file's own
        // `xctestFrameworkNames` doc comment already used manually to determine *that* fixed set)
        // and copying whatever `@rpath/*.framework/*` entries aren't already covered. Confirmed
        // necessary against real hardware (this session): a test run using a `.binaryTarget`
        // dependency failed to `dlopen` with "Library not loaded: @rpath/GoogleCast.framework/
        // GoogleCast" without this, since the Runner.app is a separate `.app` bundle on disk from
        // the main app and doesn't share its `Frameworks/` directory.
        let testExecutableURL = xctestBundle.appendingPathComponent(xcTest.testProductName)
        let alreadyEmbedded = Set(Self.xctestFrameworkNames)
        for name in try await Self.extraRPathFrameworkNames(inExecutable: testExecutableURL) where !alreadyEmbedded.contains(name) {
            let frameworkDirName = "\(name).framework"
            let source = binDir.appendingPathComponent(frameworkDirName, isDirectory: true)
            guard FileManager.default.fileExists(atPath: source.path) else {
                // Not every `@rpath` entry resolves to something SwiftPM staged in `binDir` (some
                // are satisfied by other embedded frameworks' own re-exports) -- only copy what's
                // actually there rather than failing the whole build over the rest.
                continue
            }
            let destination = frameworksDir.appendingPathComponent(frameworkDirName)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try FileManager.default.copyItem(at: source, to: destination)
        }

        let info: [String: Sendable] = [
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0.0",
            "MinimumOSVersion": xcTest.deploymentTarget,
            "CFBundleIdentifier": xcTest.bundleID,
            "CFBundleName": xcTest.runnerProduct,
            "CFBundleExecutable": xcTest.runnerProduct,
            "CFBundleDisplayName": xcTest.runnerProduct,
            "CFBundlePackageType": "APPL",
            "UIDeviceFamily": [1, 2],
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
            "UILaunchScreen": [:] as [String: Sendable],
            "UIRequiredDeviceCapabilities": ["arm64"],
            "LSRequiresIPhoneOS": true,
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
        ]
        let encodedPlist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try encodedPlist.write(to: outputURL.appendingPathComponent("Info.plist"))

        let dest = URL(fileURLWithPath: "xtool").appendingPathComponent(outputURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try output.persist(at: dest)
        return dest
    }

    @Sendable private func pack(
        product: Plan.Product,
        binDir: URL,
        outputURL: URL,
        _ group: inout ThrowingTaskGroup<Void, Error>
    ) throws {
        @Sendable func packFileToRoot(srcName: String) async throws {
            let srcURL = URL(fileURLWithPath: srcName)
            let destURL = outputURL.appendingPathComponent(srcURL.lastPathComponent)
            try FileManager.default.copyItem(at: srcURL, to: destURL)

            try Task.checkCancellation()
        }

        @Sendable func packFile(srcName: String, dstName: String? = nil, sign: Bool = false) async throws {
            let srcURL = URL(fileURLWithPath: srcName, relativeTo: binDir)
            let dstURL = URL(fileURLWithPath: dstName ?? srcURL.lastPathComponent, relativeTo: outputURL)
            try? FileManager.default.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: srcURL, to: dstURL)

            try Task.checkCancellation()
        }

        // Ensure output directory is available
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        for command in product.resources {
            group.addTask {
                switch command {
                case .bundle(let package, let target):
                    try await packFile(srcName: "\(package)_\(target).bundle")
                case .binaryTarget(let name):
                    let src = URL(fileURLWithPath: "\(name).framework/\(name)", relativeTo: binDir)
                    let magic = Data("!<arch>\n".utf8)
                    let thinMagic = Data("!<thin>\n".utf8)
                    guard let bytes = try? FileHandle(forReadingFrom: src).read(upToCount: magic.count) else {
                        // if we can't find the binary, it might be a static framework that SwiftPM
                        // did not copy into the .build directory. we don't need to pack it anyway.
                        break
                    }
                    // if the magic matches one of these it's a static archive; don't embed it.
                    // https://github.com/apple/llvm-project/blob/e716ff14c46490d2da6b240806c04e2beef01f40/llvm/include/llvm/Object/Archive.h#L33
                    // swiftlint:disable:previous line_length
                    if bytes != magic && bytes != thinMagic {
                        try await packFile(srcName: "\(name).framework", dstName: "Frameworks/\(name).framework", sign: true)
                    }
                case .library(let name):
                    try await packFile(srcName: "lib\(name).dylib", dstName: "Frameworks/lib\(name).dylib", sign: true)
                case .root(let source):
                    try await packFileToRoot(srcName: source)
                }
            }
        }
        if let iconPath = product.iconPath {
            group.addTask {
                try await packFileToRoot(srcName: iconPath)
            }
        }
        group.addTask {
            try await packFile(srcName: product.targetName, dstName: product.product)
        }
        group.addTask {
            var info = product.infoPlist

            if product.type == .application {
                info["UIRequiredDeviceCapabilities"] = ["arm64"]
                info["LSRequiresIPhoneOS"] = true
                info["CFBundleSupportedPlatforms"] = ["iPhoneOS"]
            }

            if let iconPath = product.iconPath {
                let iconName = URL(fileURLWithPath: iconPath).deletingPathExtension().lastPathComponent
                info["CFBundleIconFile"] = iconName
            }

            let infoPath = outputURL.appendingPathComponent("Info.plist")
            let encodedPlist = try PropertyListSerialization.data(
                fromPropertyList: info,
                format: .xml,
                options: 0
            )
            try encodedPlist.write(to: infoPath)
        }
    }
}

extension Plan.Product {
    fileprivate var linkerSettings: String {
        switch self.type {
        case .application: """
        [
            .unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            ]),
        ]
        """
        case .appExtension: """
        [
            // Link to Foundation framework which implements the _NSExtensionMain entrypoint
            .linkedFramework("Foundation"),
            .unsafeFlags([
                // Set the entry point to Foundation`_NSExtensionMain
                "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                // Include frameworks that the host app may use
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../Frameworks",
                // ...as well as our own
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            ]),
        ]
        """
        }
    }
}
