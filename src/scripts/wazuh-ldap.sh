#!/usr/bin/env bash
# Teach the Wazuh indexer to authenticate against lldap.
#
# Wazuh's dashboard authenticates against the indexer's OpenSearch Security
# plugin, which had only its internal user database - so the one lldap account
# worked everywhere in the lab except here, where the username was "admin" and
# the password only matched because a separate unit rotates it to the same
# value.
#
# Two files do it: an `ldap` authc domain that binds the user, and an authz
# domain that reads their groups back as backend roles. roles_mapping then
# hands the `admins` group `all_access`.
#
# The security plugin reads these from its own index, not from disk, so the
# files on disk are only the input to securityadmin.sh. They are bind-mounted
# as well, which is what makes them survive the container being recreated.
#
# Two modes, because of an ordering trap: Docker creates a *directory* when a
# bind-mount source does not exist, so the files have to be on disk before the
# stack starts, while securityadmin can only run once the cluster is up.
#   write - lay the two files down (ordered before wazuh.service)
#   push  - restart the indexer and upload them (ordered after)
set -euo pipefail

MODE=${1:-push}
STACK=${STACK:-/opt/wazuh-docker/single-node}
IDX=${IDX:-single-node-wazuh.indexer-1}
CFG=$STACK/config/wazuh_indexer
LDAP_HOST=${LDAP_HOST:-10.100.0.102}
LDAP_PORT=${LDAP_PORT:-3890}
LDAP_BASE_DN=${LDAP_BASE_DN:-dc=lsck0,dc=dev}
LDAP_BIND_DN=${LDAP_BIND_DN:-uid=admin,ou=people,$LDAP_BASE_DN}
# the lldap group whose members get all_access on the indexer
LDAP_ADMIN_GROUP=${LDAP_ADMIN_GROUP:-admins}
BIND_PASSWORD=$(cat "${LDAP_BIND_PASSWORD_FILE:?}")
[ -n "$BIND_PASSWORD" ] || { echo "ERROR: the LDAP bind password is empty"; exit 1; }

cd "$STACK"

write_files() {

# ── the two security files ───────────────────────────────────────────────────
# config.yml is replaced wholesale rather than patched: it is the plugin's
# own shipped file plus one authc domain and one authz domain, and a patch
# against a file that changes between Wazuh releases is the more fragile of
# the two.
#
# challenge: false on the LDAP domain. Only one domain may answer a failed
# request with a WWW-Authenticate header, and that stays with the internal
# database so the local admin remains a way in if lldap is down.
umask 027
cat > "$CFG/config.yml" <<EOF
---
_meta:
  type: "config"
  config_version: 2

config:
  dynamic:
    http:
      anonymous_auth_enabled: false
      xff:
        enabled: false
    authc:
      basic_internal_auth_domain:
        description: "Authenticate against the internal user database"
        http_enabled: true
        transport_enabled: true
        order: 0
        http_authenticator:
          type: basic
          challenge: true
        authentication_backend:
          type: intern
      ldap_auth_domain:
        description: "Authenticate against lldap"
        http_enabled: true
        transport_enabled: false
        order: 1
        http_authenticator:
          type: basic
          challenge: false
        authentication_backend:
          type: ldap
          config:
            enable_ssl: false
            enable_start_tls: false
            enable_ssl_client_auth: false
            verify_hostnames: false
            hosts:
              - $LDAP_HOST:$LDAP_PORT
            bind_dn: $LDAP_BIND_DN
            password: "$BIND_PASSWORD"
            userbase: "ou=people,$LDAP_BASE_DN"
            usersearch: "(uid={0})"
            username_attribute: uid
    authz:
      roles_from_lldap:
        description: "Read group membership from lldap as backend roles"
        http_enabled: true
        transport_enabled: false
        authorization_backend:
          type: ldap
          config:
            enable_ssl: false
            enable_start_tls: false
            enable_ssl_client_auth: false
            verify_hostnames: false
            hosts:
              - $LDAP_HOST:$LDAP_PORT
            bind_dn: $LDAP_BIND_DN
            password: "$BIND_PASSWORD"
            userbase: "ou=people,$LDAP_BASE_DN"
            usersearch: "(uid={0})"
            username_attribute: uid
            # lldap publishes groups as groupOfUniqueNames, so membership is
            # uniqueMember and the role name is the cn.
            rolebase: "ou=groups,$LDAP_BASE_DN"
            rolesearch: "(uniqueMember={0})"
            userrolename: disabled
            rolename: cn
            resolve_nested_roles: true
EOF

# roles_mapping is the image's own file with two lines added, not a file of
# our own. Writing it from scratch is what broke the dashboard: the version
# here listed all_access, own_index and kibana_user, and silently dropped
# kibana_server - the mapping that grants the dashboard's own service account
# its permissions. The dashboard then could not read the cluster state:
#   [security_exception] no permissions for [cluster:monitor/state] and
#   User [name=kibanaserver, backend_roles=[]]
# So the shipped file is taken from the image on every run and patched.
# From the compose file, not from `docker inspect`: the files have to be on
# disk before the stack starts, so at this point there is no container to ask.
IMAGE=${IMAGE:-$(awk '/wazuh\.indexer:/,/image:/ { if ($1 == "image:") { print $2; exit } }' \
  "$STACK/docker-compose.yml")}
[ -n "$IMAGE" ] || { echo "ERROR: no indexer image in docker-compose.yml"; exit 1; }
docker run --rm --entrypoint cat "$IMAGE" \
  /usr/share/wazuh-indexer/config/opensearch-security/roles_mapping.yml > "$CFG/roles_mapping.yml.orig"
[ -s "$CFG/roles_mapping.yml.orig" ] || { echo "ERROR: could not read the shipped roles_mapping"; exit 1; }

LDAP_ADMIN_GROUP="$LDAP_ADMIN_GROUP" python3 - \
  "$CFG/roles_mapping.yml.orig" "$CFG/roles_mapping.yml" <<'PYEOF'
import os, sys, yaml

group = os.environ["LDAP_ADMIN_GROUP"]
doc = yaml.safe_load(open(sys.argv[1]))

# all_access so the group administers the cluster, kibana_user so the
# dashboard will load for them at all. Everything else the image ships -
# kibana_server above all - is left exactly as it was.
for role in ("all_access", "kibana_user"):
    entry = doc.setdefault(role, {"reserved": False, "hidden": False,
                                  "hosts": [], "users": [], "and_backend_roles": []})
    roles = entry.setdefault("backend_roles", [])
    if group not in roles:
        roles.append(group)

with open(sys.argv[2], "w") as f:
    yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
PYEOF
rm -f "$CFG/roles_mapping.yml.orig"
echo ">>> roles_mapping patched: $LDAP_ADMIN_GROUP added to all_access and kibana_user"

chmod 640 "$CFG/config.yml" "$CFG/roles_mapping.yml"
chmod 750 "$CFG"
echo ">>> security files written"
}

