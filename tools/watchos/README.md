# Experimental Watch deployment helper

This is a Python prototype for hardware validation, separate from `xtool dev run`.
It routes Watch lockdown services through a trusted USB iPhone's companion proxy
and installs signed apps using `com.apple.streaming_zip_conduit`. Watch AFC upload
is unavailable on the tested device.

Validated on Windows with Python 3.12, pymobiledevice3 11.31.0, an iPhone on
iOS 27.0.1 and an Ultra 2 on watchOS 27.0.1. Other hardware, Linux USB deployment,
and initial trust on other OS versions need testing. The helper requires exactly
one Watch in the phone's companion registry and refuses ambiguous selection.

## Prepare the device

Install Apple's USB device software on Windows and ensure Apple Mobile Device
Service is running. Connect the paired iPhone by USB, unlock it, and accept Trust.
Keep the Watch unlocked and nearby. From the repository root in PowerShell:

```powershell
py -3.12 -m venv .watchos/venv
.watchos/venv/Scripts/python.exe -m pip install -r tools/watchos/requirements.txt
.watchos/venv/Scripts/python.exe tools/watchos/watch_device.py --pair --device-info .watchos/device.json
```

Accept the separate Trust prompt on the Watch. If it takes longer than 30 seconds,
rerun the command. The JSON contains the Watch UDID and name for `dev sign-watch`.
The command creates this file exclusively; it refuses to overwrite an existing
file. Omit `--device-info` on subsequent connection checks.

If Developer Mode is missing from Watch Settings:

```powershell
.watchos/venv/Scripts/python.exe tools/watchos/watch_device.py --reveal-developer-mode
```

On the Watch, enable Settings > Privacy & Security > Developer Mode, restart,
and confirm the post-restart prompt. The helper only reveals the switch; it never
enables Developer Mode, reboots, or accepts the confirmation automatically.
Reconnect after the restart and check that `developer_mode` is `true`.

`.watchos/` is ignored by Git and stores private pairing keys and device info.
Do not commit, publish, or copy this directory into a source archive. For another
cache location, pass `--state-directory PATH`; its `watch-pairing` subdirectory is
used for Watch pairing records. The iPhone's existing pairing record is preserved.

## Build, sign, and install

Use the modified xtool and a legally obtained Apple Watch SDK. See the
[watchOS guide](../../Documentation/xtool.docc/WatchOS.md) for SDK setup.
For the tested Ultra 2, build with `--triple arm64-apple-watchos`; arm64_32 was
rejected by its current OS. Sign a device build with `xtool dev sign-watch` using
the JSON created above. Authenticate with `xtool auth` in the same host environment
used for signing. WSL sees Windows paths under `/mnt/c/`.

Once signed, install the `.app` directly from Windows, for example:

```powershell
.watchos/venv/Scripts/python.exe tools/watchos/watch_device.py --install Examples/WatchProbe/xtool/WatchProbe.app
```

A signed `.ipa` with a single `Payload/*.app` is accepted too. The helper streams
the archive, waits for installation completion, checks the bundle ID in the Watch
app registry, and closes forwarded ports. Open the installed app manually on the
Watch. Installation verification alone does not prove that the executable launches.

## Troubleshooting

- Keep both devices unlocked, nearby, and connected throughout installation.
- If trust or Developer Mode changes require a restart, reconnect before retrying.
- `APIInternalError` about CPU architecture: rebuild for a supported Watch triple.
- `WatchOnlyAndRunsIndependentlyNotAllowed`: do not combine `WKWatchOnly` with
  `WKRunsIndependentlyOfCompanionApp` for a standalone Watch app.
- Provisioning errors: confirm the profile includes the Watch UDID, matches the
  bundle ID, and has not expired. Free-account profiles need renewal after seven days.
- Network errors in the probe: keep the app foregrounded during the request.
  Error -1001 is a timeout, not proof that the Watch has no internet. The tested
  example.com request timed out while Apple's small HTTPS page returned HTTP 200.

Exceptions omit full tracebacks to avoid exposing pairing data or device identifiers.
Installer error descriptions may include device-local staging paths. New-device
trust, Developer Mode, certificate limits, and free-account app limits are still
enforced by Apple. This prototype has no automatic launch or debug-session support.

## Helper tests

With the Python environment above, run:

```powershell
.watchos/venv/Scripts/python.exe -m unittest discover -s tools/watchos -v
```

These check rejection of iPhone packages and ambiguous IPA payloads, refusal to
select between multiple Watches, and cleanup after a Watch disconnect.
They do not replace hardware testing of trust, provisioning, installation, and launch.
