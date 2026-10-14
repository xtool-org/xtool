# Build macOS applications

Cross-compile a SwiftPM application on Linux and hand its assembled bundle to a Mac for signing.

## Supported build contract

macOS builds use the SwiftPM backend and require explicit deferred signing.

The CLI requires xtool, a matching Swift toolchain and an installed Darwin Swift
SDK on Linux, or a selected Xcode installation on macOS.

```sh
# Run in the application's directory beside Package.swift and xtool.yml.
xtool dev build --configuration release --defer-signing
```

Set `version: 2` and a macOS `target` in `xtool.yml`; see <doc:Configuration>.
The optional CLI `--triple arm64-apple-macosx15.0` overrides the schema target.
Omitting both retains the existing `arm64-apple-ios` default, even on a Mac.
The deployment version comes from the selected triple, then the schema's
`deploymentTarget`, then the package's platform minimum, then the platform
minimum (macOS 15.0). A selected version below any explicit schema/package
minimum or the platform minimum is rejected. The deployment version is recorded in the
products' binaries; each package's code still compiles for its own declared platforms, as with
`swift build`, so declare `platforms` to use newer APIs without availability checks.

The parser accepts arm64 and x86_64 macOS triples. Linux macOS Debug builds are rejected because SwiftPM
requires unavailable `codesign` support. Use Release. SwiftBuild is rejected
for macOS; its existing iOS support does not establish macOS support.

The output is `xtool/<product>.app`, accompanied by `<product>.signing.json`
and, when supplied, `<product>.signing-inputs/`. The CLI preserves copies of
caller entitlement dictionaries outside the app and rebases their paths in
the manifest. Transfer all three together. The manifest has `version: 1`,
`status: deferred`, a resolved target, and product bundle/executable paths with
their entitlement associations. It records signing intent, not release approval.

This route performs no Apple account provisioning or identity signing. Linker
ad-hoc signatures may already be present. `--sign`, IPA output and Xcode
project generation are unavailable for macOS targets. `xtool dev run` builds
and launches a local Mac app; `--app` launches an existing app without rebuilding. On a Mac,
`xtool dev sign` signs the handoff into a new directory (ad-hoc, Apple Development or
Developer ID, with an explicit certificate fingerprint) and `xtool dev notarize` submits
Developer ID output with an existing `notarytool` keychain profile. The handoff does not
select certificates or publish releases.

## Tests

The Swift Testing suite in `Tests/XToolTests` covers product selection, target
validation, nested bundle assembly, resource relocation and signing handoffs.
On macOS it compiles and executes disposable packages to test generated
`Bundle.module` lookup after removing the original build directory.
The Bats suite in `integration-tests/suite` exercises the public CLI using the
installed Darwin SDK.

## Boundaries

This support excludes native execution of macOS applications on Linux, an asset
compiler replacement, release publishing, universal binary
production and full Xcode project ingestion. Supply prepared ICNS/PNG,
`Assets.car`, storyboards or nibs where needed; raw asset catalogs, iconsets, storyboards
and xibs you supply are rejected by assembly. SwiftPM resource bundles are copied as
built, so raw assets inside them stay uncompiled. Certificate creation, identity selection and
provisioning-dependent entitlements remain separate work.
