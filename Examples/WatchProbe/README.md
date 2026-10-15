# Watch Probe

A small native SwiftUI app for testing the experimental xtool watchOS pipeline
on an Apple Watch Ultra 2. Requires watchOS 10 or later.

Swipe vertically between three screens:

- **Counter:** tap +1 to feel a haptic. The count persists when the app closes.
- **Timer:** start, pause, resume, and reset a session stopwatch.
- **Connection:** explicitly send a small HTTPS GET request to Apple's
  `www.apple.com/library/test/success.html` and display the result.
  Build 0.1.2 waits up to 30 seconds for connectivity and
  displays the URL loading error code on failure. Keep the app open while checking.
  No account or sensor permissions are needed.

The timer is a session test, not a background workout timer. Network success
does not tell whether the Watch used Wi-Fi, cellular, or the paired iPhone.

## Build

With the modified xtool and Watch SDK installed, run from this directory:

```sh
xtool dev build --triple arm64-apple-watchos
```

Use your own unique bundle ID before signing. Follow the
[watchOS signing and deployment instructions](../../Documentation/xtool.docc/WatchOS.md).
No signed IPA, Apple SDK, provisioning profile, or pairing keys are distributed
with this example. Free-account development builds need renewal after seven days.

Builds were verified for arm64_32, arm64 and the Intel Watch simulator.
The Ultra 2 running watchOS 27.0.1 requires the arm64 device build; its installer
rejects arm64_32. A signed arm64 build was installed successfully from
Windows through the paired USB iPhone using streaming_zip_conduit. App presence
was verified through the Watch's installation service. The owner confirmed the
app opens and responds. The example.com check timed out with URL error -1001.
Build 0.1.2 tests a small Apple-hosted page. The owner confirmed that it returns
Connected with HTTP 200 on the physical Watch, validating foreground HTTPS access.
The signing profile includes the intended Watch, matches the bundle identifier,
and passed CMS signature verification. Executable CodeDirectory page hashes
also matched. Installation verification does not by itself confirm launch.
