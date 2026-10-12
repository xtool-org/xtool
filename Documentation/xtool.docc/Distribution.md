# Sign for distribution

Produce an `.ipa` for TestFlight, the App Store or Ad Hoc distribution, entirely offline.

## Overview

`xtool dev` normally signs your app with a development certificate that xtool creates for you through your Apple ID. That is what you want for running on your own device, but an App Store or Ad Hoc build needs a **distribution** certificate and a matching provisioning profile.

xtool can sign with a distribution identity you already have. It never contacts Apple in this mode: it doesn't create, renew or revoke any certificate or profile, so it is safe to run in CI.

You need:

- An **Apple Distribution** certificate with its private key, exported as a `.p12` file (in Keychain Access, or with `openssl pkcs12 -export`).
- An **App Store** or **Ad Hoc** provisioning profile (`.mobileprovision`) for your app's bundle ID, created with that certificate on the Apple Developer portal.

## Sign a build

Pass the identity and the profile to `xtool dev build`:

```bash
export XTOOL_P12_PASSWORD='<password>'
xtool dev build --configuration release --ipa \
    --p12 Distribution.p12 \
    --profile MyApp_AppStore.mobileprovision
```

The password is read from the `XTOOL_P12_PASSWORD` environment variable, or from a file with `--p12-password-file`. Use `--p12-password-env` to read a different variable. It is deliberately not accepted as a command-line argument, since arguments are visible to other users of the machine and end up in shell history and CI logs.

## Re-sign an existing `.ipa`

`xtool sign` re-signs an `.ipa` (or an `.app`) that was built elsewhere, and writes a new `.ipa`. The input is left untouched.

```bash
xtool sign MyApp.ipa \
    --p12 Distribution.p12 \
    --profile MyApp_AppStore.mobileprovision \
    --output MyApp-signed.ipa
```

## What gets signed

xtool checks the inputs before it signs anything, and refuses to continue if:

- the certificate is not a distribution certificate, or has expired;
- the profile is a development profile, has expired, belongs to another team, or doesn't include your certificate;
- no profile matches the app's bundle ID.

The entitlements are derived from the profile, so that the signature matches what the profile allows:

- `application-identifier` and `com.apple.developer.team-identifier` always come from the profile.
- `get-task-allow` is never included.
- Capabilities the profile grants, such as `aps-environment` (`production` in a distribution profile), app groups and `beta-reports-active`, are carried over.
- Wildcards in the profile are resolved for your app. For example, `keychain-access-groups` of `<team>.*` becomes your app's own group.
- Entitlements already present in the app's signature (for instance those from your `.entitlements` file) narrow what is taken from the profile. Asking for something the profile doesn't allow is an error.

To use a specific set of entitlements instead of the ones already in the app, pass `--entitlements Entitlements.plist`.

The profile is copied into the app as `embedded.mobileprovision`.

## Limitations

Apps with extensions (`.appex`) or a watch app can't be signed for distribution yet. The signer applies a single set of entitlements to the whole bundle, and an extension needs its own. xtool stops with an error instead of producing a signature the App Store would reject.
