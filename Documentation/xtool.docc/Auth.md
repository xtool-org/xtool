# Authenticate with your Apple Account

Sign in to Apple Developer Services and choose the device profile used by xtool.

## Overview

xtool needs access to Apple Developer Services to sign and install apps on a physical device. To log in, run

```bash
xtool auth
```

If you use an Apple ID and password, xtool emulates a Mac to authenticate with Apple. You can choose which device identity it presents.

> Note:
>
> Password-based authentication uses private Apple APIs. If you have a paid Apple Developer Program membership, you can instead select API Key authentication.

## Choose a device profile

After selecting Password login, you'll be asked to choose a profile:

```
Select Apple device profile
0: Provider default (identity supplied by the Anisette server)
1: Modern Mac (macOS 27; for Advanced Data Protection accounts, experimental)
Choice (0-1):
```

- **Provider default:** Uses the Mac identity returned by the Anisette server. This is xtool's original behavior.
- **Modern Mac:** Uses a Mac17,3 running macOS 27 with the `akd` client. Try this if Apple rejects the provider's older macOS identity, for example with Advanced Data Protection enabled.

You can also select a profile without the interactive prompt:

```bash
xtool auth login --mode password --mac-profile modern
```

> Note:
>
> The modern profile only changes the device identity sent to Apple. It doesn't update the remote Anisette server, and Apple may reject this identity in the future.

## Change your saved profile

xtool saves your selection so it can use the same identity for subsequent commands, including `xtool dev run`.

To see your current profile, run

```bash
xtool auth profile
```

You can switch profiles without logging in again:

```bash
xtool auth profile modern
xtool auth profile provider
```

Changing profiles doesn't delete saved credentials or reset Anisette provisioning. If signing or provisioning fails after switching identities, you may need to log in again.

## Environment variables

For scripts, you can override the saved profile using `XTL_GSA_MAC_PROFILE`:

```bash
XTL_GSA_MAC_PROFILE=modern xtool dev run --network
```

Use `modern` or `provider`. The environment variable takes precedence over the saved preference. When used during password login, its value is saved for later commands too.

Don't use `--mac-profile` and `XTL_GSA_MAC_PROFILE` together during login.

## Two-factor authentication

When Apple asks you to verify your sign-in, xtool lets you choose between automatic verification, a trusted Apple device, a manually generated verification code, or SMS.

If you choose a manual code, generate it on one of your trusted Apple devices and enter it when xtool prompts you.

## Troubleshooting

To see which GrandSlam requests fail, enable HTTP status tracing:

```bash
XTL_GSA_TRACE=1 xtool auth login --mode password --mac-profile modern
```

The trace prints request names and HTTP status codes, without logging request or response contents.

> Tip:
>
> Avoid sharing Apple ID passwords, verification codes, or authentication tokens when reporting login issues.
