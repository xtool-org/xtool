import XCLIUtils
import Foundation
import Dependencies
import libunxip
import Subprocess
import XKit // HTTPClient, stdoutSafe
import XUtils // System.File{Path,Descriptor}

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

        var retainsXcode: Bool {
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
    static let sdkEpoch = 6

    // tag from https://github.com/xtool-org/darwin-tools-linux-llvm
    static let darwinToolsVersion = "1.1.0"
    // tag from https://github.com/xtool-org/OpenAppleMacros
    static let oamVersion = "1.4.1"

    // most EmulatedTools don't need this because we can intercept their invocation
    // at the SwiftBuild/llbuild level. but for some tools we need a physical path
    // on disk, which is where this comes in handy.
    // bump sdk epoch when this changes
    static let toolsToEmulate = [
        "strip",
        "bitcode_strip",
    ]

    static var currentSDKVersion: String {
        """
        epoch=\(sdkEpoch),darwinTools=\(darwinToolsVersion),oam=\(oamVersion)
        """
    }

    func buildSDK() async throws {
        let sdkVersion = Self.currentSDKVersion

        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )

        try await installToolset(in: output)
        try await installMacros(in: output)

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

        let iPhoneOSSDK = try sdk(platform: "iPhoneOS", prefix: "iPhoneOS")
        let iPhoneSimSDK = try sdk(platform: "iPhoneSimulator", prefix: "iPhoneSimulator")
        let macOSSDK = try sdk(platform: "MacOSX", prefix: "MacOSX")

        d.out.print("""
        - \(iPhoneOSSDK)
        - \(iPhoneSimSDK)
        - \(macOSSDK)
        """)

        try Data("\(sdkVersion)\n".utf8)
            .write(to: output.appendingPathComponent("darwin-sdk-version.txt"))
    }

    private func fetchTarball(
        url: URL,
        destination directory: URL,
        displayName: String,
        envOverride: String? = nil,
    ) async throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )

        if let envOverride, let path = ProcessInfo.processInfo.environment[envOverride] {
            let source = URL(fileURLWithPath: path)
            if source.dirExists {
                d.out.print("[Copying \(displayName)] \(source.path)")
                try await Subprocess.run(
                    .name("cp"),
                    arguments: ["-RL", "\(source.path)/.", "."],
                    workingDirectory: FilePath(directory),
                    output: .discarded,
                    error: .discarded,
                )
                .checkSuccess()
                // later steps write into the copy
                try await Subprocess.run(
                    .name("chmod"),
                    arguments: ["-R", "u+w", "."],
                    workingDirectory: FilePath(directory),
                    output: .discarded,
                    error: .discarded,
                )
                .checkSuccess()
                return
            }

            d.out.print("[Extracting \(displayName)] \(source.path)")
            try await Subprocess.run(
                .name("tar"),
                arguments: ["xzf", source.path],
                workingDirectory: FilePath(directory),
                output: .discarded,
                error: .discarded,
            )
            .checkSuccess()
            return
        }

        @Dependency(\.httpClient) var httpClient
        let (response, body) = try await httpClient.send(HTTPRequest(url: url))
        guard response.status == 200, let body else {
            throw Console.Error("Could not fetch tarball at \(url)")
        }
        let length: Int64? = switch body.length {
        case .known(let known): known
        case .unknown: nil
        }

        defer { d.out.print() }
        try await Subprocess.run(
            .name("tar"),
            arguments: ["xzf", "-"],
            workingDirectory: FilePath(directory),
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
                    d.out.print("\r[Downloading \(displayName)] \(progress)%", terminator: "", flush: true)
                }
            }
            try await execution.standardInputWriter.finish()
        }
        .checkSuccess()
    }

    private func installToolset(in output: URL) async throws {
        let toolsetDir = output.appendingPathComponent("toolset")
        let url = URL(string: """
        https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/\
        v\(Self.darwinToolsVersion)/toolset-\(arch.rawValue).tar.gz
        """)!
        try await fetchTarball(
            url: url,
            destination: toolsetDir,
            displayName: "toolset",
            envOverride: "XTL_TOOLSET_TARBALL",
        )

        // swift-build assumes we have an Apple-flavored librarian for Apple platforms
        // (https://github.com/swiftlang/swift-build/blob/b2433e74e/Sources/SWBCore/SpecImplementations/Tools/LinkerTools.swift#L1735)
        // but allows us to override this assumption if we explicitly provide the name llvm-lib (look a few lines above in that file)
        try FileManager.default.moveItem(
            at: toolsetDir.appending(path: "bin/libtool"),
            to: toolsetDir.appending(path: "bin/llvm-lib")
        )

        let emulatorURL = toolsetDir.appending(path: "bin/xtool-emulate-tool")
        try Data("""
        #!/bin/sh
        exec "${XTL_LOOPBACK_PATH}" _emulate "$0" "$@"
        """.utf8).write(to: emulatorURL)
        // chmod +x
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: emulatorURL.path
        )

        for tool in Self.toolsToEmulate {
            try FileManager.default.createSymbolicLink(
                atPath: toolsetDir.appending(path: "bin/\(tool)").path,
                withDestinationPath: "xtool-emulate-tool"
            )
        }
    }

    private func installMacros(in output: URL) async throws {
        let toolsetDir = output.appendingPathComponent("toolset")

        let url = URL(string: """
        https://github.com/xtool-org/OpenAppleMacros/releases/download/\
        v\(Self.oamVersion)/OpenAppleMacrosServer-\(arch.rawValue).tar.gz
        """)!

        let tmpMacrosDir = output.appendingPathComponent("OpenAppleMacros")
        try await fetchTarball(
            url: url,
            destination: tmpMacrosDir,
            displayName: "OpenAppleMacros",
            envOverride: "XTL_OAM_TARBALL",
        )

        struct MacrosInfo: Decodable {
            var plugins: [String]
        }
        let macrosInfo = try JSONDecoder().decode(
            MacrosInfo.self,
            from: Data(contentsOf: tmpMacrosDir.appendingPathComponent("info.json"))
        )
        try FileManager.default.moveItem(
            at: tmpMacrosDir.appendingPathComponent("OpenAppleMacrosServer"),
            to: toolsetDir.appendingPathComponent("bin/OpenAppleMacrosServer")
        )
        try FileManager.default.removeItem(at: tmpMacrosDir)

        let pluginsDir = toolsetDir.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        // create a lib*.so file for each macro 'library' that we support.
        // the files are stubs (empty) because we just need them to convince swiftc that
        // yes we can handle said modules. the actual logic lives in the OpenAppleMacros
        // server.
        for library in macrosInfo.plugins {
            let target = pluginsDir.appendingPathComponent("lib\(library).so")
            try Data().write(to: target)
        }
    }

    private static let expectedXcodeChildren = ["Info.plist", "version.plist", "Developer"]

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func installDeveloper(in output: URL) async throws -> URL {
        let expectedAppDir = output.appendingPathComponent("Xcode.app")
        let dev = expectedAppDir.appendingPathComponent("Contents/Developer")
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
            d.out.print("[Copying Xcode.app] This might take a minute...")
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

        if mode.retainsXcode {
            // During an update, Xcode.app moves into the new bundle only after the build succeeds.
            return appDir.appendingPathComponent("Contents/Developer")
        }

        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)

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
                    d.out.print("\r[Installing SDKs] \(progress)%", terminator: "", flush: true)
                }
                if count % 100 == 0 {
                    if wanted == nil {
                        d.out.print("\r[Installing SDKs] Installed \(count) files", terminator: "", flush: true)
                    }
                    await Task.yield()
                }

                let insideDeveloper = path.dropFirst("Contents/Developer/".count)
                guard !insideDeveloper.isEmpty else { continue }
                let dest = dev.appendingPathComponent(String(insideDeveloper))

                if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    toDoDirs.append(path)
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
                } else {
                    // Slim SDKs contain independent copies of just the selected developer files.
                    try FileManager.default.copyItem(at: child, to: dest)
                }
            }
        }

        if wanted != nil {
            // otherwise the last log might say 99%
            d.out.print("\r[Installing SDKs] 100%", terminator: "")
        }
        d.out.print()

        if let cleanupStageDir {
            d.out.print("[Cleaning up]")
            try FileManager.default.removeItem(at: cleanupStageDir)
        }

        try Data().write(to: output.appendingPathComponent("slim-marker"))
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
                d.out.print("\r[Extracting XIP] \(progress)%", terminator: "", flush: true)
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

        d.out.print()

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
