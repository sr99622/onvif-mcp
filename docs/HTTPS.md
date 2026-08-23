# HTTPS Camera System Setup and Maintenance

## 0. Variables supplied by the agent

| Variable             | Description                         |
| -------------------- | ------------------------------------|
| {{SERVER_FQDN}}      | Server fully qualified domain name  |
| {{SERVER_IP}}        | Server IP address                   |
| {{SERVER_USER}}      | Server user account                 |
| {{REPO_PATH}}        | Project repository location         |
| {{CERT_PATH}}        | Certificates Path Location          |

## 1. Verify Certificate

Verify on `{{SERVER_FQDN}}`:

```bash
openssl verify \
  -CAfile {{CERT_PATH}}/camera-system-root-ca.crt.pem \
  -purpose sslserver \
  -verify_hostname {{SERVER_FQDN}} \
  {{CERT_PATH}}/{{SERVER_FQDN}}.crt.pem
```

Confirm the certificate matches the server key:

```bash
sudo sh -c '
openssl pkey -in /etc/nginx/tls/{{SERVER_FQDN}}.key.pem -pubout |
  openssl sha256
openssl x509 -in {{CERT_PATH}}/{{SERVER_FQDN}}.crt.pem -pubkey -noout |
  openssl sha256
'
```

The hashes must be identical.

Install the certificates:

```bash
sudo install -o root -g root -m 644 \
  {{CERT_PATH}}/{{SERVER_FQDN}}.crt.pem \
  /etc/nginx/tls/{{SERVER_FQDN}}.crt.pem

sudo install -o root -g root -m 644 \
  {{CERT_PATH}}/camera-system-root-ca.crt.pem \
  /etc/nginx/tls/camera-system-root-ca.crt.pem
```

The final TLS directory should have:

- Site key: root-owned, mode `600`
- CSR: root-owned, mode `644`
- Site certificate: root-owned, mode `644`
- Public CA certificate: root-owned, mode `644`

## 2. Configure Nginx HTTPS

Back up the site configuration first:

```bash
sudo cp --update=none \
  /etc/nginx/sites-available/camera-apps \
  /etc/nginx/sites-available/camera-apps.backup-2026-08-03
```

The tested HTTPS server block was:

```nginx
server {
    listen {{SERVER_IP}}:443 ssl;
    server_name {{SERVER_FQDN}};

    ssl_certificate     /etc/nginx/tls/{{SERVER_FQDN}}.crt.pem;
    ssl_certificate_key /etc/nginx/tls/{{SERVER_FQDN}}.key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:camera_tls:10m;
    ssl_session_timeout 1d;

    root {{REPO_PATH}}/apps;
    index index.html;

    location /cameras/ {
        try_files $uri $uri/ =404;
    }

    location /multiview/ {
        try_files $uri $uri/ =404;
    }

    location /outputs/ {
        try_files $uri $uri/ =404;
    }

    location /webrtc/ {
        proxy_pass http://127.0.0.1:8889/;
        proxy_redirect / /webrtc/;
    }
}
```

The explicit `{{SERVER_IP}}:443` listener avoids exposing HTTPS directly on the camera or Wi-Fi interfaces.

Add a hostname-specific port-80 redirect while retaining the Ubuntu default site:

```nginx
server {
    listen 80;
    server_name {{SERVER_FQDN}};

    return 301 https://{{SERVER_FQDN}}$request_uri;
}
```

Validate and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx.service
systemctl --no-pager --full status nginx.service
```

Confirm the listener:

```bash
sudo ss -lntp 'sport = :443'
```

Expected listener:

```text
{{SERVER_IP}}:443
```

## 3. Validate HTTPS from {{SERVER_FQDN}}

Because `{{SERVER_FQDN}}` was not yet using its own dnsmasq service for host resolution, the initial test used an explicit mapping and CA file:

```bash
sudo curl \
  --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  --head \
  https://{{SERVER_FQDN}}/cameras/
```

Expected:

```text
HTTP/1.1 200 OK
```


## 4. Verify MediaMTX behavior

Confirm its listener:

```bash
sudo ss -lntup 'sport = :8889'
```

MediaMTX listened on all addresses at `*:8889`.

A slashless player URL returned an absolute HTTP redirect:

```bash
curl --silent --output /dev/null \
  --write-out 'HTTP %{http_code}\nRedirect: %{redirect_url}\n' \
  http://127.0.0.1:8889/STREAM/PATH
