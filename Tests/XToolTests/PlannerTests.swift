import Foundation
import Testing
@testable import PackLib

// Shaped like `swift package dump-package` output.
private let manifestJSON = Data("""
{
  "targets": [
    {
      "name": "Crypto",
      "dependencies": [
        { "target": ["CCryptoBoringSSL", { "platformNames": ["linux", "android"] }] },
        { "target": ["Shared", null] },
        { "byName": ["OnlyOnIOS", { "platformNames": ["ios", "macos"] }] },
        { "byName": ["Unconditional", null] },
        { "product": ["LinuxProduct", "some-package", null, { "platformNames": ["linux"] }] },
        { "product": ["AliasedProduct", "other-package", { "Foo": "Bar" }, null] }
      ]
    },
    {
      "name": "Leaf",
      "dependencies": []
    }
  ]
}
""".utf8)

@Test func manifestExcludesDependenciesConditionedOffIOS() throws {
    let manifest = try JSONDecoder().decode(PackageManifest.self, from: manifestJSON)
    #expect(manifest.dependenciesExcluded(onPlatform: "ios") == [
        "Crypto": ["CCryptoBoringSSL", "LinuxProduct"],
    ])
}

@Test func manifestKeepsDependenciesConditionedOnTargetPlatform() throws {
    let manifest = try JSONDecoder().decode(PackageManifest.self, from: manifestJSON)
    #expect(manifest.dependenciesExcluded(onPlatform: "linux") == [
        "Crypto": ["OnlyOnIOS"],
    ])
}
