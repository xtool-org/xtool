import SwiftBuild
import Testing
@testable import XToolSupport

struct IndexBuildArenaTests {
    @Test
    func separatesIndexProductsFromCachedInstallProducts() throws {
        var request = SWBBuildRequest()
        request.parameters.arenaInfo = arena(root: "/tmp/DerivedData")
        request.parameters.action = "install"
        var targetParameters = SWBBuildParameters()
        targetParameters.arenaInfo = arena(root: "/tmp/TargetData")
        request.configuredTargets = [
            SWBConfiguredTarget(guid: "app"),
            SWBConfiguredTarget(guid: "macro", parameters: targetParameters),
        ]

        let indexing = request.withIndexBuildArena()
        let indexedArena = try #require(indexing.parameters.arenaInfo)
        #expect(indexedArena.buildProductsPath == "/tmp/DerivedData/Index.noindex/Build/Products")
        #expect(indexedArena.buildIntermediatesPath == "/tmp/DerivedData/Index.noindex/Build/Intermediates.noindex")
        #expect(indexedArena.indexRegularBuildProductsPath == "/tmp/DerivedData/Products")
        #expect(indexedArena.indexRegularBuildIntermediatesPath == "/tmp/DerivedData/Intermediates.noindex")
        #expect(indexedArena.indexDataStoreFolderPath == "/tmp/DerivedData/Index.noindex/DataStore")
        #expect(indexedArena.indexEnableDataStore)
        #expect(indexing.configuredTargets[0].parameters == nil)
        #expect(indexing.configuredTargets[1].parameters?.arenaInfo?.buildProductsPath
            == "/tmp/TargetData/Index.noindex/Build/Products")
        #expect(request.parameters.arenaInfo?.buildProductsPath == "/tmp/DerivedData/Products")
        #expect(request.configuredTargets[1].parameters?.arenaInfo?.buildProductsPath == "/tmp/TargetData/Products")
        #expect(indexing.withIndexBuildArena().parameters.arenaInfo?.buildProductsPath == indexedArena.buildProductsPath)
        #expect(indexing.withIndexBuildArena().parameters.arenaInfo?.indexRegularBuildProductsPath
            == indexedArena.indexRegularBuildProductsPath)
    }

    @Test
    func leavesUnspecifiedArenasToSwiftBuild() {
        let request = SWBBuildRequest().withIndexBuildArena()
        #expect(request.parameters.arenaInfo == nil)
    }

    private func arena(root: String) -> SWBArenaInfo {
        SWBArenaInfo(
            derivedDataPath: root,
            buildProductsPath: root + "/Products",
            buildIntermediatesPath: root + "/Intermediates.noindex",
            pchPath: root,
            indexRegularBuildProductsPath: nil,
            indexRegularBuildIntermediatesPath: nil,
            indexPCHPath: root,
            indexDataStoreFolderPath: root + "/Index.noindex/DataStore",
            indexEnableDataStore: true
        )
    }
}
