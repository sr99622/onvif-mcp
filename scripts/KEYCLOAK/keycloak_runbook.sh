#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  keycloak_runbook.sh apply --server-fqdn HOST --backup-path PATH [--repo-path PATH] [--admin-user USER] [--realm REALM] [--scope SCOPE] [--login-user USER]
  keycloak_runbook.sh configure-hermes --server-fqdn HOST [--repo-path PATH] [--hermes-home PATH] [--mcp-name NAME]
  keycloak_runbook.sh login-hermes --server-fqdn HOST [--repo-path PATH] [--hermes-home PATH] [--mcp-name NAME]
  keycloak_runbook.sh status --server-fqdn HOST [--repo-path PATH] [--realm REALM]

Implements docs/KEYCLOAK.md executable install/configuration steps. Site-specific values are arguments.
Secrets are generated into root-owned files and are never printed.
USAGE
}

cmd="${1:-}"
[[ -n "$cmd" ]] || {
  usage
  exit 64
}
[[ "$cmd" == "-h" || "$cmd" == "--help" ]] && {
  usage
  exit 0
}
shift || true
server_fqdn=""
backup_path=""
repo_path="$HOME"
admin_user="keycloak-admin"
realm="mcp"
scope="mcp:tools"
login_user="mcp-user"
hermes_home="$HOME/.hermes"
mcp_name="camera"
while [[ $# -gt 0 ]]; do
  case "$1" in
  --server-fqdn)
    server_fqdn="${2:?missing --server-fqdn value}"
    shift 2
    ;;
  --backup-path)
    backup_path="${2:?missing --backup-path value}"
    shift 2
    ;;
  --repo-path)
    repo_path="${2:?missing --repo-path value}"
    shift 2
    ;;
  --admin-user)
    admin_user="${2:?missing --admin-user value}"
    shift 2
    ;;
  --realm)
    realm="${2:?missing --realm value}"
    shift 2
    ;;
  --scope)
    scope="${2:?missing --scope value}"
    shift 2
    ;;
  --login-user)
    login_user="${2:?missing --login-user value}"
    shift 2
    ;;
  --hermes-home)
    hermes_home="${2:?missing --hermes-home value}"
    shift 2
    ;;
  --mcp-name)
    mcp_name="${2:?missing --mcp-name value}"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    usage >&2
    exit 64
    ;;
  esac
done

require_arg() {
  local name="$1" value="$2"
  [[ -n "$value" ]] || {
    echo "Missing required argument: $name" >&2
    exit 64
  }
}
project_dir() { printf '%s/onvif-mcp' "${repo_path%/}"; }
public_url() { printf 'https://%s/auth' "$server_fqdn"; }
issuer() { printf 'https://%s/auth/realms/%s' "$server_fqdn" "$realm"; }
resource_url() { printf 'https://%s/mcp' "$server_fqdn"; }