push_config() {

# ── make the container see them ──────────────────────────────────────────────
# Both are bind-mounted as single files, so the container holds the inode it
# started with. Rewriting on the host leaves it reading the old contents, and
# securityadmin then pushes the old file while reporting success - the exact
# trap that made three runs of the password rotation change nothing.
echo ">>> restarting the indexer so the bind mounts pick up the new files"
docker restart "$IDX" >/dev/null
for _ in $(seq 1 60); do
  docker exec "$IDX" curl -sk https://localhost:9200 -o /dev/null 2>/dev/null && break
  sleep 3
done

docker exec -u 0 "$IDX" grep -q "ldap_auth_domain" \
  /usr/share/wazuh-indexer/config/opensearch-security/config.yml \
  || { echo "ERROR: the indexer still reads the old config.yml"; exit 1; }

# ── push into the running cluster ────────────────────────────────────────────
# The plugin serves what is in its .opendistro_security index, not what is on
# disk; the files above only become live once securityadmin uploads them.
echo ">>> pushing the security configuration"
docker exec "$IDX" sh -c '
  export JAVA_HOME=/usr/share/wazuh-indexer/jdk
  export PATH="$JAVA_HOME/bin:/usr/bin:/bin"
  /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
    -cd /usr/share/wazuh-indexer/config/opensearch-security \
    -icl -nhnv \
    -cacert /usr/share/wazuh-indexer/config/certs/root-ca.pem \
    -cert /usr/share/wazuh-indexer/config/certs/admin.pem \
    -key /usr/share/wazuh-indexer/config/certs/admin-key.pem \
    -h localhost -p 9200' 2>&1 | tail -5

echo ">>> lldap accounts can now sign in to Wazuh"
}

# A previous boot may have let Docker create directories where these files
# should be, which is what happens when the stack starts before they exist.
for f in "$CFG/config.yml" "$CFG/roles_mapping.yml"; do
  if [ -d "$f" ]; then
    echo ">>> removing the directory Docker left at $f"
    rmdir "$f"
  fi
done

case "$MODE" in
  write) write_files ;;
  push)  write_files; push_config ;;
  *) echo "usage: wazuh-ldap.sh [write|push]"; exit 2 ;;
esac
