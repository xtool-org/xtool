import XCLIUtils
import XUtils
import XPIF
import Foundation

struct BuildDescription {
    var directory: URL
    var pif: XPIF.Container
    var configuration: BuildConfiguration
    var triple: String

    init(pif: XPIF.Container, buildSettings: BuildSettings) {
        self.directory = URL(filePath: buildSettings.packagePath)
        self.pif = pif
        self.configuration = buildSettings.configuration
        self.triple = buildSettings.triple
    }
}
