from types import SimpleNamespace
from unittest import IsolatedAsyncioTestCase
from unittest.mock import patch

from onvif_mcp_core.audio import (
    set_camera_audio_encoding,
    set_camera_audio_sample_rate,
)


class AudioConfigurationTests(IsolatedAsyncioTestCase):
    def make_camera(self):
        encoder = SimpleNamespace(encoding="AAC", sample_rate=8)
        profile = SimpleNamespace(token="main", audio_encoder=encoder)
        camera = SimpleNamespace(
            xaddr="http://10.0.0.10/onvif/device_service",
            profiles=[profile],
            errors=None,
        )
        return camera, encoder

    async def test_each_setting_updates_and_pushes_the_profile_encoder(self):
        cases = [
            (
                set_camera_audio_encoding,
                "G711",
                lambda encoder: encoder.encoding,
            ),
            (
                set_camera_audio_sample_rate,
                16,
                lambda encoder: encoder.sample_rate,
            ),
        ]

        for operation, value, read_value in cases:
            with self.subTest(operation=operation.__name__):
                camera, encoder = self.make_camera()
                with (
                    patch(
                        "onvif_mcp_core.audio.get_camera_by_ip",
                        return_value=camera,
                    ),
                    patch(
                        "onvif_mcp_core.audio.set_audio_encoder_configuration"
                    ) as push_configuration,
                ):
                    result = await operation("10.0.0.10", "main", value)

                self.assertEqual(value, read_value(encoder))
                push_configuration.assert_called_once_with(camera, encoder)
                self.assertTrue(result.startswith("Successfully set"))

    async def test_camera_errors_are_reported(self):
        camera, _ = self.make_camera()

        def push_with_error(camera_arg, _encoder):
            camera_arg.errors = ["configuration rejected"]

        with (
            patch(
                "onvif_mcp_core.audio.get_camera_by_ip",
                return_value=camera,
            ),
            patch(
                "onvif_mcp_core.audio.set_audio_encoder_configuration",
                side_effect=push_with_error,
            ),
        ):
            result = await set_camera_audio_encoding(
                "10.0.0.10",
                "main",
                "G711",
            )

        self.assertIn("Camera returned errors", result)

    async def test_unknown_profile_does_not_push_configuration(self):
        camera, _ = self.make_camera()
        with (
            patch(
                "onvif_mcp_core.audio.get_camera_by_ip",
                return_value=camera,
            ),
            patch(
                "onvif_mcp_core.audio.set_audio_encoder_configuration"
            ) as push_configuration,
        ):
            result = await set_camera_audio_sample_rate(
                "10.0.0.10",
                "missing",
                16,
            )

        push_configuration.assert_not_called()
        self.assertIn("Profile missing not found", result)
