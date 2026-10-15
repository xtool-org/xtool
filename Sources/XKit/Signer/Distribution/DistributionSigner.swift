import Foundation

/// Signs an app for App Store, TestFlight or Ad Hoc distribution using an identity and profiles
/// that the user already owns. Unlike ``AutoSigner`` it never talks to Apple and never creates
/// or revokes certificates or profiles.
public struct DistributionSigner: Sendable {

    public struct Result: Sendable {
        public let bundleID: String
        public let entitlements: Entitlements
    }

    public let identity: DistributionIdentity
    public let profiles: [DistributionProfile]
    /// Entitlements to use instead of the ones found in the app's existing signature.
    public let entitlements: Entitlements?
    public let signer: Signer

    public init(
        identity: DistributionIdentity,
        profiles: [DistributionProfile],
        entitlements: Entitlements? = nil,
        signer: Signer? = nil
    ) throws {
        self.identity = identity
        self.profiles = profiles
        self.entitlements = entitlements
        self.signer = try signer ?? .first()
    }

    private struct Bundle {
        var url: URL
        var bundleID: String
        var profile: DistributionProfile
        var entitlements: Entitlements
    }

    /// Signs `app` in place.
    @discardableResult
    public func sign(
        app: URL,
        status: @escaping (String) -> Void = { _ in },
        progress: @escaping @Sendable (Double?) -> Void = { _ in },
        now: Date = Date()
    ) async throws -> Result {
        status(NSLocalizedString("signer.provisioning", value: "Provisioning", comment: ""))

        try identity.validate(now: now)
        for profile in profiles {
            try profile.validate(for: identity, now: now)
        }

        let bundles = try Self.appBundles(in: app)
        var prepared: [Bundle] = []
        for url in bundles {
            let bundleID = try Self.bundleID(of: url)
            guard let profile = profiles
                .compactMap({ profile in profile.specificity(forBundleID: bundleID).map { (profile, $0) } })
                .max(by: { $0.1 < $1.1 })?.0
            else { throw DistributionSigningError.noMatchingProfile(bundleID: bundleID) }

            let requested: Entitlements?
            if url == app, let entitlements {
                requested = entitlements
            } else {
                requested = await existingEntitlements(of: url)
            }
            prepared.append(Bundle(
                url: url,
                bundleID: bundleID,
                profile: profile,
                entitlements: try DistributionEntitlements.resolve(
                    profile: profile, bundleID: bundleID, requested: requested
                )
            ))
        }

        for bundle in prepared {
            let destination = bundle.url.appendingPathComponent("embedded.mobileprovision")
            if destination.exists {
                try FileManager.default.removeItem(at: destination)
            }
            try bundle.profile.mobileprovision.data().write(to: destination)
        }

        status(NSLocalizedString("signer.signing", value: "Signing", comment: ""))
        try await signer.sign(
            app: app,
            identity: .real(identity.certificate, identity.privateKey),
            entitlementMapping: Dictionary(uniqueKeysWithValues: prepared.map { ($0.url, $0.entitlements) }),
            progress: progress
        )
        progress(1)

        let root = prepared[0]
        return Result(bundleID: root.bundleID, entitlements: root.entitlements)
    }

    /// The app followed by its extensions
    private static func appBundles(in app: URL) throws -> [URL] {
        guard app.dirExists else { throw DistributionSigningError.invalidApp("\(app.lastPathComponent) not found") }
        var bundles = [app]
        for pluginsDir in ["PlugIns", "Extensions"] {
            let plugins = app.appendingPathComponent(pluginsDir)
            guard plugins.dirExists else { continue }
            bundles += plugins.implicitContents.filter { $0.pathExtension.lowercased() == "appex" }
        }
        return bundles
    }

    private static func bundleID(of bundle: URL) throws -> String {
        let infoPlist = bundle.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = dict["CFBundleIdentifier"] as? String
        else { throw DistributionSigningError.invalidApp("cannot read CFBundleIdentifier in \(infoPlist.path)") }
        return bundleID
    }

    /// The entitlements currently embedded in the bundle's main executable, if it's signed
    private func existingEntitlements(of bundle: URL) async -> Entitlements? {
        let infoPlist = bundle.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let executable = dict["CFBundleExecutable"] as? String,
              let plist = try? await signer.analyze(executable: bundle.appendingPathComponent(executable))
        else { return nil }
        return DistributionEntitlements.parse(plist: plist)
    }

}
