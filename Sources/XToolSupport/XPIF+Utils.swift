import XPIF

extension XPIF.Container.Workspace {
    static let umbrellaTargetGUID: XPIF.GUID = "xtool:UMBRELLA"

    mutating func addUmbrellaTarget(toProjectAt projectIndex: Int) throws {
        // SwiftBuild's BSP impl allows for mutable PIF but requires an immutable
        // SWBBuildRequest. So we construct an SWBBuildRequest that points to this
        // umbrella target.
        //
        // So if the user adds a new target, although we can't mutate the build
        // request, we can add the new target to the umbrella and have it covered.
        let umbrellaTarget = XPIF.AggregateTarget(
            id: Self.umbrellaTargetGUID,
            name: "Umbrella Target",
            buildConfigs: ["Debug", "Release"].map { configuration in
                XPIF.BuildConfig(
                    id: "\(Self.umbrellaTargetGUID):\(configuration)",
                    name: configuration,
                    settings: XPIF.BuildSettings(),
                )
            },
            dependencies: indexingTargets.map { XPIF.TargetDependency(targetId: $0.id) }
        )
        try projects[projectIndex].addAggregateTarget { _ in umbrellaTarget }
    }

    var indexingTargets: [XPIF.BaseTarget] {
        let targets = self.projects.flatMap(\.targets)
        let dynamicVariants = Set(targets.compactMap { target -> XPIF.GUID? in
            guard case .target(let target) = target else { return nil }
            return target.dynamicTargetVariantId
        })
        // including the dynamic variants in the umbrella causes duplicate-target collisions
        return targets.filter { !dynamicVariants.contains($0.id) }
    }
}
