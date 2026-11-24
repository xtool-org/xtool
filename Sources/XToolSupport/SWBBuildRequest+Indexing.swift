import Foundation
import SwiftBuild

extension SWBBuildRequest {
    /// Index preparation links host tools directly into Products. Normal install builds put
    /// symlinks there instead, so the two actions must have separate build arenas.
    func withIndexBuildArena() -> Self {
        var request = self
        request.parameters.arenaInfo = parameters.arenaInfo?.forIndexing()
        request.configuredTargets = configuredTargets.map { target in
            var target = target
            if let parameters = target.parameters {
                target.parameters?.arenaInfo = parameters.arenaInfo?.forIndexing()
            }
            return target
        }
        return request
    }
}

private extension SWBArenaInfo {
    func forIndexing() -> Self {
        guard indexRegularBuildProductsPath == nil else { return self }
        var arena = self
        let indexDirectory = URL(filePath: derivedDataPath).appending(path: "Index.noindex")
        let buildDirectory = indexDirectory.appending(path: "Build")
        arena.indexRegularBuildProductsPath = buildProductsPath
        arena.indexRegularBuildIntermediatesPath = buildIntermediatesPath
        arena.buildProductsPath = buildDirectory.appending(path: "Products").path
        arena.buildIntermediatesPath = buildDirectory.appending(path: "Intermediates.noindex").path
        arena.pchPath = buildDirectory.appending(path: "Intermediates.noindex/PrecompiledHeaders").path
        arena.indexPCHPath = indexDirectory.appending(path: "PrecompiledHeaders").path
        return arena
    }
}
