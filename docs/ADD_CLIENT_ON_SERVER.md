# Permit a New DCR Client on the Server (Trusted Hosts)

## Purpose

Server-side configuration for keycloak client access. It adds one new Hermes
client's source address to the anonymous Dynamic Client Registration (DCR)
Trusted Hosts policy in Keycloak, so that machine can register its own public
OAuth client.

This document is written for a single server where Nginx fronts both the MCP
server and Keycloak, and where Keycloak runs locally (native install or
compose project). All calls are made from the server host against the
loopback Keycloak listener; nothing here touches the network-facing stack.

Runbook values used by this document:

| Symbol | Meaning | Typical value in this deployment |
|---|---|---|
| `{{MCP_REALM}}` | Keycloak realm hosting the MCP client-registration policy | `mcp` |
| `{{KEYCLOAK_ADMIN_USER}}` | Permanent administrator user in the `master` realm | `keycloak-admin` |
| `{{KEYCLOAK_PORT}}` | Loopback TCP port of the Keycloak listener | `8080` |
| `{{KEYCLOAK_PATH}}` | Keycloak relative path on loopback (`KC_HTTP_RELATIVE_PATH`) | `/auth` |
| `{{CLIENT_SOURCE_IP}}` | Address supplied by agent representing the client IP | e.g. `192.168.68.51` |

The admin password lives in a root-owned, mode `0600` file
(`/opt/keycloak/admin.pass` in this deployment). Create the token body and
token stash with a restrictive umask so the credential never appears on a
command line, in an environment variable, or in an untrusted location.

Token lifetime rule (hard): Keycloak access tokens here carry a 60-second
lifespan (`exp - iat = 60`, the container default when no token lifespan is
configured), and there is no keepalive or renewal. Any Admin REST call that
presents an expired token returns `401` with a JSON error body; a step that
captures such a body into a file can mistake it for a normal response.
Therefore every mutating step in this runbook is self-contained: it mints its
own token at the top of its own bounded command, performs all of its Admin
REST calls inside that same command, verifies its own result inside it, and
cleans up before the command exits. No step may depend on a token or a file
minted by a previous step. If any verification fails or an unexpected response
is seen, re-run the entire step with a fresh mint; do not retry individual
calls with an old credential.

## Security rules

- Never print the admin password, the access token, or DCR registration
  artifacts to chat, logs, or shell history (avoid `set -x`).
- Keep every temporary file for secrets at mode `0600` and remove all of
  them at the end, including after a failed run.
- Add exactly one address per client. Do not widen the policy to a subnet
  unless the installed Keycloak provider is confirmed to accept CIDR syntax;
  do not disable Trusted Hosts to simplify onboarding.
- Change only the anonymous `trusted-hosts` component of the MCP realm.
  Never copy a component UUID from another installation, another realm, or a
  previous deployment — always resolve it live as in Steps 2 and 3 below.

## 1. Confirm the server identity and the client source address

Confirm this is the machine that fronts the realm, and confirm Keycloak is
listening on loopback:

```bash
hostname -I
ss -ltnp | grep ':8080\b' || true
curl -sS -o /dev/null -w 'Health: HTTP %{http_code}\n' \
  http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/realms/master/.well-known/openid-configuration
```

Expected result: `HTTP 200`. If Keycloak is not up, start it before
continuing; do not attempt DCR policy changes against a dead or restarting
server.

`{{CLIENT_SOURCE_IP}}` is supplied by the agent. If there is ambiguity around 
this value, please refer to section 3 of the ADD_CLIENT.md document for details.

```bash
sudo grep 'clients-registrations/openid-connect' \
  /var/log/nginx/access.log | tail -n 5
```

If no entry exists yet, the client has not attempted registration; the
policy change is harmless but cannot be confirmed against traffic.

## 2. Resolve the live anonymous Trusted Hosts component (preflight)

Mint a token and resolve the component in one bounded command. This step is a
confirmation only; Step 3 resolves the component live again immediately before
the write, so no state is carried between steps:

```bash
umask 077
pass="$(sudo cat /opt/keycloak/admin.pass)" || exit 1
body=$(mktemp /tmp/.kctmp.XXXXXX)
printf 'grant_type=password&client_id=admin-cli&username={{KEYCLOAK_ADMIN_USER}}&password=%s' "$pass" > "$body"
tok=$(curl -sS -X POST --data @"$body" \
  http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/realms/master/protocol/openid-connect/token \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])') || { rm -f "$body"; unset pass; exit 1; }
rm -f "$body"; unset pass
[ -n "$tok" ] || exit 1

tfile=$(mktemp /tmp/.kctok.XXXXXX); chmod 600 "$tfile"
printf '%s' "$tok" > "$tfile"; unset tok

curl -sS -H "Authorization: Bearer $(cat "$tfile")" \
  'http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/admin/realms/{{MCP_REALM}}/components?subType=anonymous' > /tmp/kc-components.json

python3 - <<'EOF'
import json, sys
data = json.load(open('/tmp/kc-components.json'))
matches = [c for c in data if c.get('providerId') == 'trusted-hosts' and c.get('subType') == 'anonymous']
print("exact matches:", len(matches))
for m in matches:
    print("id:", m['id'], "| name:", m.get('name'))
assert len(matches) == 1, "stop: zero or multiple components; the realm was modified by hand or the wrong realm is in use"
EOF
rc=$?

rm -f "$tfile" /tmp/kc-components.json
[ $rc -eq 0 ]
```

