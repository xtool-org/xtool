import Foundation
import Dependencies
import libunxip
import Subprocess
import XKit // HTTPClient, stdoutSafe
import XUtils // System.File{Path,Descriptor}

// swiftlint:disable:next type_body_length
struct SDKBuilder {
    enum Arch: String {
        case x86_64
        case aarch64
    }

    enum Input {
        case xip(String)
        case app(String)

        init(path: String) throws {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                throw Console.Error("""
                Could not read file or directory at path '\(path)'.
                  See 'xtool help sdk' for usage.
                """)
            }

            let url = URL(fileURLWithPath: path)

            if isDir.boolValue {
                self = .app(path)
                let devDir = url.appendingPathComponent("Contents/Developer")
                guard devDir.dirExists else {
                    throw Console.Error("""
                    The provided directory at '\(path)' does not appear to be a version of Xcode: \
                    could not read '\(devDir.path)'.
                    """)
                }
            } else {
                self = .xip(path)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }

                let expectedMagic = "xar!".utf8
                let actualMagic = try handle.read(upToCount: expectedMagic.count) ?? Data()

                guard actualMagic.elementsEqual(expectedMagic) else {
                    throw Console.Error("""
                    The file at '\(path)' does not appear to be a valid XIP file.
                    """)
                }
            }
        }
    }

    enum Mode {
        /// Create a slim SDK with just the files that this version of xtool uses
        case buildSlim
        /// Create an SDK that retains a full copy of Xcode.app/Contents/Developer.
        /// Larger but allows in-place updates.
        case buildNormal
        /// Update a normal SDK in-place.
        case update

        var usesHardLinks: Bool {
            switch self {
            case .buildSlim: false
            case .buildNormal, .update: true
            }
        }
    }

    let input: Input
    let output: URL
    let arch: Arch
    let mode: Mode

    // bump this when the sdk builder logic changes
    static let sdkEpoch = 3

    // tag from https://github.com/xtool-org/darwin-tools-linux-llvm
    static let darwinToolsVersion = "1.1.0"

    // tag from https://github.com/xtool-org/OpenAppleMacros
    static let oamVersion = "1.3.0"
    static let oamLibraries: [String] = [
        "FoundationModelsMacros",
        "PreviewsMacros",
        "SwiftUIMacros",
    ]

    static var currentSDKVersion: String {
        """
        epoch=\(sdkEpoch),darwinTools=\(darwinToolsVersion),oam=\(oamVersion)
        """
    }

    // swiftlint:disable:next function_body_length
    func buildSDK() async throws {
        let sdkVersion = Self.currentSDKVersion

        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )

        // TODO: parallelize these three steps
        // we need to synchronize progress reporting though

        try await installMacros(in: output)

        try await installToolset(in: output)

        let dev = try await installDeveloper(in: output)

        func sdk(platform: String, prefix: String) throws -> String {
            let regex = try NSRegularExpression(pattern: #"^\#(prefix)\d+\.\d+\.sdk$"#)
            let dir = dev.appendingPathComponent("Platforms/\(platform).platform/Developer/SDKs")
            let names = try dir.contents().map(\.lastPathComponent)
            guard let name = names.first(where: {
                regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
            }) else {
                throw Console.Error("Could not find SDK for \(platform)/\(prefix)")
            }
            return name
        }

        func triple(platform: String, sdk: String) -> SDKDefinition.Triple {
            SDKDefinition.Triple(
                sdkRootPath: "Developer/Platforms/\(platform).platform/Developer/SDKs/\(sdk)",
                includeSearchPaths: ["Developer/Platforms/\(platform).platform/Developer/usr/lib"],
                librarySearchPaths: ["Developer/Platforms/\(platform).platform/Developer/usr/lib"],
                swiftResourcesPath: "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift",
                swiftStaticResourcesPath: "Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift_static",
                toolsetPaths: ["toolset.json"]
            )
        }

        let iPhoneOSSDK = try sdk(platform: "iPhoneOS", prefix: "iPhoneOS")
        let iPhoneSimSDK = try sdk(platform: "iPhoneSimulator", prefix: "iPhoneSimulator")
        let macOSSDK = try sdk(platform: "MacOSX", prefix: "MacOSX")

        print("""
        - \(iPhoneOSSDK)
        - \(iPhoneSimSDK)
        - \(macOSSDK)
        """)

        print("[Writing metadata]")
        try """
        {
            "schemaVersion": "1.0",
            "artifacts": {
                "darwin": {
                    "type": "swiftSDK",
                    "version": "0.0.1",
                    "variants": [
                        {
                            "path": ".",
                            "supportedTriples": ["aarch64-unknown-linux-gnu", "x86_64-unknown-linux-gnu"]
                        }
                    ]
                }
            }
        }
        """.write(
            to: output.appendingPathComponent("info.json"),
            atomically: false,
            encoding: .utf8
        )

        try """
        {
            "schemaVersion": "1.0",
            "rootPath": "toolset/bin",
            "linker": {
                "path": "ld64.lld"
            },
            "librarian": {
                "path": "llvm-lib"
            },
            "swiftCompiler": {
                "extraCLIOptions": [
                    "-Xfrontend", "-enable-cross-import-overlays",
                    "-use-ld=lld"
                ]
            }
        }
        """.write(
            to: output.appendingPathComponent("toolset.json"),
            atomically: false,
            encoding: .utf8
        )

        // this toolset works with the swiftbuild system on Linux
        // note that we need Swift 6.4+ because 6.3 has bugs in
        // resolving the librarian and linker paths.
        try """
        {
            "schemaVersion": "1.0",
            "rootPath": "toolset/bin",
            "linker": {
                "path": "ld64.lld"
            },
            "librarian": {
                "path": "llvm-lib"
            }
        }
        """.write(
            to: output.appendingPathComponent("toolset-swb.json"),
            atomically: false,
            encoding: .utf8
        )

        let sdkDefinition = SDKDefinition(
            schemaVersion: "4.0",
            targetTriples: [
                "arm64-apple-ios": triple(platform: "iPhoneOS", sdk: iPhoneOSSDK),
                "arm64-apple-ios-simulator": triple(platform: "iPhoneSimulator", sdk: iPhoneSimSDK),
                "x86_64-apple-ios-simulator": triple(platform: "iPhoneSimulator", sdk: iPhoneSimSDK),
                "arm64-apple-macosx": triple(platform: "MacOSX", sdk: macOSSDK),
                "x86_64-apple-macosx": triple(platform: "MacOSX", sdk: macOSSDK),
            ]
        )

        let encoder = JSONEncoder()
        try encoder
            .encode(sdkDefinition)
            .write(to: output.appendingPathComponent("swift-sdk.json"))

        try Data("\(sdkVersion)\n".utf8)
            .write(to: output.appendingPathComponent("darwin-sdk-version.txt"))
    }

    // swiftlint:disable:next function_body_length
    private func installToolset(in output: URL) async throws {
        let toolsetDir = output.appendingPathComponent("toolset")

        try FileManager.default.createDirectory(
            at: toolsetDir,
            withIntermediateDirectories: false
        )

        @Dependency(\.httpClient) var httpClient
        let url = URL(string: """
        https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/\
        v\(Self.darwinToolsVersion)/toolset-\(arch.rawValue).tar.gz
        """)!
        let (response, body) = try await httpClient.send(HTTPRequest(url: url))
        guard response.status == 200, let body else { throw Console.Error("Could not fetch toolset") }
        let length: Int64? = switch body.length {
        case .known(let known): known
        case .unknown: nil
        }

        defer { print() }
        try await Subprocess.run(
            .name("tar"),
            arguments: ["xzf", "-"],
            workingDirectory: FilePath(toolsetDir),
            input: .inputWriter,
            output: .discarded,
            error: .discarded,
        ) { execution in
            var totalWritten: Int64 = 0
            for try await chunk in body {
                var remaining = chunk
                while !remaining.isEmpty {
                    let written = try await execution.standardInputWriter.write(Array(remaining))
                    remaining = remaining.dropFirst(written)
                    totalWritten += Int64(written)

                    guard let length else { continue }
                    let progress = Int(Double(totalWritten) / Double(length) * 100)
                    print("\r[Downloading toolset] \(progress)%", terminator: "")
                    fflush(stdoutSafe)
                }
            }
            try await execution.standardInputWriter.finish()
        }
        .checkSuccess()

        // swift-build assumes we have an Apple-flavored librarian for Apple platforms
        // (https://github.com/swiftlang/swift-build/blob/b2433e74e/Sources/SWBCore/SpecImplementations/Tools/LinkerTools.swift#L1735)
        // but allows us to override this assumption if we explicitly provide the name llvm-lib (look a few lines above in that file)
        try FileManager.default.moveItem(
            at: toolsetDir.appending(path: "bin/libtool"),
            to: toolsetDir.appending(path: "bin/llvm-lib")
        )

        let ld64 = toolsetDir.appending(path: "bin/ld64.lld")
        let origBins = toolsetDir.appending(path: "bin/orig")
        let origLD64 = origBins.appending(path: "ld64.lld")
        try FileManager.default.createDirectory(at: origBins, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: ld64, to: origLD64)

        // this terrible hack works around the fact that lld doesn't support the -r option,
        // which merges multiple object files into one (used by SPM's SWB backend to combine
        // per-file MachOs into a single one for the module, on Darwin).
        //
        // so instead, we write a trampoline that intercepts `ld64.lld -r` and instead runs
        // libtool to build a static archive.
        try """
        #!/bin/sh

        set -eu

        case "$0" in
            */*) script_path="$0" ;;
            *) script_path="$(command -v "$0")" ;;
        esac
        case "$script_path" in
            /*) script_dir="${script_path%/*}"; [ -n "$script_dir" ] || script_dir="/" ;;
            */*) script_dir="${script_path%/*}" ;;
            *) script_dir="." ;;
        esac
        bin_dir="$(CDPATH= cd -P "$script_dir" && pwd -P)"

        find_argument_value() {
            argument_name="$1"
            shift

            while [ "$#" -gt 0 ]; do
                if [ "$1" = "$argument_name" ]; then
                    shift
                    if [ "$#" -gt 0 ]; then
                        argument_value="$1"
                        return 0
                    fi
                    return 1
                fi
                shift
            done

            return 1
        }

        relocatable=
        for argument do
            if [ "$argument" = "-r" ]; then
                relocatable=1
            fi
        done

        if [ -n "$relocatable" ]; then
            missing_argument=

            if find_argument_value -filelist "$@"; then
                filelist="$argument_value"
            else
                missing_argument=1
            fi
            if find_argument_value -dependency_info "$@"; then
                dependency_info="$argument_value"
            else
                missing_argument=1
            fi
            if find_argument_value -o "$@"; then
                output="$argument_value"
            else
                missing_argument=1
            fi

            if [ -n "$missing_argument" ]; then
                echo "ld64.lld trampoline could not process arguments." >&2
                echo "Please file an issue at https://github.com/xtool-org/xtool/issues" >&2
                echo "  Arguments: $@" >&2
                exit 2
            fi

            exec "$bin_dir/llvm-lib" -static \
                -filelist "$filelist" \
                -dependency_info "$dependency_info" \
                -o "$output"
        fi

        exec "$bin_dir/orig/ld64.lld" "$@"
        """.write(
            to: ld64,
            atomically: false,
            encoding: .utf8
        )
        // set -x
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ld64.path)
    }

    private func installMacros(in output: URL) async throws {
        @Dependency(\.httpClient) var httpClient
        let url = URL(string: """
        https://github.com/xtool-org/OpenAppleMacros/releases/download/\
        v\(Self.oamVersion)/OpenAppleMacrosServer-\(arch.rawValue)
        """)!

        let (response, body) = try await httpClient.send(HTTPRequest(url: url))
        guard response.status == 200, let body else { throw Console.Error("Could not fetch toolset") }

        let length: Int64? = switch body.length {
        case .known(let known): known
        case .unknown: nil
        }

        let outputPath = output.appendingPathComponent("OpenAppleMacrosServer").path
        do {
            let handle = try FileDescriptor.open(
                FilePath(outputPath),
                .writeOnly,
                options: .create,
                permissions: [.ownerReadWriteExecute, .groupReadExecute, .otherReadExecute]
            )
            defer { try? handle.close() }

            var written: Int64 = 0
            for try await chunk in body {
                try handle.writeAll(chunk)
                written += Int64(chunk.count)

                if let length {
                    let progress = Int(Double(written) / Double(length) * 100)
                    print("\r[Downloading OpenAppleMacros] \(progress)%", terminator: "")
                    fflush(stdoutSafe)
                }
            }
        }
        print()
    }

    private static let expectedXcodeChildren = ["Info.plist", "version.plist", "Developer"]

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func installDeveloper(in output: URL) async throws -> URL {
        let dev = output.appendingPathComponent("Developer")

        let expectedAppDir = output.appendingPathComponent("Xcode.app")
        let appDir: URL
        let cleanupStageDir: URL?
        let wanted: Int?

        switch (input, mode) {
        case (.xip(let inputPath), .buildSlim):
            let stage = output.appendingPathComponent("DeveloperStage")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            wanted = try await extractXIP(inputPath: inputPath, outDir: stage.path)
            try Task.checkCancellation()
            let contents = try FileManager.default.contentsOfDirectory(
                at: stage,
                includingPropertiesForKeys: nil
            )
            let apps = contents.filter { $0.pathExtension == "app" }
            switch apps.count {
            case 0:
                throw Console.Error("Unrecognized xip layout (Xcode.app not found)")
            case 1:
                appDir = apps[0]
            default:
                throw Console.Error("Unrecognized xip layout (multiple apps found)")
            }
            cleanupStageDir = stage
        case (.xip(let inputPath), .buildNormal):
            wanted = try await extractXIP(inputPath: inputPath, outDir: output.path)
            appDir = expectedAppDir
            cleanupStageDir = nil
            try cleanUpXcode(appDir)
        case (.xip, .update):
            throw Console.Error("Can't update with xip input")
        case (.app(let appPath), .buildSlim):
            appDir = URL(fileURLWithPath: appPath)
            wanted = nil
            cleanupStageDir = nil
        case (.app(let appPath), .update):
            appDir = URL(fileURLWithPath: appPath)
            wanted = nil
            cleanupStageDir = nil
            try cleanUpXcode(appDir)
        case (.app(let appPath), .buildNormal):
            let source = URL(fileURLWithPath: appPath)
            let sourceContentsDir = source.appendingPathComponent("Contents")
            let expectedContentsDir = expectedAppDir.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: expectedContentsDir, withIntermediateDirectories: true)
            print("[Copying Xcode.app] This might take a minute...")
            for child in Self.expectedXcodeChildren {
                let expectedFile = expectedContentsDir.appendingPathComponent(child)
                let sourceFile = sourceContentsDir.appendingPathComponent(child)
                guard FileManager.default.fileExists(atPath: sourceFile.path) else {
                    throw Console.Error("""
                    The provided directory at '\(appPath)' does not appear to be a known version of Xcode: \
                    could not read '\(sourceFile.path)'
                    """)
                }
                try await FileManager.default.copyItem(at: sourceFile, to: expectedFile, preserveOwner: false)
            }
            appDir = expectedAppDir
            wanted = nil
            cleanupStageDir = nil
        }
        try Task.checkCancellation()

        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: false)

        var toDoDirs: [String] = ["Contents/Developer"]
        var count = 0
        while let next = toDoDirs.popLast() {
            try Task.checkCancellation()

            let url = appDir.appendingPathComponent(next)
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            for child in contents {
                let path = "\(next)/\(child.lastPathComponent)"
                guard Self.isWanted(path[...]) else { continue }

                count += 1
                if let wanted {
                    let progress = Int(Double(count) / Double(wanted) * 100)
                    print("\r[Installing SDKs] \(progress)%", terminator: "")
                    fflush(stdoutSafe)
                }
                if count % 100 == 0 {
                    if wanted == nil {
                        print("\r[Installing SDKs] Installed \(count) files", terminator: "")
                        fflush(stdoutSafe)
                    }
                    await Task.yield()
                }

                let insideDeveloper = path.dropFirst("Contents/Developer/".count)
                guard !insideDeveloper.isEmpty else { continue }
                let dest = dev.appendingPathComponent(String(insideDeveloper))

                if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    toDoDirs.append(path)
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
                } else if mode.usesHardLinks {
                    // Installed SDKs retain Xcode.app developer dir, so avoid storing their developer files twice.
                    try FileManager.default.linkItem(at: child, to: dest)
                } else {
                    // Slim SDKs omit Xcode.app and contain independent copies.
                    try FileManager.default.copyItem(at: child, to: dest)
                }
            }
        }

        if wanted != nil {
            // otherwise the last log might say 99%
            print("\r[Installing SDKs] 100%", terminator: "")
        }
        print()

        if let cleanupStageDir {
            print("[Cleaning up]")
            try FileManager.default.removeItem(at: cleanupStageDir)
        }

        print("[Finalizing SDKs]")

        for platform in ["iPhoneOS", "MacOSX", "iPhoneSimulator"] {
            let lib = "../../../../../Library"
            let platformDir = dev.appending(path: "Platforms/\(platform).platform")

            try patchPlatformManifest(path: platformDir.appending(path: "Info.plist"))

            /*
             XCTest and Testing.framework are located in *.platform/Developer/{Library/Frameworks,usr/lib} rather than inside
             the SDK. These search paths are explicitly included when building tests, which presumably ensures that normal
             applications don't accidentally link against them in production.

             SwiftPM makes no such affordances outside of macOS, so we add the usr/lib path as include/library search paths
             in the SDK config, and symlink the frameworks into the SDKs (since there's no frameworkSearchPaths option).
             While this drops a safeguard it's better than not having the testing libs at all.
             */

            let fwk = platformDir.appending(path: "Developer/SDKs/\(platform).sdk/System/Library/Frameworks").path

            try FileManager.default.createSymbolicLink(
                atPath: "\(fwk)/Testing.framework",
                withDestinationPath: "\(lib)/Frameworks/Testing.framework"
            )

            try FileManager.default.createSymbolicLink(
                atPath: "\(fwk)/XCTest.framework",
                withDestinationPath: "\(lib)/Frameworks/XCTest.framework"
            )

            try FileManager.default.createSymbolicLink(
                atPath: "\(fwk)/XCUIAutomation.framework",
                withDestinationPath: "\(lib)/Frameworks/XCUIAutomation.framework"
            )

            try FileManager.default.createSymbolicLink(
                atPath: "\(fwk)/XCTestCore.framework",
                withDestinationPath: "\(lib)/PrivateFrameworks/XCTestCore.framework"
            )

            /*
             Apply patches to load OpenAppleMacros as the swift-plugin-server
             */

            let bin = platformDir.appendingPathComponent("Developer/usr/bin")
            let pluginServer = bin.appendingPathComponent("swift-plugin-server")
            try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: pluginServer)
            try FileManager.default.createSymbolicLink(
                atPath: pluginServer.path,
                withDestinationPath: "../../../../../../OpenAppleMacrosServer"
            )

            let hostDir = platformDir.appendingPathComponent("Developer/usr/lib/swift/host")
            let pluginsDir = hostDir.appendingPathComponent("plugins")

            if platform == "iPhoneSimulator" {
                // The iPhoneSimulator platform doesn't contain plugins; Xcode seems to be hardcoded
                // to look at the ones from iPhoneOS.platform. We can symlink the iPhoneOS ones too.
                try? FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: pluginsDir)
                try FileManager.default.createSymbolicLink(
                    atPath: pluginsDir.path,
                    withDestinationPath: "../../../../../../iPhoneOS.platform/Developer/usr/lib/swift/host/plugins"
                )
            } else {
                try? FileManager.default.removeItem(at: pluginsDir)
                try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
                // create a lib*.so file for each macro 'library' that we support.
                // the files are stubs (empty) because we just need them to convince swiftc that
                // yes we can handle said modules. the actual logic lives in the OpenAppleMacros
                // server.
                for library in Self.oamLibraries {
                    let target = pluginsDir.appendingPathComponent("lib\(library).so")
                    try Data().write(to: target)
                }
            }
        }

        // we copy over the host's clang resorurce dir during install, because intrinsics can differ
        // by LLVM version
        try FileManager.default.removeItem(
            at: dev.appending(path: "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang/include")
        )

        return dev
    }

    /// Removes unneeded files from a copy of Xcode.app that's owned by xtool.
    /// 
    /// This is conservative: we keep anything that we expect _might_ be necessary
    /// even in a future update of xtool, so that SDK self-updates work. We only
    /// delete files that we're relatively confident won't be needed.
    /// 
    /// - Important: ONLY call this if we own appDir, lest we delete files from the user's Xcode.
    private func cleanUpXcode(_ appDir: URL) throws {
        let contentsDir = appDir.appendingPathComponent("Contents")
        let contents = try FileManager.default.contentsOfDirectory(
            at: contentsDir,
            includingPropertiesForKeys: nil
        )
        let expectedChildren = Set(Self.expectedXcodeChildren)
        let missingChildren = expectedChildren.subtracting(contents.map(\.lastPathComponent))
        guard missingChildren.isEmpty else {
            let missing = missingChildren.sorted().joined(separator: ", ")
            throw Console.Error("Unrecognized xip layout: missing \(missing)")
        }
        for child in contents where !expectedChildren.contains(child.lastPathComponent) {
            try FileManager.default.removeItem(at: child)
        }
    }

    private func extractXIP(inputPath: String, outDir: String) async throws -> Int {
        // unxip doesn't like cooperative cancellation atm so shield it.
        // if the user does a ^C during unxip, we'll just wait until extraction
        // is over before bailing
        try await Task {
            try await _extractXIP(inputPath: inputPath, outDir: outDir)
        }.value
    }

    private func patchPlatformManifest(path: URL) throws {
        let data = try Data(contentsOf: path)
        guard var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw Console.Error("Could not read '\(path.path)'")
        }

        var defaultProperties = (plist["DefaultProperties"] as? [String: Any]) ?? [:]
        defaultProperties["SWIFT_RESOURCE_DIR"] = "$(PLATFORM_DIR)/../../Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"
        defaultProperties["CLANG_RESOURCE_DIR"] = "$(SWIFT_RESOURCE_DIR)/clang"
        defaultProperties["ALTERNATE_LINKER"] = "lld"
        // stub out codesign as /bin/true (SwiftBuild often emits CodeSign tasks, e.g. when
        // building for sim). we sign post-build.
        defaultProperties["CODESIGN"] = "true"
        plist["DefaultProperties"] = defaultProperties

        let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        // a non-atomic write would modify the shared inode that's hard-linked from Xcode.app
        try newData.write(to: path, options: .atomic)
    }

    // returns the number of files we actually want to keep,
    // useful for computing progress % during fs traversal
    private func _extractXIP(inputPath: String, outDir: String) async throws -> Int {
        let fd = try FileDescriptor.open(inputPath, .readOnly)
        defer { try? fd.close() }

        let length = try fd.seek(offset: 0, from: .end)
        try fd.seek(offset: 0, from: .start)

        // global state, ah well
        let oldDirectory = FileManager.default.currentDirectoryPath
        guard FileManager.default.changeCurrentDirectoryPath(outDir) else {
            throw Console.Error("Could not change directory to '\(outDir)'")
        }
        defer { _ = FileManager.default.changeCurrentDirectoryPath(oldDirectory) }

        let inputStream = DataReader.data(readingFrom: fd.rawValue)

        let (observer, source) = inputStream.lockstepSplit()

        async let readTask: Void = {
            var read = 0
            for try await chunk in observer {
                read += chunk.count
                let progress = Int(Double(read) / Double(length) * 100)
                print("\r[Extracting XIP] \(progress)%", terminator: "")
                fflush(stdoutSafe)
                if read == length { break }
            }
        }()

        let xipToChunks = XIP.transform(
            DataReader(data: source),
            options: nil
        )

        // ideally we would filter out the files we don't want at this stage,
        // speeding up extraction AND entirely avoiding the "Installing SDKs"
        // post-processing step. However, files in xip archives may be hardlinks
        // to one another and so we need to handle the case where a file inside
        // our filter() points to a file outside of it. We might be able to do this
        // with a double-pass system.

        let chunksToFiles = Chunks.transform(
            xipToChunks,
            options: nil
        )

        let filesToDisk = Files.transform(
            chunksToFiles,
            options: .init(
                compress: false,
                dryRun: false
            )
        )

        var wanted = 0
        for try await file in filesToDisk {
            wanted += Self.isWanted(file.name[...]) ? 1 : 0
        }
        _ = try await readTask

        print()

        return wanted
    }

    private static func isWanted(_ path: Substring) -> Bool {
        var components = path.split(separator: "/")[...]
        if components.first == "." {
            components.removeFirst()
        }
        if components.first?.hasSuffix(".app") == true {
            components.removeFirst()
        }
        guard SDKEntry.wanted.matches(components) else { return false }

        // TODO: see if we can exclude most dylibs. Seems we need the XCTest ones though.

        if components.count >= 10 && components[components.startIndex + 9] == "prebuilt-modules" && components.starts(
            with: "Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"
                .split(separator: "/")
        ) {
            return false
        }

        return true
    }
}

