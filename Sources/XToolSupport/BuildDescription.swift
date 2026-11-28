import Foundation
import XPIF

struct BuildDescription {
    var directory: URL
    var pif: XPIF.Container
    var configuration: BuildConfiguration
    var triple: String
    var hotReloadable = false

    struct TargetSelection {
        var application: XPIF.GUID
        var buildTargets: [XPIF.GUID]
        var buildImplicitDependencies: Bool
    }

    var targetSelection: TargetSelection?
}

enum BuildConfiguration: String, CaseIterable, Sendable {
    case debug
    case release

    var swiftBuildValue: String {
        switch self {
        case .debug: "Debug"
        case .release: "Release"
        }
    }
}
