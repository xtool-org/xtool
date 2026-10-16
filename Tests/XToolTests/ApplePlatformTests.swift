import Foundation
import Subprocess
import Testing
@testable import PackLib

@Test func effectiveDeploymentMinimumMatchesSwiftPMAndSDK() {
    #expect(ApplePlatform.macCatalyst.effectiveDeploymentTarget(
        platforms: ["ios": "17.0"], swiftVersion: .init(6, 4), sdkMinimum: "13.1"
    ) == "17.0")
    #expect(ApplePlatform.iOS.effectiveDeploymentTarget(
        platforms: ["ios": "13.0"], swiftVersion: .init(6, 4), sdkMinimum: "12.0"
    ) == "15.0")
    #expect(ApplePlatform.iOS.effectiveDeploymentTarget(
        platforms: ["ios": "17.0"], swiftVersion: .init(6, 4), sdkMinimum: "18.0"
    ) == "18.0")
    #expect(ApplePlatform.iOS.effectiveDeploymentTarget(
        platforms: ["ios": "17.0"], swiftVersion: .init(6, 4), sdkMinimum: "15.0", tripleMinimum: "18.0"
    ) == "18.0")
}

@Test func catalystCanImportCompatibilityFrameworks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CatalystTests-\(UUID())", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sdk = root.appendingPathComponent("MacOSX.sdk", isDirectory: true)
    let support = sdk.appendingPathComponent("System/iOSSupport", isDirectory: true)
    let framework = support.appendingPathComponent("System/Library/Frameworks/UIKit.framework", isDirectory: true)
    for path in ["Headers", "Modules"] {
        try FileManager.default.createDirectory(at: framework.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    let include = support.appendingPathComponent("usr/include", isDirectory: true)
    try FileManager.default.createDirectory(at: include, withIntermediateDirectories: true)
    try Data("void UIKitFixture(void);\n".utf8).write(to: include.appendingPathComponent("UIKitFixture.h"))
    try Data("#include <UIKitFixture.h>\n".utf8).write(to: framework.appendingPathComponent("Headers/UIKit.h"))
    try Data("framework module UIKit { umbrella header \"UIKit.h\" export * }\n".utf8)
        .write(to: framework.appendingPathComponent("Modules/module.modulemap"))
    let source = root.appendingPathComponent("Example.swift")
    try Data("import UIKit\n".utf8).write(to: source)

    let baseArguments = [
        "-typecheck", "-parse-stdlib", "-nostdimport", "-target", "arm64-apple-ios17.0-macabi",
        "-sdk", sdk.path, source.path,
    ]
    let compiler = try await BuildSettings.swiftcURL()
    let withoutSupport = try await Subprocess.run(
        .path(compiler), arguments: .init(baseArguments), output: .discarded, error: .discarded
    )
    #expect(!withoutSupport.terminationStatus.isSuccess)

    let options = ApplePlatform.macCatalyst.additionalSDKOptions(sdkRoot: sdk)
    let compilerOptions = stride(from: 0, to: options.count, by: 2).flatMap { index -> [String] in
        switch options[index] {
        case "-Xswiftc": return [options[index + 1]]
        case "-Xcc": return ["-Xcc", options[index + 1]]
        default: return []
        }
    }
    let withSupport = try await Subprocess.run(
        .path(compiler), arguments: .init(baseArguments + compilerOptions), output: .discarded, error: .string(limit: .max)
    )
    #expect(withSupport.terminationStatus.isSuccess, "\(withSupport.standardError)")
}
