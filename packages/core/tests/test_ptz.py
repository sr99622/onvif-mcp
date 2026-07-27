from types import SimpleNamespace
from unittest import IsolatedAsyncioTestCase
from unittest.mock import patch

from onvif_mcp_core.ptz import (
    MISSING_PTZ_XADDR,
    goto_camera_preset,
    pan_tilt_camera,
    set_camera_preset_tour,
    stop_camera_zoom,
    zoom_camera,
)


class PtzTests(IsolatedAsyncioTestCase):
    async def test_direct_commands_require_a_ptz_address(self):
        self.assertEqual(
            MISSING_PTZ_XADDR,
            await goto_camera_preset("", "main", "1", 0),
        )
        self.assertEqual(
            MISSING_PTZ_XADDR,
            await pan_tilt_camera("", "main", 0, 0.5, 0.5),
        )
        self.assertEqual(
            MISSING_PTZ_XADDR,
            await stop_camera_zoom("", "main", 0),
        )

    async def test_zero_zoom_is_rejected_without_sending_a_command(self):
        with patch("onvif_mcp_core.ptz.continuous_move") as move:
            result = await zoom_camera("http://camera/ptz", "main", 0, 0)
        move.assert_not_called()
        self.assertIn("z must not be 0.0", result)

    async def test_pan_tilt_builds_a_minimal_camera_and_sends_velocity(self):
        with patch("onvif_mcp_core.ptz.continuous_move") as move:
            result = await pan_tilt_camera(
                "http://camera/ptz",
                "main",
                -3,
                0.25,
                -0.5,
            )

        camera = move.call_args.args[0]
        self.assertEqual("http://camera/ptz", camera.capabilities.ptz.xaddr)
        self.assertEqual(-3, camera.time_offset)
        move.assert_called_once_with(camera, "main", 0.25, -0.5, 0)
        self.assertTrue(result.startswith("Successfully started"))

    async def test_tour_update_replaces_spots(self):
        tour = SimpleNamespace(
            token="tour-1",
            name="Old",
            auto_start=False,
            spots=[],
        )
        camera = SimpleNamespace(
            xaddr="http://camera/device",
            ptz=SimpleNamespace(tours=[tour]),
            errors=None,
        )
        spots = [{"preset_token": "1", "stay_time": "PT5S"}]
        with (
            patch("onvif_mcp_core.ptz._query_camera", return_value=camera),
            patch("onvif_mcp_core.ptz.modify_preset_tour") as modify,
        ):
            result = await set_camera_preset_tour(
                "10.0.0.10",
                "main",
                "tour-1",
                tour_name="New",
                auto_start=True,
                spots=spots,
            )

        self.assertEqual("New", tour.name)
        self.assertTrue(tour.auto_start)
        self.assertEqual("1", tour.spots[0].preset_token)
        self.assertEqual("PT5S", tour.spots[0].stay_time)
        modify.assert_called_once_with(camera, "main", tour)
        self.assertTrue(result.startswith("Successfully updated"))
