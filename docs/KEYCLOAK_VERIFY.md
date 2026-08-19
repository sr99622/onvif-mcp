


Resolve the bootstrap account ID before deletion:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh get users \
  --config /tmp/kcadm-permanent.config \
  -r master -q exact=true -q username=admin \
  --fields id,username
```

Delete only the returned bootstrap user ID:

```bash
sudo docker compose --project-directory /opt/keycloak exec keycloak \
  /opt/keycloak/bin/kcadm.sh delete users/BOOTSTRAP_USER_UUID \
  --config /tmp/kcadm-permanent.config \
  -r master
```

Remove both `KC_BOOTSTRAP_ADMIN_*` lines from `/opt/keycloak/.env` and the
Keycloak service environment:

```bash
sudo sed -i \
  '/^KC_BOOTSTRAP_ADMIN_USERNAME=/d; /^KC_BOOTSTRAP_ADMIN_PASSWORD=/d' \
  /opt/keycloak/.env

sudo sed -i \
  '/^[[:space:]]*KC_BOOTSTRAP_ADMIN_USERNAME:/d; /^[[:space:]]*KC_BOOTSTRAP_ADMIN_PASSWORD:/d' \
  /opt/keycloak/compose.yaml

sudo docker compose --project-directory /opt/keycloak config --quiet
sudo sh -c '
  if grep -q "^KC_BOOTSTRAP_ADMIN_" /opt/keycloak/.env ||
     grep -q "KC_BOOTSTRAP_ADMIN_" /opt/keycloak/compose.yaml; then
    echo "ERROR: bootstrap entries remain"
    exit 1
  else
    echo "Bootstrap entries removed"
  fi
'
```

Recreate Keycloak so those variables leave the container environment:

```bash
sudo docker compose --project-directory /opt/keycloak up -d --force-recreate keycloak
sudo docker compose --project-directory /opt/keycloak ps
```

Wait for `HTTP 200` again, then repeat the secure permanent-administrator
login, this time writing `/tmp/kcadm.config`. Container recreation deletes
files under `/tmp`.