```

A player URL ending in `/` returned `200 OK`. Its page used relative resources:

```text
./reader.js
whep
```

Therefore, the external proxied URLs were intentionally written with trailing slashes.

## 5. Proxy MediaMTX through Nginx

Add this inside the HTTPS server block:

```nginx
location /webrtc/ {
    proxy_pass http://127.0.0.1:8889/;
    proxy_redirect / /webrtc/;
}
```

The trailing slash on `proxy_pass` strips the external `/webrtc/` prefix before forwarding to MediaMTX. `proxy_redirect` adds it back to redirects.

Validate and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx.service
```

Test a player page through HTTPS:

```bash
sudo curl \
  --silent \
  --show-error \
  --output /dev/null \
  --write-out 'HTTP %{http_code}\nContent-Type: %{content_type}\n' \
  --resolve {{SERVER_FQDN}}:443:{{SERVER_IP}} \
  --cacert /etc/nginx/tls/camera-system-root-ca.crt.pem \
  https://{{SERVER_FQDN}}/webrtc/STREAM/PATH/
```

Expected:

```text
HTTP 200
Content-Type: text/html
```

## 6. Update the camera registry

Back it up:

```bash
sudo cp --update=none \
  {{REPO_PATH}}/apps/outputs/camera_registry.json \
  {{REPO_PATH}}/apps/outputs/camera_registry.json.backup-2026-08-03
```

Transform the direct-IP player URLs:

```bash
sudo perl -pi -e \
  's#http://\Q{{SERVER_IP}}\E:8889/([^\"]+)#https://{{SERVER_FQDN}}/webrtc/$1/#g' \
  {{REPO_PATH}}/apps/outputs/camera_registry.json
```

Validate JSON and inspect all transformed URLs:

```bash
python3 -m json.tool \
  {{REPO_PATH}}/apps/outputs/camera_registry.json \
  >/dev/null

rg -n 'player_url' \
  {{REPO_PATH}}/apps/outputs/camera_registry.json
```

Final URL pattern:

```text
https://{{SERVER_FQDN}}/webrtc/STREAM/PATH/
```

After a Firefox hard refresh with Command-Shift-R, all camera streams appeared.

## 7. Temporary files to clean up after final verification

The tested workflow created public transfer copies in `{{CERT_PATH}}` on `{{SERVER_FQDN}}`:

```text
{{CERT_PATH}}/{{SERVER_FQDN}}.csr.pem
{{CERT_PATH}}/{{SERVER_FQDN}}.crt.pem
{{CERT_PATH}}/camera-system-root-ca.crt.pem
```

These contain no private CA key, but should be removed after confirming their installed copies and backups. Use a recoverable deletion method where available.

The authoritative installed files remain under:

```text
/etc/nginx/tls
```

## Renewal procedure (NOT USED DURING INSTALLTION)

Before the 397-day site certificate expires:

1. Confirm the existing Nginx key remains secure and valid.
2. Generate a new CSR from it, or generate a new site key if rotating keys.
3. Transfer only the CSR to the CA workstation.
4. Review the SAN and extension file.
5. Sign through `openssl ca`.
6. Verify chain, purpose, hostname, and key match.
7. Create and verify a new encrypted CA archive.
8. Copy the archive to SMB and compare hashes.
9. Transfer and install the new public site certificate.
10. Run `nginx -t` and reload Nginx.
11. Verify the live certificate and streams.


## Useful operational commands

```bash
# Nginx
sudo nginx -t
systemctl --no-pager --full status nginx.service
sudo ss -lntp 'sport = :443'

# Certificate inspection
openssl x509 -in certificate.pem -noout -subject -issuer -dates -serial
openssl x509 -in certificate.pem -noout -text

# CA verification
openssl verify \
  -CAfile camera-system-root-ca.crt.pem \
  -purpose sslserver \
  -verify_hostname {{SERVER_FQDN}} \
  {{SERVER_FQDN}}.crt.pem

# HTTPS test
/usr/bin/curl --head https://{{SERVER_FQDN}}/cameras/

# MediaMTX signaling listener
sudo ss -lntup 'sport = :8889'
```

