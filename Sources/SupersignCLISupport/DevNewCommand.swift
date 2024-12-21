import ArgumentParser
import Foundation

struct DevNewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Create a new project"
    )

    @Argument var name: String?

    func run() async throws {
        let name = try await Console.promptRequired("Package name: ", existing: self.name)

        var allowedFirstCharacters: CharacterSet = ["_"]
        allowedFirstCharacters.insert(charactersIn: "a"..."z")
        allowedFirstCharacters.insert(charactersIn: "A"..."Z")

        var allowedOtherCharacters = allowedFirstCharacters
        allowedOtherCharacters.insert(charactersIn: "0"..."9")
        allowedOtherCharacters.insert("-")

        // promptRequired validates !isEmpty
        let firstScalar = name.unicodeScalars.first!
        guard allowedFirstCharacters.contains(firstScalar) else {
            throw Console.Error("""
            Package name '\(name)' is invalid. \
            The package name must start with one of [a-z, A-Z, _]. Found '\(firstScalar)'.
            """)
        }

        if let firstInvalid = name.rangeOfCharacter(from: allowedOtherCharacters.inverted) {
            let invalidValue = name[firstInvalid]
            throw Console.Error("""
            Package name '\(name)' is invalid. \
            The package name may only contain [a-z, A-Z, 0-9, _, -]. Found '\(invalidValue)'.
            """)
        }

        let baseURL = URL(fileURLWithPath: name)

        guard !baseURL.exists else {
            throw Console.Error("Cannot create \(name): a file already exists at that path.")
        }

        print("Creating package: \(name)")

        let moduleName = name.replacingOccurrences(of: "-", with: "_")

        let files: [(String, String)] = [
            (
                "Package.swift",
                """
                // swift-tools-version: 6.0

                import PackageDescription

                let package = Package(
                    name: "\(name)",
                    platforms: [
                        .iOS(.v17),
                        .macOS(.v14),
                    ],
                    products: [
                        // A Swiftpack project should contain exactly one library target,
                        // representing the main app.
                        .library(
                            name: "\(moduleName)",
                            targets: ["\(moduleName)"]
                        ),
                    ],
                    targets: [
                        .target(
                            name: "\(moduleName)"
                        ),
                    ]
                )
                """
            ),

            (
                "swiftpack.yml",
                """
                version: 1
                bundleID: com.example.\(name)
                """
            ),

            (
                ".gitignore",
                """
                .DS_Store
                /.build
                /Packages
                xcuserdata/
                DerivedData/
                .swiftpm/configuration/registries.json
                .swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata
                .netrc
                
                /swiftpack
                /.sourcekit-lsp
                """
            ),

            (
                ".sourcekit-lsp/config.json",
                """
                {
                    "swiftPM": {
                        "swiftSDK": "arm64-apple-ios"
                    }
                }
                """
            ),

            (
                "Sources/\(moduleName)/\(moduleName)App.swift",
                """
                import SwiftUI
                
                @main
                struct \(moduleName)App: App {
                    var body: some Scene {
                        WindowGroup {
                            ContentView()
                        }
                    }
                }
                """
            ),

            (
                "Sources/\(moduleName)/ContentView.swift",
                """
                import SwiftUI
                
                struct ContentView: View {
                    var body: some View {
                        VStack {
                            Image(systemName: "globe")
                                .imageScale(.large)
                                .foregroundStyle(.tint)
                            Text("Hello, world!")
                        }
                        .padding()
                    }
                }
                """
            ),
        ]

        for (path, contents) in files {
            let url = baseURL.appendingPathComponent(path)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            print("Creating \(path)")
            try "\(contents)\n".write(to: url, atomically: true, encoding: .utf8)
        }

        let gitInit = Process()
        gitInit.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        gitInit.arguments = ["git", "init"]
        gitInit.currentDirectoryURL = baseURL
        try gitInit.run()
        await gitInit.waitForExit()

        print("\nFinished generating project \(name). Next steps:")
        print("- Enter the directory with `cd \(name)`")
        print("- Build and run with `supersign dev`")
    }
}