Select the component whose:

```text
providerType = org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy
providerId   = trusted-hosts
subType      = anonymous
name          "Trusted Hosts" (informational; not required)
```

Require exactly one match. If zero or multiple components match, stop: the realm
was modified by hand or the wrong realm is in use. Never substitute a UUID
remembered from another machine or an earlier realm — each step below resolves
it live.

Two operational notes learned in practice:

- An *unfiltered* `/components` collection GET may omit `providerType` on
  some entries (it came back as absent/null), which makes type-based
  filtering on the raw list silently return nothing. Prefer the filtered
  query above and confirm on `providerId`/`subType`.
- Collection views can also show `config: {}` even when component
  configuration exists. Never read or write policy values from a collection
  view — always fetch the single component by ID.

## 3. Fetch, update, and push the component (single bounded command)

The entire mint, resolve, fetch, change, push, verify, and cleanup sequence
runs in one root-controlled command. Mint-to-verify wall time is seconds, so
it cannot cross the token's 60-second lifetime, and verification happens in
the same process directly after the PUT. If this step fails for any reason,
re-run the whole command — a fresh mint is taken at its top, the component is
re-resolved live, and the presence guard makes a retry idempotent (an address
already present is a no-success, not an error):

```bash
umask 077
pass="$(sudo cat /opt/keycloak/admin.pass)" || exit 1
body=$(mktemp /tmp/.kctmp.XXXXXX)
printf 'grant_type=password&client_id=admin-cli&username={{KEYCLOAK_ADMIN_USER}}&password=%s' "$pass" > "$body"
tok=$(curl -sS -X POST --data @"$body" \
  http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/realms/master/protocol/openid-connect/token \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])') || { rm -f "$body"; unset pass; exit 1; }
rm -f "$body"; unset pass
[ -n "$tok" ] || exit 1

# Resolve the component live in this same command (never from a previous step).
curl -sS -H "Authorization: Bearer ***" \
  'http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/admin/realms/{{MCP_REALM}}/components?subType=anonymous' > /tmp/kc-components.json

python3 - <<'EOF'
import json, sys
data = json.load(open('/tmp/kc-components.json'))
matches = [c for c in data if c.get('providerId') == 'trusted-hosts' and c.get('subType') == 'anonymous']
assert len(matches) == 1, "stop: zero or multiple components; the realm was modified by hand or the wrong realm is in use"
open('/tmp/kc-cid.txt', 'w').write(matches[0]['id'])
EOF
[ $? -eq 0 ] || exit 1

CID=$(cat /tmp/kc-cid.txt)

# Fetch directly by ID and assert the shape before any edit. An error body (for
# example a 401 JSON from an expired token) captured into this file must fail
# loudly, not pass as data.
curl -sS -H "Authorization: Bearer ***" \
  "http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/admin/realms/{{MCP_REALM}}/components/$CID" > /tmp/kc-th-before.json

python3 - <<'EOF'
import json, sys
raw = open('/tmp/kc-th-before.json').read()
c = json.loads(raw)
assert c.get('providerId') == 'trusted-hosts' and c.get('subType') == 'anonymous', \
    "unexpected component shape (possible transient or error body): " + raw[:200]
hosts = list(c['config'].get('trusted-hosts', []))
print("current hosts:", hosts)
new_ip = "{{CLIENT_SOURCE_IP}}"
if new_ip not in hosts:
    hosts.append(new_ip)
c['config']['trusted-hosts'] = hosts
c['config']['host-sending-registration-request-must-match'] = ["true"]
c['config']['client-uris-must-match'] = ["true"]
with open('/tmp/kc-th-update.json', 'w') as f:
    json.dump(c, f)
print("hosts after change:", hosts)
EOF
[ $? -eq 0 ] || exit 1

# Push the full representation back with a single PUT; require an HTTP 2xx code.
PUT_CODE=$(curl -sS -o /dev/null -w 'HTTP %{http_code}' -X PUT \
  -H "Authorization: Bearer ***" \
  -H 'Content-Type: application/json' --data @/tmp/kc-th-update.json \
  "http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/admin/realms/{{MCP_REALM}}/components/$CID") || exit 1
case "$PUT_CODE" in
  HTTP\ 2*) : ;;
  *) echo "PUT failed: $PUT_CODE"; exit 1 ;;
esac

# Verify against a SECOND direct fetch, in this same process, after the PUT.
curl -sS -H "Authorization: Bearer ***" \
  "http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/admin/realms/{{MCP_REALM}}/components/$CID" > /tmp/kc-th-after.json

python3 - <<'EOF'
import json, sys
raw = open('/tmp/kc-th-after.json').read()
c = json.loads(raw)
if c.get('providerId') != 'trusted-hosts':
    sys.exit("unexpected component representation: " + raw[:200])
hosts = c['config']['trusted-hosts']
print("stored:", hosts)
assert "{{CLIENT_SOURCE_IP}}" in hosts, "new client address missing"
for keep in ["localhost", "127.0.0.1"]:          # plus any pre-existing LAN IPs
    assert keep in hosts, f"pre-existing host lost: {keep}"
assert c['config']['host-sending-registration-request-must-match'] == ["true"]
assert c['config']['client-uris-must-match'] == ["true"]
print("VERIFY OK")
EOF
rc=$?

# Clean up this step's artifacts, including the update payload, before exit.
rm -f /tmp/kc-components.json /tmp/kc-cid.txt \
  /tmp/kc-th-before.json /tmp/kc-th-update.json /tmp/kc-th-after.json
[ $rc -eq 0 ]
```