kc_exec() { sudo docker compose --project-directory /opt/keycloak exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
ensure_kcadm() {
  sudo cat /opt/keycloak/admin.pass | sudo docker compose --project-directory /opt/keycloak exec -i keycloak sh -c 'IFS= read -r admin_password; /opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm.config --server http://127.0.0.1:8080/auth --realm master --user "$1" --password "$admin_password"' sh "$admin_user"
}
wait_keycloak() {
  local url="http://127.0.0.1:8080/auth/realms/master/.well-known/openid-configuration" code=""
  for _ in $(seq 1 60); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" || true)"
    [[ "$code" == "200" ]] && {
      echo "keycloak-ready HTTP 200"
      return 0
    }
    sleep 3
  done
  echo "Keycloak did not become ready; last HTTP $code" >&2
  exit 1
}
install_packages() {
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2 python3 curl ca-certificates postgresql-client-common
  sudo systemctl enable --now docker
  sudo docker version --format 'Docker server {{.Server.Version}}'
  sudo docker compose version
}

write_compose() {
  sudo install -d -m 750 -o root -g root /opt/keycloak
  if ! sudo test -s /opt/keycloak/.env; then
    sudo sh -c 'umask 077; printf "POSTGRES_PASSWORD=%s\n" "$(openssl rand -hex 32)" > /opt/keycloak/.env'
  fi
  if ! sudo test -s /opt/keycloak/admin.pass; then
    sudo sh -c 'umask 077; printf "%s" "$(openssl rand -hex 32)" > /opt/keycloak/admin.pass'
  fi
  sudo tee /opt/keycloak/compose.yaml >/dev/null <<EOF
services:
  postgres:
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
    volumes:
      - keycloak_postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keycloak -d keycloak"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s

  keycloak:
    image: quay.io/keycloak/keycloak:26.7.0
    restart: unless-stopped
    command: start
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: \${POSTGRES_PASSWORD}
      KC_HTTP_ENABLED: "true"
      KC_HTTP_RELATIVE_PATH: /auth
      KC_HOSTNAME: https://$server_fqdn/auth
      KC_PROXY_HEADERS: xforwarded
      KC_HEALTH_ENABLED: "true"
    ports:
      - "127.0.0.1:8080:8080"

volumes:
  keycloak_postgres_data:
EOF
  sudo chmod 640 /opt/keycloak/compose.yaml
  sudo docker compose --project-directory /opt/keycloak config --quiet
  sudo stat -c '%A %U %G %n' /opt/keycloak /opt/keycloak/.env /opt/keycloak/admin.pass /opt/keycloak/compose.yaml
}

bootstrap_admin() {
  if sudo cat /opt/keycloak/admin.pass | sudo docker compose --project-directory /opt/keycloak exec -i keycloak sh -c 'IFS= read -r admin_password; /opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm.config --server http://127.0.0.1:8080/auth --realm master --user "$1" --password "$admin_password"' sh "$admin_user" >/dev/null 2>&1; then
    sudo sed -i '/^KC_BOOTSTRAP_ADMIN_USERNAME=/d; /^KC_BOOTSTRAP_ADMIN_PASSWORD=/d' /opt/keycloak/.env
    sudo sed -i '/^[[:space:]]*KC_BOOTSTRAP_ADMIN_USERNAME:/d; /^[[:space:]]*KC_BOOTSTRAP_ADMIN_PASSWORD:/d' /opt/keycloak/compose.yaml
    sudo docker compose --project-directory /opt/keycloak config --quiet
    echo "permanent-admin-login-ok"
    return 0
  fi
  if ! sudo grep -q '^KC_BOOTSTRAP_ADMIN_USERNAME=' /opt/keycloak/.env; then
    sudo sh -c 'umask 077; printf "KC_BOOTSTRAP_ADMIN_USERNAME=admin\nKC_BOOTSTRAP_ADMIN_PASSWORD=%s\n" "$(openssl rand -hex 32)" >> /opt/keycloak/.env'
  fi
  sudo python3 - <<'PY'
from pathlib import Path
p=Path('/opt/keycloak/compose.yaml')
s=p.read_text()
needle='      KC_HEALTH_ENABLED: "true"\n'
block='      KC_BOOTSTRAP_ADMIN_USERNAME: ${KC_BOOTSTRAP_ADMIN_USERNAME}\n      KC_BOOTSTRAP_ADMIN_PASSWORD: ${KC_BOOTSTRAP_ADMIN_PASSWORD}\n'
if block not in s:
    s=s.replace(needle, needle+block)
p.write_text(s)
PY
  sudo docker compose --project-directory /opt/keycloak config --quiet
  sudo docker compose --project-directory /opt/keycloak pull
  sudo docker compose --project-directory /opt/keycloak up -d
  sudo docker compose --project-directory /opt/keycloak ps
  wait_keycloak
  sudo docker compose --project-directory /opt/keycloak exec keycloak sh -c '/opt/keycloak/bin/kcadm.sh config credentials --config /tmp/kcadm.config --server http://127.0.0.1:8080/auth --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"'
  if ! kc_exec get users --config /tmp/kcadm.config -r master -q exact=true -q username="$admin_user" --fields username | grep -F "$admin_user" >/dev/null; then
    kc_exec create users --config /tmp/kcadm.config -r master -s username="$admin_user" -s enabled=true
  fi
  sudo cat /opt/keycloak/admin.pass | sudo docker compose --project-directory /opt/keycloak exec -i keycloak sh -c 'IFS= read -r new_password; /opt/keycloak/bin/kcadm.sh set-password --config /tmp/kcadm.config -r master --username "$1" --new-password "$new_password"' sh "$admin_user"
  kc_exec add-roles --config /tmp/kcadm.config -r master --uusername "$admin_user" --rolename admin || true
  ensure_kcadm
  bootstrap_id="$(kc_exec get users --config /tmp/kcadm.config -r master -q exact=true -q username=admin --fields id,username | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"
  if [[ -n "$bootstrap_id" ]]; then kc_exec delete "users/$bootstrap_id" --config /tmp/kcadm.config -r master; fi
  sudo sed -i '/^KC_BOOTSTRAP_ADMIN_USERNAME=/d; /^KC_BOOTSTRAP_ADMIN_PASSWORD=/d' /opt/keycloak/.env
  sudo sed -i '/^[[:space:]]*KC_BOOTSTRAP_ADMIN_USERNAME:/d; /^[[:space:]]*KC_BOOTSTRAP_ADMIN_PASSWORD:/d' /opt/keycloak/compose.yaml
  sudo docker compose --project-directory /opt/keycloak config --quiet
  sudo sh -c 'if grep -q "^KC_BOOTSTRAP_ADMIN_" /opt/keycloak/.env || grep -q "KC_BOOTSTRAP_ADMIN_" /opt/keycloak/compose.yaml; then exit 1; fi'
  sudo docker compose --project-directory /opt/keycloak up -d --force-recreate keycloak
  wait_keycloak
  ensure_kcadm
}

configure_realm() {
  ensure_kcadm
  if ! kc_exec get realms --config /tmp/kcadm.config --fields realm | grep -F '"'"$realm"'"' >/dev/null; then
    kc_exec create realms --config /tmp/kcadm.config -s realm="$realm" -s enabled=true
  fi
  kc_exec update "realms/$realm" --config /tmp/kcadm.config -s ssoSessionIdleTimeout=28800 -s ssoSessionMaxLifespan=604800 -s clientSessionIdleTimeout=0 -s clientSessionMaxLifespan=0 -s accessTokenLifespan=300 -s revokeRefreshToken=true -s refreshTokenMaxReuse=0
  if ! kc_exec get users --config /tmp/kcadm.config -r "$realm" -q exact=true -q username="$login_user" --fields username | grep -F "$login_user" >/dev/null; then
    kc_exec create users --config /tmp/kcadm.config -r "$realm" -s username="$login_user" -s email="${login_user}@example.com" -s firstName=Sample -s lastName=User -s emailVerified=true -s enabled=true
  fi
  if ! sudo test -s "/opt/keycloak/$login_user.pass"; then
    sudo sh -c "umask 077; printf '%s' \"\$(openssl rand -hex 32)\" > '/opt/keycloak/$login_user.pass'"
  fi
  sudo cat "/opt/keycloak/$login_user.pass" | sudo docker compose --project-directory /opt/keycloak exec -i keycloak sh -c 'IFS= read -r user_password; /opt/keycloak/bin/kcadm.sh set-password --config /tmp/kcadm.config -r "$1" --username "$2" --new-password "$user_password"' sh "$realm" "$login_user"

  scope_id="$(kc_exec get client-scopes --config /tmp/kcadm.config -r "$realm" --fields id,name | python3 -c 'import json,sys; name=sys.argv[1]; d=json.load(sys.stdin); print(next((x["id"] for x in d if x.get("name")==name), ""))' "$scope")"
  if [[ -z "$scope_id" ]]; then
    kc_exec create client-scopes --config /tmp/kcadm.config -r "$realm" -s "name=$scope" -s protocol=openid-connect -s 'attributes={"display.on.consent.screen":"true","include.in.token.scope":"true","include.in.openid.provider.metadata":"true"}'
    scope_id="$(kc_exec get client-scopes --config /tmp/kcadm.config -r "$realm" --fields id,name | python3 -c 'import json,sys; name=sys.argv[1]; d=json.load(sys.stdin); print(next((x["id"] for x in d if x.get("name")==name), ""))' "$scope")"
  else
    kc_exec update "client-scopes/$scope_id" --config /tmp/kcadm.config -r "$realm" -s 'attributes={"display.on.consent.screen":"true","include.in.token.scope":"true","include.in.openid.provider.metadata":"true"}'
  fi
  if ! kc_exec get "client-scopes/$scope_id/protocol-mappers/models" --config /tmp/kcadm.config -r "$realm" | grep -F 'mcp-server-audience' >/dev/null; then
    kc_exec create "client-scopes/$scope_id/protocol-mappers/models" --config /tmp/kcadm.config -r "$realm" -s name=mcp-server-audience -s protocol=openid-connect -s protocolMapper=oidc-audience-mapper -s consentRequired=false -s "config={\"included.custom.audience\":\"$(resource_url)\",\"access.token.claim\":\"true\",\"id.token.claim\":\"false\",\"introspection.token.claim\":\"true\"}"
  fi

  policies_json="$(kc_exec get components --config /tmp/kcadm.config -r "$realm" -q type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy --fields id,name,providerId,subType,config)"
  allowed_id="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(next((x["id"] for x in d if x.get("subType")=="anonymous" and x.get("providerId")=="allowed-client-templates"), ""))' "$policies_json")"
  trusted_id="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(next((x["id"] for x in d if x.get("subType")=="anonymous" and x.get("providerId")=="trusted-hosts"), ""))' "$policies_json")"
  max_id="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(next((x["id"] for x in d if x.get("subType")=="anonymous" and x.get("providerId")=="max-clients"), ""))' "$policies_json")"
  [[ -n "$allowed_id" && -n "$trusted_id" && -n "$max_id" ]] || {
    echo "Required anonymous DCR policy IDs not found" >&2
    exit 1
  }
  if ! kc_exec update "components/$allowed_id" --config /tmp/kcadm.config -r "$realm" -s "config={\"allowed-client-scopes\":[\"$scope\"],\"allow-default-scopes\":[\"true\"]}"; then
    echo "kcadm rejected allowed-client-scopes; applying equivalent component_config rows directly" >&2
    sudo docker compose --project-directory /opt/keycloak exec -i postgres psql --username=keycloak --dbname=keycloak --set=ON_ERROR_STOP=1 --command="DELETE FROM component_config WHERE component_id='$allowed_id' AND name IN ('allowed-client-scopes','allow-default-scopes'); INSERT INTO component_config (id, component_id, name, value) VALUES (md5(random()::text || clock_timestamp()::text), '$allowed_id', 'allowed-client-scopes', '$scope'), (md5(random()::text || clock_timestamp()::text), '$allowed_id', 'allow-default-scopes', 'true');"
    sudo docker compose --project-directory /opt/keycloak up -d --force-recreate keycloak
    wait_keycloak
    ensure_kcadm
  fi
  compose_gateway_ip="$(sudo docker network inspect keycloak_default --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}')"
  server_lan_ip="$(hostname -I | awk '{print $1}')"
  kc_exec update "components/$trusted_id" --config /tmp/kcadm.config -r "$realm" -s "config={\"trusted-hosts\":[\"localhost\",\"127.0.0.1\",\"$compose_gateway_ip\",\"$server_lan_ip\"],\"host-sending-registration-request-must-match\":[\"true\"],\"client-uris-must-match\":[\"true\"]}"
  kc_exec update "components/$max_id" --config /tmp/kcadm.config -r "$realm" -s 'config={"max-clients":["20"]}'
}

configure_nginx() {
  local site=""
  local effective
  effective="$(mktemp "${TMPDIR:-/tmp}/nginx-effective.XXXXXX")"
  sudo nginx -T >"$effective" 2>/dev/null
  site="$(
    python3 - "$server_fqdn" "$effective" <<'PY'
import re, sys
fqdn=sys.argv[1]
path=sys.argv[2]
cur=''
for line in open(path):
    m=re.match(r'# configuration file: (.*):$', line.strip())
    if m: cur=m.group(1)
    if f'server_name {fqdn}' in line and cur and '/conf.d/' in cur:
        print(cur); break
PY
  )"
  rm -f "$effective"
  [[ -n "$site" ]] || site="/etc/nginx/conf.d/$server_fqdn.conf"
  sudo test -s "$site"
  sudo install -d -m 750 -o root -g root /etc/nginx/backups
  sudo cp --update=none "$site" "/etc/nginx/backups/$(basename "$site").pre-keycloak" || true
  sudo chmod 640 "/etc/nginx/backups/$(basename "$site").pre-keycloak" || true
  sudo python3 - "$site" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
block='''
    location = /auth {
        return 301 /auth/;
    }

    location /auth/ {
        proxy_pass http://127.0.0.1:8080/auth/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location = /.well-known/oauth-protected-resource/mcp {
        proxy_pass http://127.0.0.1:8001;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
'''
if 'location /auth/' not in s:
    idx=s.rfind('\n}')
    if idx < 0: raise SystemExit('could not find server block closing brace')
    s=s[:idx]+block+s[idx:]
s=s.replace('return 301 http://$host/mcp;', 'return 301 https://$host/mcp;')
p.write_text(s)
PY
  sudo nginx -t
  sudo systemctl reload nginx
  systemctl is-active nginx
}

