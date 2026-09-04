# Run XCTest/XCUITest on a device

Build, install, and run your package's test targets on a real device -- no Xcode required.

## Overview

`xtool test` builds every `.testTarget` in your SwiftPM package into SwiftPM's own combined test
bundle (SwiftPM doesn't support separate per-target test products), packages it into a
`Runner.app` (matching Xcode's own `<Target>-Runner.app` convention), installs it on a connected
device, and drives it via the same `testmanagerd` protocol Xcode uses -- so you get real pass/fail
results, failure screenshots, and crash logs from an actual device, from Linux.

```bash
xtool test
```

`xtool test` only ever builds and installs the test Runner -- it never builds or installs your
main app product. For XCUITest targets that drive a separate app under test, install that app
first with `xtool install` or `xtool dev`, then point `xtool test` at it:

```bash
xtool test --test-target MyAppUITests --target-bundle-id com.example.MyApp
```

## Choosing what to run

If your package has more than one `.testTarget`, `xtool test` prompts you interactively to choose
one -- only one test target actually runs per invocation, since a UI test target and a plain unit
test target typically need different session settings (notably `--target-bundle-id`) and
shouldn't run mixed together in one session anyway. Skip the prompt with `--test-target`:

```bash
xtool test --test-target MyAppTests
```

To run (or exclude) specific tests within a target, use `--only`/`--skip` with a `TestClass` or
`TestClass/testMethod` identifier. Both are repeatable:

```bash
xtool test --only LoginTests --only SettingsTests/testLogout
xtool test --skip FlakyTests
```

> Note:
>
> A single on-device session reliably filters to *one* class-level identifier at a time -- running
> two whole classes' worth of tests in one filtered session is a real (confirmed) limitation of the
> on-device XCTest runner, not something `xtool test` can work around within a single session.
> `--test-target` and multiple `--only` values are handled correctly by running one session per
> class internally and aggregating the results, but each of those sessions needs its own app
> relaunch -- so a target with many test classes will take noticeably longer than one with a
> single class.

## Reports and artifacts

Write machine-readable reports with `--junit`, `--json`, or `--html`, each taking a file path:

```bash
xtool test --junit report.xml --json report.json
```

Capture additional failure diagnostics:

- `--screenshot-on-failure` -- captures a device screenshot for every failed test case
- `--capture-syslog` -- captures the device syslog for the duration of each run
- `--capture-crash-logs` -- collects any on-device crash logs written during the run

All three write into `--report-directory` (defaults to a timestamped directory in the current
directory).

## Running against multiple devices or repeatedly

```bash
xtool test --parallel        # run on every currently-connected device concurrently
xtool test --repeat 5        # run the whole session 5 times sequentially, aggregating results
```

## Other options

- `--triple` -- override the build target triple (defaults to the standard iOS device triple)
- `--session-timeout <seconds>` -- fail a run if no event arrives from the device for this long
  (default 120s). This guards against a stalled-but-still-connected session hanging forever; it's
  measured as an idle gap between events, not a cap on the whole run, so a long `--test-target`
  sweep isn't penalized for legitimately taking a while.

> Troubleshooting:
>
> A free Apple Developer account can only have a small number of apps installed on a device at
> once. If `xtool test` fails to install the Runner with a message about the maximum number of
> installed apps, uninstall one of the listed bundle IDs with `xtool uninstall <bundle-id>` and try
> again.
