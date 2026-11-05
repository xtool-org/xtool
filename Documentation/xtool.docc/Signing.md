# Sign an existing app

Create a development-signed copy of an iOS or tvOS device app without rebuilding it.

## Overview

`xtool sign` accepts an existing `.app` directory or `.ipa` archive. It stages a copy, provisions and signs it using your saved `xtool auth` account, and writes a new `.app` or `.ipa`. The input remains unchanged. No Apple SDK is required for this command.

```bash
xtool sign Example.app --output Example-signed.ipa
xtool sign Example.ipa --output Example-signed.app --platform tvos
```

The output path must not exist, its parent directory must exist, and it must be outside the input app. IPA inputs must contain exactly one app directly inside `Payload`.

The signing platform is detected from the app's `CFBundleSupportedPlatforms`, or `UIDeviceFamily` when platform metadata is absent. Use `--platform ios` or `--platform tvos` if neither is present. An explicit platform must agree with the app's metadata. Simulator and macOS apps are not supported.

## Keep an existing bundle identifier

By default, signing adds xtool's account-specific prefix to the app and extension bundle identifiers. To keep their exact existing identifiers, use:

```bash
xtool sign Example.ipa --output Example-renewed.ipa --preserve-bundle-id
```

This also preserves identifiers that already start with `XTL-`. The identifiers must be available to the selected Apple Developer team. Keeping a bundle identifier does not transfer ownership of an app to another team. App-group identifiers still follow xtool's existing rewriting rules; this option does not promise continuity of shared containers or keychain data.

## Devices and renewal

The development profile includes compatible devices already registered with the account: Apple TVs for tvOS, and iPhones, iPads and iPods for iOS. Register the target device first using Xcode or the Apple Developer website, as supported by your account. Use `xtool ds devices list` to check registered devices. This command does not connect to, register or install on a device.

Signing uses xtool's existing certificate management and may prompt before revoking a certificate. Revocation can affect other installed development apps. Profile expiration and account limits remain Apple's limits, including short-lived profiles for free accounts. Run the command again with a fresh output path when renewing, then install the result using a deployment tool that supports your device and OS version.