trust_ca_and_verify_public() {
  sudo test -s /etc/nginx/tls/camera-system-root-ca.crt.pem
  sudo openssl x509 -in /etc/nginx/tls/camera-system-root-ca.crt.pem -noout -subject -issuer -ext basicConstraints | grep -F 'CA:TRUE' >/dev/null
  sudo install -m 644 /etc/nginx/tls/camera-system-root-ca.crt.pem /usr/local/share/ca-certificates/camera-system-root-ca.crt
  sudo update-ca-certificates
  curl -sS -o /dev/null -w 'auth: HTTP %{http_code}\n' "$(public_url)/"
  curl -sS -o /dev/null -w 'discovery: HTTP %{http_code}\n' "$(issuer)/.well-known/openid-configuration" | grep -F 'HTTP 200'
  curl -sS "$(issuer)/.well-known/openid-configuration" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("issuer:",d.get("issuer")); print("registration_endpoint:",d.get("registration_endpoint")); print("S256:", "S256" in d.get("code_challenge_methods_supported", [])); print("scope:", "mcp:tools" in d.get("scopes_supported", []))'
}

configure_mcp_oauth() {
  sudo install -d -m 755 /etc/systemd/system/onvif-mcp-http.service.d
  sudo tee /etc/systemd/system/onvif-mcp-http.service.d/oauth.conf >/dev/null <<EOF
[Service]
Environment=MCP_OAUTH_ENABLED=true
Environment=MCP_OAUTH_ISSUER=$(issuer)
Environment=MCP_RESOURCE_URL=$(resource_url)
Environment=MCP_OAUTH_JWKS_URL=http://127.0.0.1:8080/auth/realms/$realm/protocol/openid-connect/certs
EOF
  sudo chmod 644 /etc/systemd/system/onvif-mcp-http.service.d/oauth.conf
  sudo systemd-analyze verify onvif-mcp-http.service
  sudo systemctl daemon-reload
  sudo systemctl restart onvif-mcp-http.service
  systemctl is-active onvif-mcp-http.service
  for _ in $(seq 1 20); do
    curl -sS -D - -o /dev/null "$(resource_url)" | tee /tmp/keycloak-mcp-unauth.headers
    if grep -E '^HTTP/.* 401' /tmp/keycloak-mcp-unauth.headers >/dev/null; then break; fi
    sleep 1
  done
  grep -E '^HTTP/.* 401' /tmp/keycloak-mcp-unauth.headers
  curl -sS "https://$server_fqdn/.well-known/oauth-protected-resource/mcp" | python3 -m json.tool
}

