import SwiftBuild
// we don't want to import SWB* in other places
private import SWBBuildService

extension SWBBuildServiceConnectionMode {
    static var xtool: Self {
        .inProcessStatic(swiftbuildServiceEntryPoint)
    }
}
