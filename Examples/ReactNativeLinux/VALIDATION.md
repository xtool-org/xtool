# Validation record

## Original device proof — 2026-10-28

A standalone copy of this example was compiled and linked on Omarchy x86_64 using
Linux Clang/LLD 23.1.3 and Apple's iPhoneOS 27.1 SDK. All 683 dependency translation
units plus the Objective-C++ app entry point were compiled locally. Metro bundled
React Native 0.77.3 / React 18.3.1 JavaScript locally.

xtool 1.24.0 provisioned, signed, and installed the app on an iPhone16,2 running
iOS 27.0.1. The owner confirmed that the screen rendered and tapping **Add one**
incremented the counter. Device logs independently recorded these messages
(timestamps and process/device identifiers omitted):

```text
[OmarchyRN] RCTRootView attached to iPhone window
[OmarchyRN] registering React Native JavaScript screen
Running "OmarchyReactNative"
[OmarchyRN] counter=1
[OmarchyRN] counter=2
[OmarchyRN] counter=3
```

`llvm-nm` independently found `RCTBridge`, `RCTRootView`, `RCTUIManager`, and
`facebook::jsc::makeJSCRuntime` in the native executable. The executable links
Apple's JavaScriptCore framework and loads the app's embedded `main.jsbundle`.
This verifies a native React Native screen and JavaScript state updates, rather
than just a successful native link or JavaScript bundle.

The first install crashed because the scene-based application delegate lacked
the legacy `window` accessor used by `RCTDeviceInfo`. Build 2 added that property
and assigns the scene window to it; that is the version included here and tested
successfully. The complete standalone build command was rerun afterward and
reproduced its native executable and JavaScript bundle hashes.

## Packaged example — 2026-10-29

The example was built again from `Examples/ReactNativeLinux` in the xtool fork,
with a fresh npm install, fresh project-local Ruby/CocoaPods dependencies and
**no copied native objects**. `scripts/build.sh` passed CocoaPods deployment-mode
resolution, Metro bundling, compilation of all **684** native files, Darwin archive
creation and the final Mach-O arm64 link. The native graph contained 54 source
targets (16 `.cc`, 156 `.m`, 272 `.cpp`, 236 `.mm`, and 4 `.S` files including
the app entry point).

The resulting executable again contains `RCTBridge`, `RCTRootView`, `RCTUIManager`
and `facebook::jsc::makeJSCRuntime`. The app's `ios/Main.mm` and `index.js` match
the original device-tested source byte for byte. This packaged build has not
been reinstalled on the phone; the device was disconnected during validation.

SHA-256 values for this local build (not a promise of reproducibility across
paths/toolchain versions):

```text
native: f62db7e85849c2110100c1dc686bc273e6cff4e85f4229f4e638acbaf1c3faec
bundle: 7ba565a8fea61eea81b4cb78826026ccbd3c555faff29f6be459aa7448b742ba
```

Six SDK-free Python regression checks passed, as did Bash/Ruby syntax checks,
workflow YAML parsing and the frozen Ruby dependency check. `make lint` was
attempted as required by the repository, but SwiftLint 0.65.1 could not start on
this host because `libxml2.so.2` was unavailable. No Swift source was changed;
core Swift build/tests were not run locally. The new CI job tests only the
SDK-free adapter logic, not a complete native/device build.

## Known device limitations

- Home Screen launch worked. Automatic `xtool launch` returned
  `DebugserverClient.Error.unknown`; automatic launch is not claimed as passing.
- A screenshot could not be captured because screenshotr required a mounted
  developer disk image. No automated screenshot/UI test is claimed.
- RN logged one non-fatal `Unbalanced calls start/end for tag 19` message during
  startup. The screen and counter still worked; the warning is unresolved.
- No Hermes, New Architecture, Expo modules, arbitrary third-party native pods,
  live Metro/Fast Refresh, macOS build, or WSL build was tested.

Raw crash reports, phone logs, signing identities, credentials, Apple SDK files,
dependency caches and compiled artifacts are excluded from this contribution.