test_dcr() {
  umask 077
  curl -sS -o /tmp/keycloak-dcr-test.json -w 'HTTP %{http_code}\n' -H 'Content-Type: application/json' -d "{\"client_name\":\"temporary-dcr-verification\",\"application_type\":\"native\",\"redirect_uris\":[\"http://127.0.0.1:8765/callback\"],\"grant_types\":[\"authorization_code\",\"refresh_token\"],\"response_types\":[\"code\"],\"token_endpoint_auth_method\":\"none\",\"scope\":\"$scope\"}" "$(issuer)/clients-registrations/openid-connect" | grep -F 'HTTP 201'
  python3 - <<'PY'
import json
p='/tmp/keycloak-dcr-test.json'
d=json.load(open(p))
print('client_id:', d.get('client_id'))
print('scope:', d.get('scope'))
print('error:', d.get('error'))
print('error_description:', d.get('error_description'))
print(d.get('client_id') or '', file=open('/tmp/keycloak-dcr-client-id','w'))
PY
  dcr_client_id="$(cat /tmp/keycloak-dcr-client-id)"
  internal_id="$(kc_exec get clients --config /tmp/kcadm.config -r "$realm" -q "clientId=$dcr_client_id" --fields id,clientId,name | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d and d[0].get("name")=="temporary-dcr-verification" else "")')"
  [[ -n "$internal_id" ]] || {
    echo "temporary DCR client not found by safe name check" >&2
    exit 1
  }
  kc_exec delete "clients/$internal_id" --config /tmp/kcadm.config -r "$realm"
  rm -f /tmp/keycloak-dcr-test.json /tmp/keycloak-dcr-client-id
  test ! -e /tmp/keycloak-dcr-test.json
}

