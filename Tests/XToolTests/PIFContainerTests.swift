import XPIF
import Foundation
import Testing
@testable import XToolSupport

@Test func pifContainerEncodesFlatPIFObjects() throws {
    let target = XPIF.AggregateTarget(id: "target", name: "Target")
    let project = XPIF.Project(
        id: "project",
        path: "/tmp/Project.xcodeproj",
        projectDir: "/tmp",
        name: "Project",
        targets: [.aggregate(target)]
    )
    let pif = XPIF.Container(workspace: .init(
        id: "workspace", name: "Workspace", path: "/tmp", projects: [project]
    ))

    let data = try pif.data()
    let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    #expect(objects.count == 3)
    #expect(objects.compactMap { $0["type"] as? String } == ["workspace", "project", "target"])

    let workspace = try #require(objects[0]["contents"] as? [String: Any])
    let projectContents = try #require(objects[1]["contents"] as? [String: Any])
    let targetContents = try #require(objects[2]["contents"] as? [String: Any])
    let projectSignature = try #require(objects[1]["signature"] as? String)
    let targetSignature = try #require(objects[2]["signature"] as? String)
    #expect(workspace["guid"] as? String == "workspace")
    #expect(workspace["projects"] as? [String] == [projectSignature])
    #expect(projectContents["targets"] as? [String] == [targetSignature])
    #expect(targetContents["type"] as? String == "aggregate")
}

@Test func pifContainerRoundTripsProjectsAndTargets() throws {
    let standard = XPIF.Target(
        id: "standard-target",
        productType: .executable,
        name: "Executable",
        productName: "Executable"
    )
    let aggregate = XPIF.AggregateTarget(id: "aggregate-target", name: "Aggregate")
    let project = XPIF.Project(
        id: "project",
        path: "/tmp/Project.xcodeproj",
        projectDir: "/tmp",
        name: "Project",
        targets: [.target(standard), .aggregate(aggregate)]
    )
    let original = XPIF.Container(workspace: .init(
        id: "workspace",
        name: "Workspace",
        path: "/tmp",
        projects: [project]
    ))

    let decoded = try XPIF.Container(data: original.data())
    #expect(decoded.workspace.id == original.workspace.id)
    #expect(decoded.workspace.name == original.workspace.name)
    #expect(decoded.workspace.path == original.workspace.path)
    #expect(decoded.workspace.projects.map(\.id) == [project.id])
    #expect(decoded.workspace.projects[0].targets.map(\.id) == [standard.id, aggregate.id])
    #expect(try !decoded.data().isEmpty)
}

@Test func pifContainerDecodesWorkspace() throws {
    let decoded = try XPIF.Container(data: fixtureData("workspace-only"))
    #expect(decoded.workspace.name == "Fixture Workspace")
    #expect(decoded.workspace.projects.isEmpty)
}

@Test func pifContainerDecodesWorkspaceWithTarget() throws {
    let decoded = try XPIF.Container(data: fixtureData("workspace-with-target"))
    #expect(decoded.workspace.name == "Fixture Workspace")
    #expect(decoded.workspace.projects.map(\.name) == ["Fixture Project"])
    #expect(decoded.workspace.projects[0].targets.map(\.id) == ["aggregate-target"])
}

@Test func pifContainerDecodesComplexWorkspace() throws {
    let complexData = try fixtureData("complex")
    let decoded = try XPIF.Container(data: complexData)
    #expect(decoded.workspace.name == "Hello")
}

private func fixtureData(_ name: String) throws -> Data {
    let url = fixtureURL("\(name).json")
    return try Data(contentsOf: url)
}

@Test func pifContainerRejectsMissingProjectReference() throws {
    let original = XPIF.Container(workspace: .init(
        id: "workspace",
        name: "Workspace",
        path: "/tmp",
        projects: [XPIF.Project(id: "project", path: "/tmp/Project.xcodeproj", projectDir: "/tmp", name: "Project")]
    ))
    let data = try original.data()
    var objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    var contents = try #require(objects[0]["contents"] as? [String: Any])
    contents["projects"] = ["missing-signature"]
    objects[0]["contents"] = contents

    let invalidData = try JSONSerialization.data(withJSONObject: objects)
    #expect(throws: DecodingError.self) {
        try XPIF.Container(data: invalidData)
    }
}
