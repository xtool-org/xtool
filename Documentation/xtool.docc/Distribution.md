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
- `get-task-allow` is always `false`.
- Like Xcode, xtool claims what the app asks for (the entitlements already in its signature, for instance those from your `.entitlements` file), checked against what the profile allows. Asking for something the profile doesn't allow is an error. `beta-reports-active` is carried over when the profile has it.
- If the app has no entitlements of its own, everything the profile grants is claimed, such as `aps-environment` (`production` in a distribution profile) and app groups.
- Wildcards in the profile are resolved for your app. For example, `keychain-access-groups` of `<team>.*` becomes your app's own group.

To use a specific set of entitlements instead of the ones already in the app, pass `--entitlements Entitlements.plist`.

Extensions (`.appex`) are signed with their own profile and entitlements. Pass one `--profile` per bundle: each bundle uses the profile that best matches its bundle ID.

The profile is copied into each bundle as `embedded.mobileprovision`.