install_backup_service() {
  sudo install -d -m 700 -o root -g root /var/backups/keycloak-postgres
  sudo install -o root -g root -m 750 "$(project_dir)/scripts/backup-keycloak-postgres.sh" /usr/local/sbin/backup-keycloak-postgres.sh
  sudo bash -n /usr/local/sbin/backup-keycloak-postgres.sh
  sudo tee /etc/systemd/system/keycloak-postgres-backup.service >/dev/null <<'EOF'
[Unit]
Description=Back up the Keycloak PostgreSQL database
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
User=root
Group=root
UMask=0077
Nice=10
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/backup-keycloak-postgres.sh
EOF
  sudo chmod 644 /etc/systemd/system/keycloak-postgres-backup.service
  sudo systemctl daemon-reload
  sudo systemd-analyze verify keycloak-postgres-backup.service
  sudo systemctl start keycloak-postgres-backup.service
  sudo systemctl show keycloak-postgres-backup.service -p Result -p ExecMainStatus
  sudo find /var/backups/keycloak-postgres -maxdepth 1 -type f -name 'keycloak-*.dump' -printf '%M %u %g %s bytes %f\n'
  backup_file="$(sudo find /var/backups/keycloak-postgres -maxdepth 1 -type f -name 'keycloak-*.dump' -printf '%f\n' | sort | tail -n 1)"
  sudo sh -c "docker compose --project-directory /opt/keycloak exec -i postgres pg_restore --list < '/var/backups/keycloak-postgres/$backup_file' >/dev/null"
}

