from __future__ import annotations

import asyncio
import os
import sys
import json
from datetime import datetime
import logging
from pathlib import Path
import uvicorn
from importlib.metadata import version as get_installed_version
from starlette.middleware.cors import CORSMiddleware
#from starlette.requests import Request
#from starlette.responses import StreamingResponse
#from starlette.types import ASGIApp, Receive, Scope, Send
from pydantic import AnyHttpUrl, BaseModel
from mcp.server.fastmcp import FastMCP, Context
from mcp.server.auth.settings import AuthSettings
#from mcp.server.elicitation import AcceptedElicitation, DeclinedElicitation, CancelledElicitation
from mcp.server.transport_security import TransportSecuritySettings
from onvif_mcp_http.auth import JWTVerifier
from onvif_mcp_core.camera_queries import get_adapters as get_adapters_query
from onvif_mcp_core.guidance import TOOL_GUIDANCE
from onvif_mcp_core.tools import (
    register_audio_configuration_tools,
    register_camera_query_tools,
    register_device_management_tools,
    register_ptz_tools,
    register_streaming_tools,
    register_video_configuration_tools,
)

LOG_FILE = Path(__file__).parent / "camera_events.log"

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.WARNING,
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
)
logger = logging.getLogger(__name__)
logger.setLevel(logging.DEBUG)

MCP_OAUTH_ENABLED = os.environ.get("MCP_OAUTH_ENABLED", "").lower() in {
    "1",
    "true",
    "yes",
}
MCP_OAUTH_ISSUER = os.environ.get(
    "MCP_OAUTH_ISSUER",
    "https://gmktec.home.arpa/auth/realms/mcp",
)
MCP_RESOURCE_URL = os.environ.get(
    "MCP_RESOURCE_URL",
    "https://gmktec.home.arpa/mcp",
)
MCP_OAUTH_JWKS_URL = os.environ.get(
    "MCP_OAUTH_JWKS_URL",
    "http://127.0.0.1:8080/auth/realms/mcp/protocol/openid-connect/certs",
)
SERVER_FQDN = os.environ.get(
    "SERVER_FQDN"
)
oauth_settings = (
    AuthSettings(
        issuer_url=AnyHttpUrl(MCP_OAUTH_ISSUER),
        resource_server_url=AnyHttpUrl(MCP_RESOURCE_URL),
        required_scopes=["mcp:tools"],
    )
    if MCP_OAUTH_ENABLED
    else None
)
oauth_token_verifier = (
    JWTVerifier(
        issuer=MCP_OAUTH_ISSUER,
        audience=MCP_RESOURCE_URL,
        jwks_url=MCP_OAUTH_JWKS_URL,
    )
    if MCP_OAUTH_ENABLED
    else None
)

mcp = FastMCP(
    "camera-mcp",
    auth=oauth_settings,
    token_verifier=oauth_token_verifier,
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=[
            "127.0.0.1:*", 
            "localhost:*", 
            "[::1]:*",
            SERVER_FQDN,
        ],
        allowed_origins=[
            "http://127.0.0.1:*",
            "http://localhost:*",
            "http://[::1]:*",
            f"http://{SERVER_FQDN}",
        ],
    ),
)
register_video_configuration_tools(mcp)
register_audio_configuration_tools(mcp)
register_ptz_tools(mcp)
register_device_management_tools(mcp)
register_camera_query_tools(mcp)
register_streaming_tools(mcp)

@mcp.tool(description=TOOL_GUIDANCE["get_adapters"])
async def get_adapters() -> str:
    """Return a list of available active network adapters.

    Returns:
        A delimited string containing the IP address of each active adapter,
        one per line, separated by "\n--\n".
    """
    return await get_adapters_query()

class TripTypeResponse(BaseModel):
    value: str

@mcp.tool()
async def get_camera_mcp_version() -> str:
    """
    Get the version of the camera application, along with the version of the
    installed libonvif package it depends on.

    Returns:
        A JSON string with two fields:
            camera_mcp_version: version derived from the pyproject.toml file.
            libonvif_version: version of the installed libonvif package,
                               read via importlib.metadata.
    """

    camera_mcp_version = None
    current_file = Path(__file__)
    filename = Path(current_file.parent.parent.parent) / "pyproject.toml"
    with open(filename, "r") as f:
        for line in f:
            if line.startswith("version"):
                camera_mcp_version = line.split("=")[1].strip().strip('"')
                logger.debug(f"Found camera_mcp version: {camera_mcp_version}")
                break

    try:
        libonvif_version = get_installed_version("libonvif")
    except Exception as e:
        logger.error(f"Failed to get libonvif version: {e}")
        libonvif_version = None

    return json.dumps({
        "camera_mcp_version": camera_mcp_version,
        "libonvif_version": libonvif_version,
    }, indent=4)

class PrivateNetworkAccessMiddleware:
    """
    Adds the Access-Control-Allow-Private-Network header some Chromium
    browsers require (in addition to normal CORS) before allowing a page
    served from a non-loopback origin to fetch a loopback address like
    127.0.0.1. Without this, the browser can reject the request before
    it ever reaches this server, showing up client-side as a generic
    "Failed to fetch" with no server-side log at all.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def send_wrapper(message):
            if message["type"] == "http.response.start":
                headers = message.setdefault("headers", [])
                headers.append((b"access-control-allow-private-network", b"true"))
            await send(message)

        await self.app(scope, receive, send_wrapper)

def main():
    app = mcp.streamable_http_app()
    app.add_middleware(PrivateNetworkAccessMiddleware)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
        # The streamable-http transport returns a session ID in a custom
        # response header on the initialize call, and expects it echoed
        # back on every subsequent request. Browsers hide custom response
        # headers from JS by default unless the server explicitly exposes
        # them via CORS - without this, the client never sees the session
        # ID and every follow-up request gets rejected as missing one.
        expose_headers=["mcp-session-id"],
    )
    # Bind only to loopback; Nginx provides HTTPS and authentication.
    # Internal endpoint: http://127.0.0.1:8001/mcp
    host = os.environ.get("MCP_HTTP_HOST", "127.0.0.1")
    port = int(os.environ.get("MCP_HTTP_PORT", "8001"))
    uvicorn.run(app, host=host, port=port)

if __name__ == "__main__":
    main()
