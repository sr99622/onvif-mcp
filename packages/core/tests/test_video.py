from types import SimpleNamespace
from unittest import IsolatedAsyncioTestCase
from unittest.mock import patch

from onvif_mcp_core.video import (
    set_camera_video_bitrate,
    set_camera_video_frame_rate,
    set_camera_video_gov_length,
    set_camera_video_resolution,
)


class VideoConfigurationTests(IsolatedAsyncioTestCase):
    def make_camera(self):
        encoder = SimpleNamespace(
            resolution="640 x 480",
            gov_length=30,
            rate_control=SimpleNamespace(
                frame_rate_limit=15,
                bitrate_limit=1024,
            ),
        )
        profile = SimpleNamespace(token="main", video_encoder=encoder)
        camera = SimpleNamespace(
            xaddr="http://10.0.0.10/onvif/device_service",
            profiles=[profile],
            errors=None,
        )
        return camera, encoder

    async def test_each_setting_updates_and_pushes_the_profile_encoder(self):
        cases = [
            (
                set_camera_video_resolution,
                "1920 x 1080",
                lambda encoder: encoder.resolution,
            ),
            (
                set_camera_video_frame_rate,
                30,
                lambda encoder: encoder.rate_control.frame_rate_limit,
            ),
            (
                set_camera_video_bitrate,
                4096,
                lambda encoder: encoder.rate_control.bitrate_limit,
            ),
            (
                set_camera_video_gov_length,
                60,
                lambda encoder: encoder.gov_length,
            ),
        ]

        for operation, value, read_value in cases:
            with self.subTest(operation=operation.__name__):
                camera, encoder = self.make_camera()
                with (
                    patch(
                        "onvif_mcp_core.video.get_camera_by_ip",
                        return_value=camera,
                    ),
                    patch(
                        "onvif_mcp_core.video.set_video_encoder_configuration"
                    ) as push_configuration,
                ):
                    result = await operation("10.0.0.10", "main", value)

                self.assertEqual(value, read_value(encoder))
                push_configuration.assert_called_once_with(camera, encoder)
                self.assertTrue(result.startswith("Successfully set"))

    async def test_unknown_profile_does_not_push_configuration(self):
        camera, _ = self.make_camera()
        with (
            patch(
                "onvif_mcp_core.video.get_camera_by_ip",
                return_value=camera,
            ),
            patch(
                "onvif_mcp_core.video.set_video_encoder_configuration"
            ) as push_configuration,
        ):
            result = await set_camera_video_bitrate(
                "10.0.0.10",
                "missing",
                4096,
            )

        push_configuration.assert_not_called()
        self.assertIn("Profile missing not found", result)

    async def test_query_failure_is_returned_as_a_tool_message(self):
        with patch(
            "onvif_mcp_core.video.get_camera_by_ip",
            side_effect=RuntimeError("offline"),
        ):
            result = await set_camera_video_resolution(
                "10.0.0.10",
                "main",
                "1920 x 1080",
            )

        self.assertEqual(
            "Failed to query camera at 10.0.0.10: offline",
            result,
        )