struct SDKDefinition: Encodable {
    struct Triple: Encodable {
        var sdkRootPath: String
        var includeSearchPaths: [String]
        var librarySearchPaths: [String]
        var swiftResourcesPath: String
        var swiftStaticResourcesPath: String
        var toolsetPaths: [String]
    }
    var schemaVersion: String
    var targetTriples: [String: Triple]
}

struct SDKEntry {
    var names: Set<Substring>
    var values: [SDKEntry] = []

    // empty = wildcard
    init(_ names: Set<Substring>, _ values: [SDKEntry] = []) {
        self.names = names
        self.values = values
    }

    init(_ name: Substring, _ values: [SDKEntry] = []) {
        self.init([name], values)
    }

    func matches(_ path: ArraySlice<Substring>) -> Bool {
        guard let first = path.first else { return true }
        guard names.isEmpty || names.contains(first) else { return false }
        if values.isEmpty { return true } // leaf, everything after is good
        let afterName = path.dropFirst()
        for value in values {
            if value.matches(afterName) {
                return true
            }
        }
        return false
    }

    static func E(_ name: Substring?, _ values: [SDKEntry] = []) -> SDKEntry {
        guard let name else { return SDKEntry([], values) }
        let parts = name.split(separator: "/").reversed()
        return parts.dropFirst().reduce(SDKEntry(parts.first!, values)) { SDKEntry($1, [$0]) }
    }

    static let wanted = E("Contents/Developer", [
        E("Toolchains/XcodeDefault.xctoolchain/usr/lib", [
            E("swift"),
            E("swift_static"),
            E("clang"),
        ]),
        E("Platforms", ["iPhoneOS", "MacOSX", "iPhoneSimulator"].map {
            E("\($0).platform", [
                E("Info.plist"),
                E("Developer", [
                    E("SDKs"),
                    E("Library", [
                        E("Frameworks"),
                        E("PrivateFrameworks"),
                    ]),
                    E("usr/lib"),
                ])
            ])
        }),
    ])
}
