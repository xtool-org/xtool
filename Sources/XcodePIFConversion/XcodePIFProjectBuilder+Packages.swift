import Foundation
import XcodeProjects
import XPIF

extension XcodePIFProjectBuilder {
    func packageProduct(_ reference: XCSchema.SwiftPackageProductReference) throws -> XPIF.BaseTarget {
        if reference.productType == .buildToolPlugin {
            // TODO: Xcode targets would need us to run the plugin ourselves, via XcodeProjectPlugin
            throw ConversionError("""
            Plugin '\(reference.productName)' is applied to an Xcode target, which xtool \
            does not support yet.

            You can apply the plugin to a SwiftPM target instead.
            """)
        }
        let candidates = packageProjects.filter { project in
            guard let name = reference.package?.packageName.lowercased() else { return true }
            return project.name.lowercased() == name || project.id.value == "PACKAGE:\(name)"
        }.flatMap(\.targets).filter {
            $0.id.value.hasPrefix("PACKAGE-PRODUCT:") && $0.common.name == "\(reference.productName)-product"
        }
        switch candidates.count {
        case 0:
            throw ConversionError("Missing Swift package product '\(reference.productName)'.")
        case 1:
            return candidates[0]
        default:
            throw ConversionError("Found multiple Swift package products with name '\(reference.productName)'.")
        }
    }
}
