"""OAuth access-token verification for the Camera MCP resource server."""

from __future__ import annotations

import asyncio
from typing import Any

import jwt
from mcp.server.auth.provider import AccessToken


class JWTVerifier:
    """Validate RFC 9068 JWT access tokens against its JWKS."""

    def __init__(
        self,
        *,
        issuer: str,
        audience: str,
        jwks_url: str,
    ) -> None:
        self.issuer = issuer
        self.audience = audience
        self._jwk_client = jwt.PyJWKClient(
            jwks_url,
            cache_keys=True,
            cache_jwk_set=True,
            lifespan=300,
            timeout=5,
        )

    async def verify_token(self, token: str) -> AccessToken | None:
        try:
            signing_key = await asyncio.to_thread(
                self._jwk_client.get_signing_key_from_jwt,
                token,
            )
            claims: dict[str, Any] = jwt.decode(
                token,
                signing_key.key,
                algorithms=["RS256"],
                issuer=self.issuer,
                audience=self.audience,
                leeway=30,
                options={
                    "require": ["exp", "iat", "iss", "sub"],
                },
            )
        except (jwt.PyJWTError, OSError, ValueError):
            return None

        client_id = claims.get("client_id") or claims.get("azp")
        subject = claims.get("sub")
        expires_at = claims.get("exp")

        if not isinstance(client_id, str) or not client_id:
            return None
        if not isinstance(subject, str) or not subject:
            return None
        if not isinstance(expires_at, int):
            return None

        scopes = self._extract_scopes(claims)

        return AccessToken(
            token=token,
            client_id=client_id,
            scopes=scopes,
            expires_at=expires_at,
            resource=self.audience,
            subject=subject,
            claims=claims,
        )

    @staticmethod
    def _extract_scopes(claims: dict[str, Any]) -> list[str]:
        scope = claims.get("scope")
        if isinstance(scope, str):
            return scope.split()

        scopes = claims.get("scp")
        if isinstance(scopes, list) and all(
            isinstance(value, str) for value in scopes
        ):
            return scopes

        return []
