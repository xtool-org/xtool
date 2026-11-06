# Upload to TestFlight

Send a built `.ipa` to App Store Connect from the command line.

## Overview

`xtool upload` uploads an `.ipa` to App Store Connect, where it becomes a build that you can distribute with TestFlight or submit for review. It uses Apple's [Build Uploads](https://developer.apple.com/documentation/appstoreconnectapi/build-uploads) API, so it works the same on Linux, macOS and WSL, and doesn't need Xcode or Transporter.

Before you start, you need

- A paid Apple Developer Program membership.
- An [App Store Connect API key](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api) with the App Manager (or Admin) role. xtool must be logged in with it, which you do with `xtool auth login --mode key`.
- An app record in App Store Connect with the same bundle ID as your app. The API can't create it for you.

## Upload a build

```bash
xtool upload path/to/App.ipa --wait
```

xtool reads the bundle ID, version and build number from the `.ipa`, finds your app in App Store Connect, sends the file, and with `--wait` stays until Apple has processed the build. If Apple rejects it, the reasons Apple gives are printed.

Each upload needs a build number (`CFBundleVersion`) that is higher than the previous uploads of the same version (`CFBundleShortVersionString`).

If the app can't be found from its bundle ID, pass its App Store Connect ID with `--app-id`.

## Check the .ipa first

Processing takes a few minutes and Apple only reports problems at the end. `xtool upload` therefore checks the `.ipa` locally before it sends anything, and refuses to upload when it finds something that Apple is known to reject:

- `Payload/` doesn't contain exactly one `.app`, or `Info.plist` lacks `CFBundleIdentifier`, `CFBundleShortVersionString` or `CFBundleVersion`.
- The icon doesn't come from a compiled asset catalog: `Assets.car` or `CFBundleIconName` is missing.
- `embedded.mobileprovision` is missing, isn't an App Store distribution profile, grants `get-task-allow`, or is for another bundle ID.

It also warns when the `Info.plist` lacks the keys that Xcode adds (`DTXcode`, `DTXcodeBuild`, `DTSDKBuild`, `DTPlatformName` and so on). Apple may reject such a build with "Unsupported SDK or Xcode version".

Use `--check` to only run these checks, which needs no login, and `--dry-run` to also look up the app without uploading. If you know better than the checks, `--skip-check` uploads anyway.

> Important:
>
> A build from `xtool dev build` is signed for development, so it fails the checks above. `xtool upload` uploads an `.ipa` that is already ready for the App Store, for example one built on a Mac.
