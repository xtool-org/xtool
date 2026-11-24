# XPIF

A model of SwiftBuild's Project Interchange Format (PIF).

## Commandments

### Round tripping is critical

Decoding and re-encoding PIF JSON should preserve fields and values. `additionalFields` is your friend. Prefer RawRepresentable structs (with `static let` constants) over String enums.

### Easy mutation

Fields should be mutable so they're easy to modify.

## License

XPIF adapts parts of [swift-build](https://github.com/swiftlang/swift-build/tree/3125911a8d/Sources/SwiftBuild/ProjectModel) and [swift-package-manager](https://github.com/swiftlang/swift-package-manager/blob/28b775e7/Sources/SwiftBuildSupport/PIF.swift), and is licensed under Apache 2.0 with the Runtime Library Exception. See [LICENSE.txt](./LICENSE.txt).
