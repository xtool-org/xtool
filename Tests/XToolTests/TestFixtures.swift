import Foundation

func fixtureURL(_ path: String) -> URL {
    URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(path)")
}