restore_test() {
  local restore_db="keycloak_restore_test_$(date -u +%Y%m%d%H%M%S)"
  if sudo docker compose --project-directory /opt/keycloak exec -i postgres psql --username=keycloak --dbname=postgres --tuples-only --no-align --command="SELECT datname FROM pg_database WHERE datname = '$restore_db';" | grep -Fx "$restore_db" >/dev/null; then
    echo "restore db already exists" >&2
    exit 1
  fi
  sudo docker compose --project-directory /opt/keycloak exec -i postgres createdb --username=keycloak "$restore_db"
  backup_file="$(sudo find /var/backups/keycloak-postgres -maxdepth 1 -type f -name 'keycloak-*.dump' -printf '%f\n' | sort | tail -n 1)"
  sudo sh -c "docker compose --project-directory /opt/keycloak exec -i postgres pg_restore --username=keycloak --dbname='$restore_db' --exit-on-error < '/var/backups/keycloak-postgres/$backup_file'"
  sudo docker compose --project-directory /opt/keycloak exec -i postgres psql --username=keycloak --dbname="$restore_db" --tuples-only --no-align --command="SELECT 'realms=' || count(*) FROM realm UNION ALL SELECT 'users=' || count(*) FROM user_entity UNION ALL SELECT 'clients=' || count(*) FROM client;" | tee /tmp/keycloak-restore-counts.txt
  awk -F= '{if ($2+0 <= 0) exit 1}' /tmp/keycloak-restore-counts.txt
  sudo docker compose --project-directory /opt/keycloak exec -i postgres dropdb --username=keycloak "$restore_db"
}

