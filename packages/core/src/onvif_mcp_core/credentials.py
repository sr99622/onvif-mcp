"""Shared camera credential access for both MCP transports."""

import os
from dataclasses import dataclass, field


@dataclass(frozen=True)
class CameraCredentials:
    """Camera login values; omit the password from diagnostic representations."""

    username: str
    password: str = field(repr=False)


def get_camera_credentials() -> CameraCredentials:
    """Read the current environment, preserving empty defaults and whitespace.

    Credential acquisition is centralized here so callers do not depend on the
    source. Values are not cached; this preserves the existing lookup behavior.
    """
    return CameraCredentials(
        username=os.environ.get("CAMERA_USERNAME", ""),
        password=os.environ.get("CAMERA_PASSWORD", ""),
    )
