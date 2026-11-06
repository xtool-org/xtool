# Experimental React Native iOS build on Linux

This experiment for [#364](https://github.com/xtool-org/xtool/issues/364)
compiles a small React Native app on Linux and uses **xtool to sign and install
it on an iPhone**. Native compilation uses a separate CocoaPods-to-Clang adapter
in this directory; `xtool dev build` does not build this project.

The app renders a real React Native JavaScript screen with a `Pressable` and a
React `useState` counter. It uses React Native **0.77.3**, React **18.3.1**, the
**legacy bridge/Paper renderer**, and the iOS system **JavaScriptCore** engine.
A release JavaScript bundle is embedded in the application. No web view, Expo Go,
remote Mac, or precompiled React Native library is involved.

This is a feasibility example, not general React Native project support. It does
not implement Expo modules, Hermes, the New Architecture, Swift pods, arbitrary
CocoaPods build phases/resources, simulator builds, or Fast Refresh. Updating
React Native requires reviewing the adapter and its two dependency patches.

## Prerequisites

- Linux with Python 3.10+, Bash, Node.js/npm, Ruby 3.2+, Ruby development headers,
  `make`, a host C compiler, Git, curl, and standard archive utilities. Native Ruby
  gems may need your distribution's development packages. The tested host was
  Omarchy x86_64 with Node 26.12.1, Ruby 3.4.10 and Python 3.14.
- Linux Clang/Clang++, `llvm-ar`, and **`ld64.lld`** (the Mach-O LLD driver).
  Tested with LLVM **23.1.3**. This example does not install system packages.
- A genuine **iPhoneOS device SDK**, obtained from your own Apple Xcode download,
  and the corresponding Xcode toolchain's **`libclang_rt.ios.a`**. Tested with
  Xcode/iPhoneOS **27.1** and its Clang 21 availability archive. No Apple files
  are distributed here. The minimum app deployment target is **iOS 15.1**.
- [xtool](../../Documentation/xtool.docc/Installation-Linux.md), tested with
  **1.24.0**, and a signing identity configured using its interactive login.
  Pair/trust the USB-connected iPhone and enable Developer Mode as required by
  xtool. Signing credentials stay in xtool's storage, outside this example.

Download Xcode from [Apple Developer Downloads](https://developer.apple.com/download/all/?q=Xcode).
Supply SDK/toolchain paths from an extraction that **preserves Xcode archive
hardlinks**. A naive selective CPIO extraction can leave `NULLcanary` placeholder
headers when the shared file's first entry belongs to another platform. The
preflight checks one representative header; it cannot certify the whole SDK.
SDK acquisition/extraction is an external prerequisite of this example.

## Setup and build

From this directory, set the two Apple input paths (substitute your own location):

```bash
export XCODE_ROOT=/path/to/extracted/Xcode.app
export IOS_SDK="$XCODE_ROOT/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
# Use the version directory present in your matching Xcode toolchain:
export IOS_AVAILABILITY_LIBRARY="$XCODE_ROOT/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin/libclang_rt.ios.a"

bash scripts/setup.sh
bash scripts/build.sh
```

The native Linux tools default to those on `PATH`. Override any with an executable
path using `CLANG`, `CLANGXX`, `LD64_LLD`, or `LLVM_AR`. If your tools are extracted
outside the system installation, configure their shared-library search path
(e.g. `LD_LIBRARY_PATH`) as required by your distribution. Keep the same exported
configuration when rebuilding.

`setup.sh` runs `npm ci --ignore-scripts` from the npm lockfile and installs
Bundler 2.6.9 and the locked Ruby gems into the ignored `.cache/` directory.
CocoaPods is pinned to **1.17.0**, with erb **6.0.7** for distributions that package
it separately. `build.sh` uses `pod install --deployment` with the checked-in
Podfile lock. Re-running setup intentionally restores npm dependency sources;
`build.sh` applies the patches again after dependency resolution.

The unsigned output is `build/OmarchyReactNative.app`. Inspect generated
`build/compile_commands.json`, `build/link-command.json`, and `build/link.map`
for the actual native build commands. Logs go to the ignored `evidence/`
directory. Objects are cached using command/compiler identity and dependency
modification times; remove `build/` for a clean native build after replacing a
compiler or SDK in place.

## Install and exercise

With the phone connected, unlocked and trusted, and xtool authentication set up:

```bash
xtool install --usb build/OmarchyReactNative.app
```

For an AppImage installation, use the equivalent invocation for your environment
(e.g. `APPIMAGE_EXTRACT_AND_RUN=1 /path/to/xtool.AppImage install --usb ...`). xtool
provisions/signs a staged copy of the app and installs it. This may register the
sample bundle identifier in your selected development team. The local input app
remains unsigned.

Open **React Native Linux** from the iPhone Home Screen. Confirm that **Hello from
Omarchy.** appears and tapping **Add one** changes the counter from 0 to 1 to 2.
The sample emits `[OmarchyRN]` native and JavaScript logs, including each counter
value. See [VALIDATION.md](VALIDATION.md) for recorded results and limitations.

## Adapter design and compatibility patches

`ios/Podfile` uses React Native's standard CocoaPods dependency definitions with
Hermes and the New Architecture disabled. It skips the host Xcode/Rosetta probes,
then exports resolved source paths, per-file compiler flags, Release settings,
frameworks, weak frameworks, and libraries into `native-build-manifest.json`.
It does not run an Xcode build. CocoaPods still resolves some Fabric-related
source targets; this does not make the app a New Architecture app.

`scripts/build-native.py` compiles that fixed source graph with Linux Clang for
arm64 iOS, creates Darwin archives with `llvm-ar`, and links using `ld64.lld`.
The linker SDK version comes from `SDKSettings.plist`. The adapter represents
Xcode header maps with CocoaPods header directories, explicitly includes the
existing `RCTTurboModule.h` definition for textual compilation of
`RCTCxxBridge.mm`, and links CoreText plus Apple's availability helpers.
Unresolved native symbols are errors; no dummy implementations are supplied.

The project-scoped `tools/bin/xcrun` supports only glog's compiler and SDK lookup
queries. Its `ios-clang` wrapper invokes the configured real Clang and LLD. Other
queries fail explicitly; these wrappers are not installed system-wide.

Two version-checked, idempotent source adjustments are applied to downloaded
sources only, with replacement files to preserve CocoaPods cache hardlinks:

- [React Native WebSocket signature](patches/react-native-0.77.3-websocket-signature.patch):
  match the implementation's socket identifier type to its existing `NSNumber *`
  public declaration/dictionary keys.
- [fmt 11.0.2 format checker](patches/fmt-11.0.2-constexpr-identity.patch):
  make the constexpr parser and checker share the stored string view, avoiding
  repeated wrapper conversions producing distinct string-literal pointers under
  newer Clang. This follows the diagnosis in
  [fmt #4177](https://github.com/fmtlib/fmt/issues/4177); compile-time checking stays
  enabled. This is a local compatibility patch, not a claim of upstream acceptance.

The example's original source uses the repository's MIT license. Downloaded React
Native, fmt, CocoaPods and their dependencies retain their respective licenses;
installation leaves their license files in their dependency directories. The
patch files are small diffs against React Native (Meta, MIT) and fmt (Victor
Zverovich and contributors, MIT). Apple SDK/toolchain files remain external and
subject to Apple's terms.

## Regression checks

These checks require neither an Apple SDK nor signing credentials:

```bash
python3 -m unittest discover -s tests -v
bash -n scripts/*.sh tools/bin/*
ruby -c ios/Podfile
```

They cover SDK validation, paths with spaces, inherited/per-file build flags,
header-driven cache invalidation, failed-compilation cancellation, safe/idempotent
patching, and explicit rejection of unsupported xcrun queries. A separate CI job
runs them without Apple downloads. This example is intentionally excluded from
`Examples/test.sh`, whose fixtures are SwiftPM simulator apps.
