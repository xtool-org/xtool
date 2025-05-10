# macOS Packaging

xtool is packaged as a .app bundle on macOS, so that we can add entitlements and use the keychain.

Ideally we'd dogfood xtool to package xtool, but it only supports iOS apps right now. Someday, hopefully.

## Building

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen)
2. Run `xcodegen` inside this (`./macOS`) directory
3. Open the Xcode project and build the `XToolMac` scheme
