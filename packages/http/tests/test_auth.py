from __future__ import annotations

import time
from types import SimpleNamespace
from unittest import IsolatedAsyncioTestCase

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

from onvif_mcp_http.auth import JWTVerifier


ISSUER = "https://gmktec.home.arpa/auth/realms/mcp"
AUDIENCE = "https://gmktec.home.arpa/mcp"


class StaticJWKClient:
    def __init__(self, public_key) -> None:
        self.public_key = public_key

    def get_signing_key_from_jwt(self, token: str):
        return SimpleNamespace(key=self.public_key)


class JWTVerifierTests(IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.private_key = rsa.generate_private_key(
            public_exponent=65537,
            key_size=2048,
        )
        cls.public_key = cls.private_key.public_key()

    def make_verifier(self) -> AutheliaJWTVerifier:
        verifier = JWTVerifier(
            issuer=ISSUER,
            audience=AUDIENCE,
            jwks_url="http://127.0.0.1:8080/auth/realms/mcp/protocol/openid-connect/certs",
        )
        verifier._jwk_client = StaticJWKClient(self.public_key)
        return verifier

    def make_token(self, **overrides) -> str:
        now = int(time.time())
        claims = {
            "iss": ISSUER,
            "aud": AUDIENCE,
            "sub": "stephen",
            "client_id": "agent-camera-mcp",
            "iat": now,
            "exp": now + 300,
            "scope": "mcp:tools",
        }
        claims.update(overrides)
        return jwt.encode(claims, self.private_key, algorithm="RS256")

    async def test_valid_token_returns_access_token(self):
        result = await self.make_verifier().verify_token(self.make_token())

        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual("agent-camera-mcp", result.client_id)
        self.assertEqual("stephen", result.subject)
        self.assertEqual(["mcp:tools"], result.scopes)
        self.assertEqual(AUDIENCE, result.resource)
        self.assertEqual(ISSUER, result.claims["iss"])

    async def test_wrong_audience_is_rejected(self):
        token = self.make_token(aud="https://camera.home.arpa/other")

        result = await self.make_verifier().verify_token(token)

        self.assertIsNone(result)

    async def test_expired_token_is_rejected(self):
        now = int(time.time())
        token = self.make_token(iat=now - 600, exp=now - 300)

        result = await self.make_verifier().verify_token(token)

        self.assertIsNone(result)
