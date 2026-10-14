# Configure packaging

Describe a SwiftPM application's target, products and prepared inputs in `xtool.yml`.

## Version 2

Version 1 retains the existing iOS configuration. Version 2 adds `target`,
`deploymentTarget`, `source`, `resourceCopies` and `nestedProducts`; using these
fields in version 1 is rejected. See <doc:MacOS> for target precedence, supported
backends and build commands.

The example below packages an app with an extension, XPC service and helper.
Supply the referenced plist, entitlement and icon files alongside your package.

```yaml
version: 2
bundleID: com.example.app
product: MyApp
target: arm64-apple-macosx15.0
deploymentTarget: '15.0'
source: {kind: executable, product: MyApp}
infoPath: Support/App-Info.plist
entitlementsPath: Support/App.entitlements
iconPath: Support/App.icns
nestedProducts:
  - product: MyExtension
    kind: appExtension
    bundleID: com.example.extension
    source: {kind: library, product: MyExtension}
    infoPath: Support/Extension-Info.plist
    entitlementsPath: Support/Extension.entitlements
  - product: MyService
    kind: xpcService
    bundleID: com.example.xpc
    source: {kind: executable, product: MyService}
    infoPath: Support/XPC-Info.plist
    entitlementsPath: Support/XPC.entitlements
  - product: MyHelper
    kind: helperExecutable
    bundleID: com.example.helper
    source: {kind: executable, product: MyHelper}
```

## Fields and product sources

| Field | Contract |
| --- | --- |
| `version` | Required schema version, `1` or `2`. |
| `bundleID` / `orgID` | At least one is required. `bundleID` takes precedence; `orgID` derives `<orgID>.<product>`. |
| `product` | Output/application product name. Use an explicit name when the package has multiple candidates. |
| `target` | Apple target triple, independent of host OS; CLI `--triple` takes precedence. |
| `deploymentTarget` | Numeric OS version; cannot lower the package or platform minimum. |
| `source` | Tagged product source described below; explicit in this example. |
| `infoPath` | Caller plist dictionary merged over generated defaults; caller identifiers and extension/XPC metadata are preserved. |
| `entitlementsPath` | Caller plist dictionary associated with this product for the later signer. |
| `iconPath` | Prepared `.png` or `.icns` in version 2; ICNS requires macOS. |
| `resources` | Legacy list of files/directories copied to the product's resources directory: the bundle root on iOS, `Contents/Resources` on macOS. |
| `resourceCopies` | Explicit copies with `source` and `destination: {location, path}`. |
| `nestedProducts` | Products with required `product`, `kind` and `source`; optional `bundleID`, `infoPath`, `entitlementsPath`, `resourceCopies`. |
| `extensions` | Existing extension list with required `product`/`infoPath`; version 2 also accepts `source`/`resourceCopies`. |
| `skipLSP` | Skip automatic creation of a missing LSP support file. |

Paths to input files resolve from the package directory. Product names must be
safe single path components; nested names must be unique. Extension and XPC
products require `infoPath`; helpers are bare executables without their own
Info.plist. `xpcService` and `helperExecutable` require a macOS target.

| `source.kind` | Required value | Build behavior |
| --- | --- | --- |
| `executable` | `product` | Build that SwiftPM executable directly; do not create a target depending on an executable product. |
| `library` | `product` | Create an executable wrapper linking that SwiftPM library; extensions use the extension entry point. |
| `prebuilt` | `path` | Validate and copy an existing target executable; do not compile it. |

SwiftPM sources cannot carry `path`; prebuilt sources cannot carry `product`.
The requested kind must match the selected package product. Omitted source
retains legacy product selection; explicit sources make multi-product packages
unambiguous. For prebuilt XPC services/helpers use `source.kind: prebuilt` with
a `path` to a compatible macOS Mach-O executable, while retaining the nested
product's `kind` and metadata. This form is covered by planner/builder tests;
the example above builds its XPC service/helper from source.
Prebuilt products with automatically discovered SwiftPM resources are rejected
because xtool cannot rewrite their compiled accessors. Supply explicit copies
and resource lookup implemented by that binary instead.

## macOS bundle and resource destinations

| Product kind | Executable relative to the outer app |
| --- | --- |
| `application` | `Contents/MacOS/<product>` |
| `appExtension` | `Contents/PlugIns/<product>.appex/Contents/MacOS/<product>` |
| `xpcService` | `Contents/XPCServices/<product>.xpc/Contents/MacOS/<product>` |
| `helperExecutable` | `Contents/Helpers/<product>` |

The outer application is selected at the schema root; `nestedProducts` cannot
contain `application`. App, extension and XPC plists live in their respective
`Contents/Info.plist`. Helpers have no plist. Dependency traversal follows
platform-conditional SwiftPM dependencies, collecting resource bundles, dynamic
libraries and compatible binary targets. Frameworks/dylibs are placed in each
owner's `Contents/Frameworks`; helper-owned frameworks use
`Contents/Helpers/Frameworks`, with a matching helper rpath.

`destination.location` is required in YAML and accepts:

| Location | Base for app/extension/XPC | Base for helper |
| --- | --- | --- |
| `resources` | The owner's `Contents/Resources` | Outer app's `Contents/Resources` |
| `contents` | The owner's `Contents` | Outer app's `Contents/Helpers` |
| `bundle` | The owner's bundle root | Outer app's `Contents/Helpers` |

`destination.path` is a nonempty relative path appended to that base. Absolute
paths, empty components, `.`, `..`, backslashes and NUL are rejected. Assembly
also rejects overlapping destinations, including case/Unicode-equivalent
collisions, and unsafe symlinks. Legacy `resources` copies into each product's
resources directory; use `resourceCopies` to choose another destination. Explicit extension resources
belong in the extension's Resources directory.

Source-built macOS SwiftPM resource accessors are adapted for relocated bundles;
separate relocation tests exercise the adapted `Bundle.module` accessor after
original build inputs are removed.
Prepared assets are copied without invoking `actool` or `ibtool`. Raw
`.xcassets`, `.iconset`, `.storyboard` and `.xib` inputs require preparation elsewhere;
SwiftPM resource bundles are copied as built, with any raw assets left uncompiled.

Caller plist values override generated defaults, including identifiers. Ensure
`CFBundleExecutable`, bundle kind and minimum OS agree with the actual product;
xtool does not translate an Xcode project's build settings or extension policy.
Deferred signing preserves entitlement dictionaries and their product associations
without approving or applying them.
