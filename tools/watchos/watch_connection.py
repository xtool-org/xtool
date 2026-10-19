import asyncio
from pathlib import Path
from pymobiledevice3.lockdown import PlistUsbmuxLockdownClient, create_using_usbmux
from pymobiledevice3.service_connection import ServiceConnection
from pymobiledevice3.services.companion import CompanionProxyService


class CompanionWatchLockdownClient(PlistUsbmuxLockdownClient):
    def __init__(self, *args, phone, proxy, ports, **kwargs):
        super().__init__(*args, **kwargs)
        self.phone = phone
        self.proxy = proxy
        self.ports = ports

    async def create_service_connection(self, remote_port):
        local_port = await asyncio.wait_for(self.proxy.start_forwarding_service_port(remote_port), 8)
        if local_port is None:
            raise RuntimeError("Cannot forward requested Watch service.")
        self.ports.add(remote_port)
        return await asyncio.wait_for(ServiceConnection.create_using_usbmux(self.phone.udid, local_port), 8)


class WatchConnection:
    """Route a trusted Watch's lockdown services through its paired USB iPhone."""

    def __init__(self, directory: Path, pair_watch=False):
        self.directory = directory
        self.pair_watch = pair_watch
        self.phone = None
        self.watch = None
        self.proxy = None
        self.initial_service = None
        self.ports = set()

    async def __aenter__(self):
        try:
            self.phone = await asyncio.wait_for(create_using_usbmux(autopair=False, connection_type="USB"), 8)
            self.proxy = CompanionProxyService(self.phone)
            registry = await asyncio.wait_for(self.proxy.list(), 8)
            if len(registry) != 1:
                raise RuntimeError("Expected exactly one paired Watch; no device selected.")
            port = await asyncio.wait_for(self.proxy.start_forwarding_service_port(62078), 8)
            if port is None:
                raise RuntimeError("Cannot forward Watch lockdown service.")
            self.ports.add(62078)
            cache = self.directory / "watch-pairing"
            service = await asyncio.wait_for(ServiceConnection.create_using_usbmux(self.phone.udid, port), 8)
            self.initial_service = service
            self.watch = await asyncio.wait_for(CompanionWatchLockdownClient.create(
                service, identifier=registry[0], port=62078, autopair=False,
                pairing_records_cache_folder=cache, system_buid=self.phone.system_buid,
                phone=self.phone, proxy=self.proxy, ports=self.ports
            ), 15)
            if not self.watch.paired and self.pair_watch:
                print("Unlock the Watch and accept its Trust prompt.", flush=True)
                await asyncio.wait_for(self.watch.pair(timeout=30), 35)
            if not self.watch.paired:
                raise RuntimeError("The Watch must first trust this PC.")
            if self.watch.all_values.get("DeviceClass") != "Watch":
                raise RuntimeError("Connection did not reach an Apple Watch.")

            return self.watch
        except BaseException:
            await self.__aexit__(None, None, None)
            raise

    async def __aexit__(self, *_):
        try:
            if self.watch is not None:
                await asyncio.wait_for(self.watch.close(), 5)
            elif self.initial_service is not None:
                await asyncio.wait_for(self.initial_service.close(), 5)
        finally:
            try:
                if self.proxy is not None:
                    for port in sorted(self.ports, reverse=True):
                        try:
                            await asyncio.wait_for(self.proxy.stop_forwarding_service_port(port), 5)
                        except Exception:
                            pass
                    await asyncio.wait_for(self.proxy.close(), 5)
            finally:
                if self.phone is not None:
                    await asyncio.wait_for(self.phone.close(), 5)
