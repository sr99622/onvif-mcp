# Nginx Integration

MediaMTX is accessed through Nginx at `/webrtc/` with these key settings:

- **Proxy target:** `http://127.0.0.1:8889/` (MediaMTX WebRTC listener)
- **Protocol rewrite:** `proxy_redirect / /webrtc/` so relative URLs get the correct path prefix
- **WebSocket upgrade:** Required for WebRTC data channels and ICE candidates
- **Auth protection:** `/webrtc/` is protected by oauth2-proxy (Keycloak) via Nginx `auth_request`

The proxy also forwards `X-Forwarded-*` headers so MediaMTX can log the real client IP.
