import Testing
@testable import XToolSupport

@Test(arguments: [
    ("1.2.3", [1, 2, 3]),
    ("v1.2.3", [1, 2, 3]),
    ("10.0", [10, 0]),
])
func parsesVersions(version: String, expected: [Int]) {
    #expect(GitHubRelease.parse(version) == expected)
}

@Test(arguments: ["unversioned", "", "1.x.3", "1..2", "1.2-beta"])
func rejectsInvalidVersions(version: String) {
    #expect(GitHubRelease.parse(version) == nil)
}

@Test(arguments: [
    ("1.2.4", "1.2.3", true),
    ("1.3.0", "1.2.9", true),
    ("2.0", "1.9.9", true),
    ("1.10.0", "1.9.0", true),
    ("v1.2.4", "1.2.3", true),
    ("1.2.3", "1.2.3", false),
    ("1.2", "1.2.0", false),
    ("1.2.2", "1.2.3", false),
    ("1.2.4", "unversioned", false),
    ("unversioned", "1.2.3", false),
])
func comparesVersions(candidate: String, current: String, expected: Bool) {
    #expect(GitHubRelease.isNewer(candidate, than: current) == expected)
}
