import asyncio
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import AsyncMock, patch
from zipfile import ZipFile

from watch_connection import WatchConnection
from watch_device import package_info


class PackageValidationTests(unittest.TestCase):
    def test_rejects_iphone_package(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Phone.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleSupportedPlatforms": ["iPhoneOS"]}))
            with self.assertRaises(ValueError):
                package_info(app)

    def test_rejects_ambiguous_ipa_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "ambiguous.ipa"
            with ZipFile(ipa, "w") as archive:
                for name in ["First", "Second"]:
                    archive.writestr(f"Payload/{name}.app/Info.plist", plistlib.dumps({}))
            with self.assertRaises(ValueError):
                package_info(ipa)


class ConnectionCleanupTests(unittest.IsolatedAsyncioTestCase):
    async def test_cleanup_continues_when_watch_close_fails(self):
        connection = WatchConnection(Path("unused"))
        connection.watch = AsyncMock()
        connection.watch.close.side_effect = ConnectionError("disconnected")
        connection.proxy = AsyncMock()
        connection.phone = AsyncMock()
        connection.ports = {62078, 1234}
        with self.assertRaises(ConnectionError):
            await connection.__aexit__()
        self.assertEqual(connection.proxy.stop_forwarding_service_port.await_count, 2)
        connection.proxy.close.assert_awaited_once()
        connection.phone.close.assert_awaited_once()

    async def test_multiple_watches_do_not_forward_any_ports(self):
        phone = AsyncMock()
        proxy = AsyncMock()
        proxy.list.return_value = ["first", "second"]
        with patch("watch_connection.create_using_usbmux", AsyncMock(return_value=phone)), \
                patch("watch_connection.CompanionProxyService", return_value=proxy):
            with self.assertRaisesRegex(RuntimeError, "exactly one"):
                async with WatchConnection(Path("unused")):
                    self.fail("Ambiguous Watch selection must not connect")
        proxy.start_forwarding_service_port.assert_not_awaited()
        proxy.close.assert_awaited_once()
        phone.close.assert_awaited_once()


if __name__ == "__main__":
    unittest.main()
