import SwiftBuild
import Testing
import XPIF
@testable import XToolSupport

struct BuildServerTargetsTests {
    @Test
    func leavesDynamicVariantsToDependencyResolution() {
        var support = XPIF.Target(
            id: "support", productType: .commonStaticArchive, name: "MacroSupport", productName: "MacroSupport.o"
        )
        support.dynamicTargetVariantId = "support-dynamic"
        let dynamic = XPIF.Target(
            id: "support-dynamic", productType: .framework, name: "MacroSupport", productName: "MacroSupport.framework"
        )
        let macro = XPIF.Target(
            id: "macro", productType: .hostBuildTool, name: "Macro", productName: "Macro",
            dependencies: [XPIF.TargetDependency(targetId: support.id)]
        )
        let tests = XPIF.Target(
            id: "tests", productType: .unitTest, name: "Tests", productName: "Tests.xctest"
        )
        var package = XPIF.Project(id: "package", path: "/tmp/Package", projectDir: "/tmp/Package", name: "Package")
        package.targets = [.target(support), .target(macro), .target(tests)]
        var variants = XPIF.Project(id: "variants", path: "/tmp/Variants", projectDir: "/tmp/Variants", name: "Variants")
        variants.targets = [.target(dynamic)]
        let workspace = XPIF.Workspace(
            id: "workspace", name: "Workspace", path: "/tmp", projects: [package, variants]
        )

        let targets = workspace.indexingTargets
        #expect(targets.map(\.id) == ["support", "macro", "tests"])
        #expect(workspace.projects[1].targets[0].id == dynamic.id)
    }
}
