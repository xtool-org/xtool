import Testing
@testable import XKit

private let identifierTestAuth = DeveloperAPIAuthData.appStoreConnect(
    .init(id: "TEST", issuerID: "01234567-89AB-CDEF-0123-456789ABCDEF", pem: "unused")
)

@Test(arguments: ["com.example.app", "com.example.app.extension", "XTL-OLD.com.example.app"])
func preservesExactExistingBundleIdentifiers(identifier: String) {
    let context = SigningContext(auth: identifierTestAuth, preserveBundleID: true)
    #expect(ProvisioningIdentifiers.bundleID(from: identifier, context: context) == identifier)
}

@Test func defaultSigningRetainsScopedBundleIdentifier() {
    let context = SigningContext(auth: identifierTestAuth)
    #expect(ProvisioningIdentifiers.bundleID(from: "com.example.app", context: context) == "XTL-01234567.com.example.app")
}
