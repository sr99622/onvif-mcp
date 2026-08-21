# Permit a New DCR Client on the Server (Trusted Hosts)

## Purpose

Server-side companion to Step 4 of `ADD_CLIENT.md`. It adds one new Hermes
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
| `{{CLIENT_SOURCE_IP}}` | Address Nginx recorded for the client's DCR request (from Step 3 of `ADD_CLIENT.md`) | e.g. `192.168.68.51` |

The admin password lives in a root-owned, mode `0600` file
(`/opt/keycloak/admin.pass` in this deployment). Create the token body and
token stash with a restrictive umask so the credential never appears on a
command line, in an environment variable, or in an untrusted location.

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
  previous deployment — always resolve it live as in Step 3 below.

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

`{{CLIENT_SOURCE_IP}}` must be the address from Step 3 of `ADD_CLIENT.md`,
i.e. the source address recorded by Nginx for the client's DCR request —
not an address guessed from the client machine:

```bash
sudo grep 'clients-registrations/openid-connect' \
  /var/log/nginx/access.log | tail -n 5
```

If no entry exists yet, the client has not attempted registration; the
policy change is harmless but cannot be confirmed against traffic.

## 2. Obtain an Admin REST token

Keycloak 26 disables password grants for most built-in clients, and `kcadm`
inside the deployment directory can prompt without a console. The reliable
pattern is `admin-cli` with the permanent administrator from one process,
using a mode `0600` temporary body file.

Note: in this deployment `/opt/keycloak` is root-owned (mode `750`) and not
writable by the operating user; create temp files under `/tmp`, not there.

```bash
pass="$(sudo cat /opt/keycloak/admin.pass)" || exit 1
umask 077
body=$(mktemp /tmp/.kctmp.XXXXXX)
printf 'grant_type=password&client_id=admin-cli&username={{KEYCLOAK_ADMIN_USER}}&password=%s' "$pass" > "$body"
tok=$(curl -sS -X POST --data @"$body" \
  http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/realms/master/protocol/openid-connect/token \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])') || { rm -f "$body"; unset pass; exit 1; }
rm -f "$body"; unset pass

tfile=$(mktemp /tmp/.kctok.XXXXXX); chmod 600 "$tfile"
printf '%s' "$tok" > "$tfile"; unset tok
echo "TOKEN_FILE=$tfile" > /tmp/.kcstep4.env   # keep out of shell history
```

If the token call fails, inspect the response body (it is an error JSON when
authentication fails), fix the credential or username, and delete both temp
files before retrying. The `master` realm administrator with the realm-level
`admin` role can manage components in any realm.

## 3. Resolve the live anonymous Trusted Hosts component

Query the MCP realm's DCR policy components filtered by sub-type:

```bash
source /tmp/.kcstep4.env
curl -sS -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
  'http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/admin/realms/{{MCP_REALM}}/components?subType=anonymous' \
  | python3 -m json.tool
```

Select the component whose:

```text
providerType = org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy
providerId   = trusted-hosts
subType      = anonymous
name          "Trusted Hosts" (informational; not required)
```

Require exactly one match and take its `id`. If zero or multiple components
match, stop: the realm was modified by hand or the wrong realm is in use.
Never substitute a UUID remembered from another machine or an earlier realm.

Two operational notes learned in practice:

- An *unfiltered* `/components` collection GET may omit `providerType` on
  some entries (it came back as absent/null), which makes type-based
  filtering on the raw list silently return nothing. Prefer the filtered
  query above and confirm on `providerId`/`subType`.
- Collection views can also show `config: {}` even when component
  configuration exists. Never read or write policy values from a collection
  view — always fetch the single component by ID.

## 4. Fetch, update, and push the component

Fetch the component *directly* by ID so you edit the exact stored
representation. Preserve every existing trusted host; append only
`{{CLIENT_SOURCE_IP}}`; keep both matching controls:

```bash
source /tmp/.kcstep4.env
CID=<component id from step 3>
curl -sS -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
  http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/admin/realms/{{MCP_REALM}}/components/$CID > /tmp/kc-th-before.json

python3 - <<'EOF'
import json
c = json.load(open('/tmp/kc-th-before.json'))
assert c.get('providerId') == 'trusted-hosts' and c.get('subType') == 'anonymous'
hosts = list(c['config'].get('trusted-hosts', []))
new_ip = "{{CLIENT_SOURCE_IP}}"
if new_ip not in hosts:
    hosts.append(new_ip)
c['config']['trusted-hosts'] = hosts
c['config']['host-sending-registration-request-must-match'] = ["true"]
c['config']['client-uris-must-match'] = ["true"]
with open('/tmp/kc-th-update.json', 'w') as f:
    json.dump(c, f)
print("hosts:", hosts)
EOF
```

The resulting configuration must look like the shape below (order in the list
is not significant — Keycloak may store the appended value at any position):

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

Push the full representation back with a single PUT:

```bash
source /tmp/.kcstep4.env
CID=<component id from step 3>
curl -sS -X PUT \
  -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
  -H 'Content-Type: application/json' --data @/tmp/kc-th-update.json \
  http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/admin/realms/{{MCP_REALM}}/components/$CID
```

A successful PUT returns the updated representation (or empty body in some
versions) with HTTP `2xx`. Check the exit code and, on failure, fetch the
component before retrying so you never PUT a stale or partial document.

## 5. Verify the exact stored configuration

Retrieve the component directly again — not from a collection view — and
assert the stored configuration:

```bash
source /tmp/.kcstep4.env
CID=<component id from step 3>
curl -sS -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
  http://127.0.0.1:{{KEYCLOAK_PORT}}{{KEYCLOAK_PATH}}/admin/realms/{{MCP_REALM}}/components/$CID > /tmp/kc-th-after.json

python3 - <<'EOF'
import json, sys
raw = open('/tmp/kc-th-after.json').read()
c = json.loads(raw)
# Guard against a transient or error body (an earlier run once received a
# response missing the expected fields); fail loudly instead of passing.
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
```

If a fetch ever returns an unexpected or empty body (a transient condition
was observed once in the field), retry the direct GET before concluding the
write failed. The verification must be against the *second* direct fetch,
after the PUT.

## 6. Clean up and hand back to the client

Remove every temporary secret artifact, including the update payloads:

```bash
source /tmp/.kcstep4.env
rm -f /tmp/kc-th-before.json /tmp/kc-th-update.json /tmp/kc-th-after.json \
  "$TOKEN_FILE" /tmp/.kcstep4.env
```

Confirm nothing matching the patterns remains in `/tmp`, then tell the client
to proceed with Step 5 of `ADD_CLIENT.md` (add the Hermes MCP entry) and let
it run DCR. Confirm success by watching Nginx record a `201` for the
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
- `{{CLIENT_SOURCE_IP}}` came from the Nginx DCR access log (Step 3), not a guess.
- Exactly one anonymous `trusted-hosts` component existed in `{{MCP_REALM}}`.
- All pre-existing trusted hosts were preserved; exactly one address was added.
- Both matching controls remain `["true"]`.
- Verification used a direct by-ID GET after the PUT and passed every assert.
- Token, body, and JSON temp files are deleted; no secret is printed anywhere.
- The client's next DCR attempt from the same address succeeds (`201`).
