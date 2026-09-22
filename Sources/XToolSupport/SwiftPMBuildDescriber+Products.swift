import Foundation
import XCLIUtils
import XPIF
import XUtils

extension SwiftPMBuildDescriber {
    func bundleProducts(in project: XPIF.Project) throws -> [ProjectProduct] {
        let idSpecifier = try self.project.base.schema.idSpecifier.orThrow(
            Console.Error("xtool.yml: Must specify either orgID or bundleID")
        )
        let appProduct = try libraryProduct(in: project, matching: schema.product)
        let app = ProjectProduct(
            packageProduct: appProduct,
            isExtension: false,
            bundleID: idSpecifier.formBundleID(product: appProduct.name.withoutSuffix("-product")),
            infoPath: schema.infoPath,
            resources: schema.resources ?? [],
            iconPath: schema.iconPath,
            entitlementsPath: schema.entitlementsPath,
        )
        let extensions = try (schema.extensions ?? []).map { ext in
            let product = try libraryProduct(in: project, matching: ext.product)
            return ProjectProduct(
                packageProduct: product,
                isExtension: true,
                bundleID: ext.bundleID ?? "\(app.bundleID).\(product.name.withoutSuffix("-product"))",
                infoPath: ext.infoPath,
                resources: ext.resources ?? [],
                iconPath: nil,
                entitlementsPath: ext.entitlementsPath,
            )
        }
        return [app] + extensions
    }

    private func libraryProduct(in project: XPIF.Project, matching expected: String?) throws -> XPIF.Target {
        let products = Self.products(in: project).filter {
            [.packageProduct, .staticArchive].contains($0.productType)
        }
        if let expected {
            return try products.first { $0.name == "\(expected)-product" }
                .orThrow(Console.Error("Could not find library product '\(expected)'"))
        }
        switch products.count {
        case 0: throw Console.Error("Could not find any library products in main target")
        case 1: return products[0]
        default: throw Console.Error("Found multiple library products in main target; specify 'product' in xtool.yml")
        }
    }
}

struct ProjectProduct {
    var packageProduct: XPIF.Target
    var product: String { packageProduct.name.withoutSuffix("-product") }
    var isExtension: Bool
    var bundleID: String
    var infoPath: String?
    var resources: [String]
    var iconPath: String?
    var entitlementsPath: String?

    var targetName: String { "\(product)-\(isExtension ? "Extension" : "App")" }

    func infoPlistConfiguration(
        at root: URL,
    ) throws -> (contents: [String: Any], settings: XPIF.BuildSettings) {
        var plist: [String: Any] = [:]
        if let path = infoPath {
            let data = try Data(contentsOf: URL(fileURLWithPath: path, relativeTo: root))
            plist = try (PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
                .orThrow(Console.Error("Info.plist has invalid format: expected a dictionary."))
        }
        if let iconPath {
            plist["CFBundleIconFile"] = URL(fileURLWithPath: iconPath).deletingPathExtension().lastPathComponent
        }

        var settings = XPIF.BuildSettings()
        settings[.GENERATE_INFOPLIST_FILE] = "YES"
        settings[.PRODUCT_NAME] = product
        settings[.PRODUCT_BUNDLE_IDENTIFIER] = plistSetting(plist, "CFBundleIdentifier", "PRODUCT_BUNDLE_IDENTIFIER", bundleID)
        settings[.CURRENT_PROJECT_VERSION] = plistSetting(plist, "CFBundleVersion", "CURRENT_PROJECT_VERSION", "1")
        settings[.MARKETING_VERSION] = plistSetting(plist, "CFBundleShortVersionString", "MARKETING_VERSION", "1.0.0")
        let families = (plist.removeValue(forKey: "UIDeviceFamily") as? [Int]) ?? [1, 2]
        settings[single: "TARGETED_DEVICE_FAMILY[sdk=iphone*]"] = families.map(String.init).joined(separator: ",")
        if plist["CFBundleExecutable"] != nil {
            settings[single: "EXECUTABLE_NAME"] = plistSetting(plist, "CFBundleExecutable", "EXECUTABLE_NAME", product)
        }
        if plist["CFBundleDevelopmentRegion"] != nil {
            settings[single: "DEVELOPMENT_LANGUAGE"] = plistSetting(plist, "CFBundleDevelopmentRegion", "DEVELOPMENT_LANGUAGE", "en")
        }
        if !isExtension {
            if plist["UILaunchScreen"] == nil {
                settings[single: "INFOPLIST_KEY_UILaunchScreen_Generation[sdk=iphone*]"] = "YES"
            }
            // Swift Build unions arrays when merging; only supply defaults for absent keys.
            if plist["UISupportedInterfaceOrientations"] == nil {
                settings[multiple: "INFOPLIST_KEY_UISupportedInterfaceOrientations[sdk=iphone*]"] = [
                    "UIInterfaceOrientationPortrait",
                ]
            }
            if plist["UISupportedInterfaceOrientations~ipad"] == nil {
                settings[multiple: "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad[sdk=iphone*]"] = [
                    "UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight",
                ]
            }
        }
        return (plist, settings)
    }

    private func plistSetting(_ plist: [String: Any], _ key: String, _ setting: String, _ fallback: String) -> String {
        // Standard Info.plists often reference the very build setting we're deriving.
        // Substitute its default instead of introducing a self-referential setting.
        ((plist[key] as? String) ?? fallback)
            .replacingOccurrences(of: "$(\(setting))", with: fallback)
            .replacingOccurrences(of: "${\(setting)}", with: fallback)
    }
}
