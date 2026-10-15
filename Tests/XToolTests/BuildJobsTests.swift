import Testing
import ArgumentParser
@testable import XToolSupport

@Test
func testBuildJobsDefault() throws {
    let options = try PackOperation.BuildOptions.parse([])
    #expect(options.jobs == nil)
    try options.validate()
}

@Test(arguments: ["--jobs", "-j"])
func testBuildJobsOption(name: String) throws {
    let options = try PackOperation.BuildOptions.parse([name, "2"])
    #expect(options.jobs == 2)
    try options.validate()
}

@Test(arguments: [0, -1])
func testBuildJobsRejectsNonpositiveCount(count: Int) throws {
    do {
        _ = try PackOperation.BuildOptions.parse(["--jobs=\(count)"])
        Issue.record("Expected a nonpositive job count to fail validation")
    } catch {
        #expect(PackOperation.BuildOptions.message(for: error) == "--jobs must be greater than zero")
    }
}
