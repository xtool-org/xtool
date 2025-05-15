import Foundation
import Dependencies
import SystemPackage
import libunxip
import XKit // HTTPClient, stdoutSafe
import PackLib // ToolRegistry

struct SDKBuilder {
    enum Arch: String {
        case x86_64
        case aarch64
    }

    enum Input {
        case xip(String)
        case app(String)

        init(path: String) throws {
            if path.hasSuffix(".xip") {
                self = .xip(path)
            } else if path.hasSuffix(".app") || path.hasSuffix(".app/") {
                self = .app(path)
            } else {
                throw Console.Error("Expected input path to end in .xip or .app")
            }
        }
    }

    let input: Input
    let outputPath: String
    let arch: Arch

    @discardableResult
    func buildSDK() async throws -> String {
        // TODO: store relevant info for staleness check
        let sdkVersion = "develop"

        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
            .appendingPathComponent("darwin.artifactbundle")

        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )

        // TODO: parallelize these two steps
        // we need to synchronize progress reporting though

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
            "swiftCompiler": {
                "extraCLIOptions": [
                    "-use-ld=lld"
                ]
            }
        }
        """.write(
            to: output.appendingPathComponent("toolset.json"),
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

        return output.path
    }

    private func installToolset(in output: URL) async throws {
        // tag from https://github.com/xtool-org/darwin-tools-linux-llvm
        let darwinToolsVersion = "1.0.1"

        let toolsetDir = output.appendingPathComponent("toolset")

        try FileManager.default.createDirectory(
            at: toolsetDir,
            withIntermediateDirectories: false
        )

        let pipe = Pipe()
        let untar = Process()
        untar.currentDirectoryURL = toolsetDir
        untar.executableURL = try await ToolRegistry.locate("tar")
        untar.arguments = ["xzf", "-"]
        untar.standardInput = pipe.fileHandleForReading
        async let tarExit: Void = untar.runUntilExit()

        @Dependency(\.httpClient) var httpClient
        let url = URL(string: """
        https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/\
        v\(darwinToolsVersion)/toolset-\(arch.rawValue).tar.gz
        """)!
        let (response, body) = try await httpClient.send(HTTPRequest(url: url))
        guard response.status == 200, let body else { throw Console.Error("Could not fetch toolset") }
        let length: Int64? = switch body.length {
        case .known(let known): known
        case .unknown: nil
        }
        let writer = pipe.fileHandleForWriting
        var written: Int64 = 0
        do {
            defer { try? writer.close() }
            for try await chunk in body {
                try writer.write(contentsOf: chunk)
                written += Int64(chunk.count)
                if let length {
                    let progress = Int(Double(written) / Double(length) * 100)
                    print("\r[Downloading toolset] \(progress)%", terminator: "")
                    fflush(stdoutSafe)
                }
            }
        }
        print()
        try await tarExit
    }

    private func installDeveloper(in output: URL) async throws -> URL {
        let dev = output.appendingPathComponent("Developer")

        let appDir: URL
        let cleanupStageDir: URL?
        let wanted: Int?

        switch input {
        case .xip(let inputPath):
            let devStage = output.appendingPathComponent("DeveloperStage")
            try FileManager.default.createDirectory(at: devStage, withIntermediateDirectories: false)
            // unxip doesn't like cooperative cancellation atm so shield it.
            // if the user does a ^C during unxip, we'll just wait until extraction
            // is over before bailing
            wanted = try await Task {
                try await extractXIP(inputPath: inputPath, outDir: devStage.path)
            }.value
            try Task.checkCancellation()
            appDir = devStage.appendingPathComponent("Xcode.app")
            cleanupStageDir = devStage
        case .app(let appPath):
            wanted = nil
            appDir = URL(fileURLWithPath: appPath)
            cleanupStageDir = nil
        }

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
                        print("\r[Installing SDKs] Copied \(count) files", terminator: "")
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
                } else {
                    try FileManager.default.copyItem(at: child, to: dest)
                }
            }
        }

        if wanted != nil {
            // otherwise the last log might say 99%
            print("\r[Installing SDKs] 100%", terminator: "")
        }
        print()

        print("[Cleaning up]")
        if let cleanupStageDir {
            try? FileManager.default.removeItem(at: cleanupStageDir)
        }

        print("[Finalizing SDKs]")

        /*
         XCTest and Testing.framework are located in *.platform/Developer/{Library/Frameworks,usr/lib} rather than inside
         the SDK. These search paths are explicitly included when building tests, which presumably ensures that normal
         applications don't accidentally link against them in production.

         SwiftPM makes no such affordances outside of macOS, so we add the usr/lib path as include/library search paths
         in the SDK config, and symlink the frameworks into the SDKs (since there's no frameworkSearchPaths option).
         While this drops a safeguard it's better than not having the testing libs at all.
         */

        for platform in ["iPhoneOS", "MacOSX", "iPhoneSimulator"] {
            let lib = "../../../../../Library"
            let dest = dev.appendingPathComponent("""
            Platforms/\(platform).platform/Developer/SDKs/\(platform).sdk\
            /System/Library/Frameworks
            """).path

            try FileManager.default.createSymbolicLink(
                atPath: "\(dest)/Testing.framework",
                withDestinationPath: "\(lib)/Frameworks/Testing.framework"
            )

            try FileManager.default.createSymbolicLink(
                atPath: "\(dest)/XCTest.framework",
                withDestinationPath: "\(lib)/Frameworks/XCTest.framework"
            )

            try FileManager.default.createSymbolicLink(
                atPath: "\(dest)/XCUIAutomation.framework",
                withDestinationPath: "\(lib)/Frameworks/XCUIAutomation.framework"
            )

            try FileManager.default.createSymbolicLink(
                atPath: "\(dest)/XCTestCore.framework",
                withDestinationPath: "\(lib)/PrivateFrameworks/XCTestCore.framework"
            )
        }

        return dev
    }

    // returns the number of files we actually want to keep,
    // useful for computing progress % during fs traversal
    private func extractXIP(inputPath: String, outDir: String) async throws -> Int {
        let fd = try FileDescriptor.open(inputPath, .readOnly)
        defer { try? fd.close() }

        let length = try fd.seek(offset: 0, from: .end)
        try fd.seek(offset: 0, from: .start)

        // global state, ah well
        let oldDirectory = FileManager.default.currentDirectoryPath
        guard FileManager.default.changeCurrentDirectoryPath(outDir) else {
            throw Console.Error("Could not change directory to '\(outDir)'")
        }
        defer { FileManager.default.changeCurrentDirectoryPath(oldDirectory) }

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
            E("\($0).platform/Developer", [
                E("SDKs"),
                E("Library", [
                    E("Frameworks"),
                    E("PrivateFrameworks"),
                ]),
                E("usr/lib"),
            ])
        }),
    ])
}