configure_hermes() {
  require_arg --server-fqdn "$server_fqdn"
  require_arg --repo-path "$repo_path"
  mkdir -p "$hermes_home"
  python3 - "$hermes_home/config.yaml" "$mcp_name" "$(resource_url)" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); name=sys.argv[2]; url=sys.argv[3]
s=p.read_text() if p.exists() else ''
if 'mcp:' not in s:
    s += '\nmcp:\n  auto_reload_on_config_change: false\n'
elif 'auto_reload_on_config_change:' not in s:
    s=s.replace('mcp:\n', 'mcp:\n  auto_reload_on_config_change: false\n', 1)
block=f'''  {name}:
    url: {url}
    auth: oauth
    ssl_verify: /etc/ssl/certs/camera-system-root-ca.pem
    connect_timeout: 600
    enabled: false
'''
if 'mcp_servers:' not in s:
    s += '\nmcp_servers:\n' + block
else:
    lines=s.splitlines(True); out=[]; i=0
    while i < len(lines):
        if lines[i].startswith('  '+name+':'):
            out.append(block); i += 1
            while i < len(lines) and (lines[i].startswith('    ') or lines[i].strip()==''):
                i += 1
            continue
        out.append(lines[i]); i += 1
    s=''.join(out)
    if f'  {name}:' not in s:
        s += '\n' + block
p.write_text(s)
PY
  echo "configure-hermes-ok config=$hermes_home/config.yaml entry=$mcp_name enabled=false"
  echo "Run: scripts/KEYCLOAK/keycloak_runbook.sh login-hermes --server-fqdn $server_fqdn --repo-path $repo_path --hermes-home $hermes_home --mcp-name $mcp_name"
}

set_hermes_entry_enabled() {
  local target_home="$1" enabled_value="$2"
  python3 - "$target_home/config.yaml" "$mcp_name" "$enabled_value" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); name = sys.argv[2]; enabled = sys.argv[3]
lines = p.read_text().splitlines(True)
out = []
i = 0
changed = False
while i < len(lines):
    out.append(lines[i])
    if lines[i].startswith('  ' + name + ':'):
        i += 1
        while i < len(lines) and (lines[i].startswith('    ') or lines[i].strip() == ''):
            if lines[i].lstrip().startswith('enabled:'):
                out.append('    enabled: ' + enabled + '\n')
                changed = True
            else:
                out.append(lines[i])
            i += 1
        if not changed:
            out.append('    enabled: ' + enabled + '\n')
        continue
    i += 1
p.write_text(''.join(out))
PY
}

