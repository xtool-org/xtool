import Foundation
@testable import XToolSupport

func fixtureURL(_ path: String) -> URL {
    URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(path)")
}

extension XToolProject {
    /// An Xcode project whose scratch files live in the current directory rather than next to the fixture.
    static func testXcode(_ container: URL, schema: PackSchema = .default) -> Self {
        .xcode(.init(base: .init(rootDirectory: URL(filePath: "."), schema: schema), container: container))
    }
}
