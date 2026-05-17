import Foundation
import Testing
import XUtils
@testable import XCAssetCompiler

@Suite("End-to-end fixture (manual)")
struct EndToEndFixture {
    @Test(
        "Compile /tmp/xtl-fixture/Test.xcassets into /tmp/xtl-fixture/ours.car",
        .enabled(if: ProcessInfo.processInfo.environment["XTL_FIXTURE"] != nil)
    )
    func compileFixture() async throws {
        let catalog = URL(fileURLWithPath: "/tmp/xtl-fixture/Test.xcassets")
        let compiler = XCAssetCompiler(deploymentTarget: "16.0", diagnostics: Diagnostics())
        let result = try await compiler.compile(catalog: catalog)
        try result.carData.write(to: URL(fileURLWithPath: "/tmp/xtl-fixture/ours.car"))
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: result.infoPlistAdditions, format: .xml, options: 0
        )
        try plistData.write(to: URL(fileURLWithPath: "/tmp/xtl-fixture/ours.partial.plist"))
        FileHandle.standardError.write(Data(
            "Wrote ours.car (\(result.carData.count) bytes), primaryIconName=\(result.primaryIconName ?? "nil")\n".utf8
        ))
    }
}
