"""Experimental companion-proxy deployment, separate from xtool dev run."""

import argparse
import asyncio
import json
from pathlib import Path
import plistlib
from zipfile import ZipFile

from pymobiledevice3.services.installation_proxy import InstallationProxyService
from pymobiledevice3.services.streaming_zip_conduit import StreamingZipConduitService
from watch_connection import WatchConnection


def package_info(package: Path):
    if package.is_dir() and package.suffix == ".app":
        info = plistlib.loads((package / "Info.plist").read_bytes())
    else:
        with ZipFile(package) as archive:
            candidates = [name for name in archive.namelist()
                          if name.startswith("Payload/") and name.count("/") == 2
                          and name.endswith("/Info.plist")]
            if len(candidates) != 1:
                raise ValueError("Expected a single Watch app payload.")
            info = plistlib.loads(archive.read(candidates[0]))
    if info.get("WKApplication") is not True or info.get("CFBundleSupportedPlatforms") != ["WatchOS"]:
        raise ValueError("Expected a watchOS device app.")
    return info


async def main(args):
    info = package_info(args.install) if args.install else None
    async with WatchConnection(args.state_directory, pair_watch=args.pair) as watch:
        enabled = await watch.get_developer_mode_status()
        print(json.dumps({"watch_connected": True, "developer_mode": enabled}), flush=True)
        if args.device_info:
            # Exclusive creation avoids silently replacing an unrelated target file.
            with args.device_info.open("x", encoding="utf-8") as destination:
                json.dump({"udid": watch.all_values["UniqueDeviceID"],
                           "name": watch.all_values.get("DeviceName", "Apple Watch")}, destination)
            print("Saved private Watch device info.", flush=True)
        if args.reveal_developer_mode:
            service = await watch.start_lockdown_service("com.apple.amfi.lockdown")
            try:
                response = await service.send_recv_plist({"action": 0})
                if not response.get("success"):
                    raise RuntimeError("Watch did not expose the Developer Mode setting.")
            finally:
                await service.close()
            print("Enable Developer Mode in Watch Settings, restart, and confirm on the Watch.", flush=True)
        if info is None:
            return
        if not enabled:
            raise RuntimeError("Enable and confirm Developer Mode on the Watch before installing.")
        async with StreamingZipConduitService(watch) as conduit:
            await conduit.install(args.install, developer=True,
                                  handler=lambda value: print(f"Install: {value}%", flush=True))
        async with InstallationProxyService(watch) as installer:
            result = await installer.service.send_recv_plist({
                "Command": "Lookup", "ClientOptions": {"BundleIDs": [info["CFBundleIdentifier"]]}
            })
            if info["CFBundleIdentifier"] not in result.get("LookupResult", {}):
                raise RuntimeError("Installer completed, but Watch app lookup failed.")
        print("Installed and verified in the Watch app registry. Open the app on the Watch.", flush=True)


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-directory", type=Path, default=Path(".watchos"),
                        help="Private directory for the watch-pairing cache (default: .watchos)")
    parser.add_argument("--pair", action="store_true", help="Request Watch trust if not already paired")
    parser.add_argument("--device-info", type=Path, help="Create private JSON for xtool dev sign-watch")
    parser.add_argument("--reveal-developer-mode", action="store_true",
                        help="Show the Developer Mode switch; does not enable or confirm it")
    parser.add_argument("--install", type=Path, help="Install a signed Watch .app or .ipa")
    args = parser.parse_args()
    args.state_directory.mkdir(parents=True, exist_ok=True)
    try:
        asyncio.run(asyncio.wait_for(main(args), 120))
    except Exception as error:
        # Avoid printing pairing records or device identifiers in tracebacks.
        if isinstance(error, (ValueError, RuntimeError)):
            print(str(error), flush=True)
        elif type(error).__name__ in {"AppInstallError", "StreamingZipConduitError"}:
            print(str(error), flush=True)
        print(f"Deployment stopped: {type(error).__name__}", flush=True)
        raise SystemExit(1) from None


if __name__ == "__main__":
    run()
