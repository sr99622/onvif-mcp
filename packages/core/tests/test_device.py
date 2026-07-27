from types import SimpleNamespace
from unittest import IsolatedAsyncioTestCase
from unittest.mock import patch, sentinel

from onvif_mcp_core.device import (
    change_camera_hostname,
    reboot_camera,
    sync_camera_time,
)


class DeviceManagementTests(IsolatedAsyncioTestCase):
    def make_camera(self):
        return SimpleNamespace(
            xaddr="http://10.0.0.10/onvif/device_service",
            hostname=SimpleNamespace(name="Old"),
            time_offset=15,
            errors=None,
        )

    async def test_change_hostname_updates_and_pushes_camera(self):
        camera = self.make_camera()
        with (
            patch("onvif_mcp_core.device._query_camera", return_value=camera),
            patch("onvif_mcp_core.device.set_hostname") as set_hostname,
        ):
            result = await change_camera_hostname("10.0.0.10", "New")

        self.assertEqual("New", camera.hostname.name)
        set_hostname.assert_called_once_with(camera)
        self.assertTrue(result.startswith("Successfully changed hostname"))

    async def test_sync_time_sets_clock_then_refreshes_offset(self):
        camera = self.make_camera()

        def refresh_offset(camera_arg):
            camera_arg.time_offset = -2

        with (
            patch("onvif_mcp_core.device._query_camera", return_value=camera),
            patch(
                "onvif_mcp_core.device.get_local_date_and_time",
                return_value=sentinel.local_time,
            ),
            patch(
                "onvif_mcp_core.device.set_system_date_and_time"
            ) as set_time,
            patch(
                "onvif_mcp_core.device.get_time_offset",
                side_effect=refresh_offset,
            ) as get_offset,
        ):
            result = await sync_camera_time("10.0.0.10")

        set_time.assert_called_once_with(camera, sentinel.local_time)
        get_offset.assert_called_once_with(camera)
        self.assertIn("time_offset is now -2 seconds", result)

    async def test_reboot_sends_system_reboot_request(self):
        camera = self.make_camera()
        with (
            patch("onvif_mcp_core.device._query_camera", return_value=camera),
            patch("onvif_mcp_core.device.reboot") as reboot,
        ):
            result = await reboot_camera("10.0.0.10")

        reboot.assert_called_once_with(camera)
        self.assertTrue(result.startswith("Successfully requested reboot"))

    async def test_query_failure_is_returned_without_device_action(self):
        with (
            patch(
                "onvif_mcp_core.device._query_camera",
                side_effect=RuntimeError("offline"),
            ),
            patch("onvif_mcp_core.device.reboot") as reboot,
        ):
            result = await reboot_camera("10.0.0.10")

        reboot.assert_not_called()
        self.assertEqual(
            "Failed to query camera at 10.0.0.10: offline",
            result,
        )
