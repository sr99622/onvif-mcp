
## 1. Generate the Nginx site key on trigkey

Verify OpenSSL:

```bash
openssl version -a
```

Create the TLS directory:

```bash
sudo install -d -o root -g root -m 700 /etc/nginx/tls
```

Generate a 3072-bit RSA server key:

```bash
sudo openssl genpkey \
  -algorithm RSA \
  -pkeyopt rsa_keygen_bits:3072 \
  -out /etc/nginx/tls/camera.home.arpa.key.pem
```

Verify mode, format, and integrity:

```bash
sudo ls -l /etc/nginx/tls/camera.home.arpa.key.pem
sudo sed -n '1p' /etc/nginx/tls/camera.home.arpa.key.pem
sudo openssl pkey \
  -in /etc/nginx/tls/camera.home.arpa.key.pem \
  -check -noout
```

Expected mode is `600`, owner `root`, with header:

```text
-----BEGIN PRIVATE KEY-----
```

## 2. Generate the CSR on trigkey

```bash
sudo openssl req \
  -new \
  -sha256 \
  -key /etc/nginx/tls/camera.home.arpa.key.pem \
  -out /etc/nginx/tls/camera.home.arpa.csr.pem \
  -subj "/CN=camera.home.arpa" \
  -addext "subjectAltName=DNS:camera.home.arpa" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth"
```

Verify the signature and requested extensions:

```bash
sudo openssl req \
  -in /etc/nginx/tls/camera.home.arpa.csr.pem \
  -noout -verify -subject

sudo openssl req \
  -in /etc/nginx/tls/camera.home.arpa.csr.pem \
  -noout -text |
sed -n '/Requested Extensions:/,/Signature Algorithm/p'
```

Required SAN:

```text
DNS:camera.home.arpa
```

## 3. Transfer only the CSR to the CA workstation

Because `/etc/nginx/tls` is mode `700`, create a temporary user-owned transfer copy:

```bash
sudo install \
  -o stephen \
  -g stephen \
  -m 600 \
  /etc/nginx/tls/camera.home.arpa.csr.pem \
  /home/stephen/camera.home.arpa.csr.pem
```