The resulting stored configuration must look like the shape below (order in the
list is not significant — Keycloak may store the appended value at any
position):

```json
{
  "trusted-hosts": [
    "<pre-existing hosts...>",
    "{{CLIENT_SOURCE_IP}}",
    "localhost",
    "127.0.0.1"
  ],
  "host-sending-registration-request-must-match": ["true"],
  "client-uris-must-match": ["true"]
}
```

If a fetch ever returns an unexpected or empty body (a transient condition was
observed once in the field), re-run the entire step — a fresh mint is taken at
its top and the shape assertion fails loudly on an error body. The verification
must be against the *second* direct fetch, after the PUT, in the same process.

## 4. Hand back to the client

Confirm nothing matching the patterns remains in `/tmp` (no `.kctmp.*`,
`.kctok.*`, `kc-components.json`, `kc-cid.txt`, or `kc-th-*` files), then tell
the client to proceed with Step 5 of `ADD_CLIENT.md` (add the Hermes MCP entry)
and let it run DCR. Confirm success by watching Nginx record a `201` for the
`clients-registrations/openid-connect` POST from `{{CLIENT_SOURCE_IP}}`:

```bash
sudo grep 'clients-registrations/openid-connect' \
  /var/log/nginx/access.log | tail -n 3
```

If the client receives `"Host not trusted"` again, its observed source
address differs from the one you added (NAT/routing change); repeat Step 1's
log check, and add only the new address.

## Individual addresses versus subnets

The strict default is to allow each observed client address individually.
This gives clear registration boundaries but requires stable addresses or
DHCP reservations. A narrowly scoped trusted subnet may reduce
administration on a controlled LAN, but use it only after confirming that the
installed Keycloak provider accepts the intended CIDR syntax. Do not assume
CIDR support, and do not disable Trusted Hosts merely to simplify
onboarding.

## Troubleshooting

- **`401` on the token endpoint** — wrong admin username or password file;
  check `{{KEYCLOAK_ADMIN_USER}}` against the permanent administrator created
  per `KEYCLOAK_ADMIN.md`, and that `/opt/keycloak/admin.pass` is the current
  one. Never retry with a different realm than `master`.
- **Zero components matching** — wrong realm, or the anonymous DCR policy was
  deleted/renamed by hand. Inspect all sub-types (`subType=anonymous`) before
  touching anything; restoring a provider from memory is not supported here.
- **PUT returns `409` or the component changes between read and write** —
  another administrator acted concurrently. Re-fetch, re-apply your one-line
  addition to the *current* host list, and PUT again. Never overwrite with a
  stale copy.
- **Client still gets `insufficient_scope` / `Host not trusted` after a
  correct write** — verify Nginx is forwarding the real client address (not
  an intermediate NAT) via `proxy_real_ip`/access-log source column; the
  policy matches the address Keycloak actually receives.

## Final checklist

- Keycloak health on loopback returned `200`.
- `{{CLIENT_SOURCE_IP}}` came from the Nginx DCR access log (Step 1), not a guess.
- Exactly one anonymous `trusted-hosts` component existed in `{{MCP_REALM}}`.
- All pre-existing trusted hosts were preserved; exactly one address was added.
- Both matching controls remain `["true"]`.
- Verification used a direct by-ID GET after the PUT and passed every assert.
- Token, body, and JSON temp files are deleted; no secret is printed anywhere.
- The client's next DCR attempt from the same address succeeds (`201`).