headless_hermes_login() {
  require_arg --server-fqdn "$server_fqdn"
  require_arg --repo-path "$repo_path"
  local real_home="${HOME}/.hermes" isolated_home login_log auth_url login_pid token_dir
  isolated_home="${hermes_home%/}-login"
  login_log="$(mktemp)"
  trap "rm -f '$login_log'" RETURN

  rm -rf "$isolated_home"
  configure_hermes >/dev/null
  hermes_home="$isolated_home" configure_hermes >/dev/null
  ln -s "$real_home/tools" "$isolated_home/tools"
  set_hermes_entry_enabled "$isolated_home" true

  BROWSER=/bin/false HERMES_HOME="$isolated_home" hermes mcp login "$mcp_name" >"$login_log" 2>&1 &
  login_pid=$!

  for _ in $(seq 1 600); do
    if ! kill -0 "$login_pid" 2>/dev/null; then
      wait "$login_pid" || {
        sed -n '1,200p' "$login_log" >&2
        exit 1
      }
      break
    fi
    auth_url="$(
      python3 - "$login_log" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
m = re.search(r'https://[^\s]+/auth/realms/[^\s]+/protocol/openid-connect/auth\?[^\s]+', text)
print(m.group(0) if m else '')
PY
    )"
    if [[ -n "$auth_url" ]]; then
      python3 "$(project_dir)/scripts/kc-headless-login-driver.py" "$auth_url"
      wait "$login_pid" || {
        sed -n '1,240p' "$login_log" >&2
        exit 1
      }
      break
    fi
    sleep 1
  done
  if kill -0 "$login_pid" 2>/dev/null; then
    kill "$login_pid" 2>/dev/null || true
    sed -n '1,240p' "$login_log" >&2
    echo "Timed out waiting for Hermes OAuth authorization URL" >&2
    exit 1
  fi

  token_dir="$isolated_home/mcp-tokens"
  test -s "$token_dir/$mcp_name.json"
  test -s "$token_dir/$mcp_name.client.json"
  test -s "$token_dir/$mcp_name.meta.json"
  install -d -m 700 "$real_home/mcp-tokens"
  install -m 600 "$token_dir/$mcp_name.json" "$real_home/mcp-tokens/$mcp_name.json"
  install -m 600 "$token_dir/$mcp_name.client.json" "$real_home/mcp-tokens/$mcp_name.client.json"
  install -m 600 "$token_dir/$mcp_name.meta.json" "$real_home/mcp-tokens/$mcp_name.meta.json"
  set_hermes_entry_enabled "$real_home" true
  HERMES_HOME="$real_home" hermes mcp test "$mcp_name"
  echo "login-hermes-ok entry=$mcp_name tokens=$real_home/mcp-tokens"
}

apply() {
  require_arg --server-fqdn "$server_fqdn"
  require_arg --backup-path "$backup_path"
  require_arg --repo-path "$repo_path"
  hostname --fqdn
  getent ahostsv4 "$server_fqdn"
  install_packages
  write_compose
  bootstrap_admin
  configure_realm
  configure_nginx
  trust_ca_and_verify_public
  configure_mcp_oauth
  test_dcr
  configure_hermes
  headless_hermes_login
  install_backup_service
  restore_test
  echo "apply-ok keycloak $(issuer)"
}

status() {
  require_arg --server-fqdn "$server_fqdn"
  echo "== services =="
  systemctl is-active docker nginx onvif-mcp-http.service 2>/dev/null || true
  sudo docker compose --project-directory /opt/keycloak ps 2>/dev/null || true
  echo "== endpoints =="
  curl -sS -o /dev/null -w 'discovery: HTTP %{http_code}\n' "$(issuer)/.well-known/openid-configuration" || true
  curl -sS -D - -o /dev/null "$(resource_url)" | sed -n '1,8p' || true
  echo "== backups =="
  sudo find /var/backups/keycloak-postgres -maxdepth 1 -type f -name 'keycloak-*.dump' -printf '%M %u %g %s %p\n' 2>/dev/null | sort || true
}

case "$cmd" in
apply) apply ;;
configure-hermes) configure_hermes ;;
login-hermes) headless_hermes_login ;;
status) status ;;
*)
  echo "Unknown command: $cmd" >&2
  usage >&2
  exit 64
  ;;
esac
