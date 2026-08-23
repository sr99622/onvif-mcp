## 0. Variables supplied by agent

{{SERVER_FQDN}} - Server Fully Qualified Domain Name

{{SERVER_USER}} - $USER account name for agent

{{CSR_PATH}} - Path Location to store the CSR


## 1. Generate the Nginx site key on {{SERVER_FQDN}}

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
  -out /etc/nginx/tls/{{SERVER_FQDN}}.key.pem
```

Verify mode, format, and integrity:

```bash
sudo ls -l /etc/nginx/tls/{{SERVER_FQDN}}.key.pem
sudo sed -n '1p' /etc/nginx/tls/{{SERVER_FQDN}}.key.pem
sudo openssl pkey \
  -in /etc/nginx/tls/{{SERVER_FQDN}}.key.pem \
  -check -noout
```

Expected mode is `600`, owner `root`, with header:

```text
-----BEGIN PRIVATE KEY-----
```

## 2. Generate the CSR on {{SERVER_FQDN}}

```bash
sudo openssl req \
  -new \
  -sha256 \
  -key /etc/nginx/tls/{{SERVER_FQDN}}.key.pem \
  -out /etc/nginx/tls/{{SERVER_FQDN}}.csr.pem \
  -subj "/CN={{SERVER_FQDN}}" \
  -addext "subjectAltName=DNS:{{SERVER_FQDN}}" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth"
```

Verify the signature and requested extensions:

```bash
sudo openssl req \
  -in /etc/nginx/tls/{{SERVER_FQDN}}.csr.pem \
  -noout -verify -subject

sudo openssl req \
  -in /etc/nginx/tls/{{SERVER_FQDN}}.csr.pem \
  -noout -text |
sed -n '/Requested Extensions:/,/Signature Algorithm/p'
```

Required SAN:

```text
DNS:{{SERVER_FQDN}}
```

## 3. Create a Tranferrable Copy of the CSR

Because `/etc/nginx/tls` is mode `700`, create a temporary user-owned transfer copy:

```bash
sudo install \
  -o {{SERVER_USER}} \
  -g {{SERVER_USER}} \
  -m 600 \
  /etc/nginx/tls/{{SERVER_FQDN}}.csr.pem \
  {{CSR_PATH}}/{{SERVER_FQDN}}.csr.pem
```
