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

# all_access keeps "admin" so the local account still works, and gains the
# lldap group. kibana_user is what lets the dashboard load at all.
cat > "$CFG/roles_mapping.yml" <<EOF
---
_meta:
  type: "rolesmapping"
  config_version: 2

all_access:
  reserved: true
  hidden: false
  backend_roles:
  - "admin"
  - "$LDAP_ADMIN_GROUP"
  hosts: []
  users: []
  and_backend_roles: []
  description: "Maps admin and the lldap $LDAP_ADMIN_GROUP group to all_access"

own_index:
  reserved: false
  hidden: false
  backend_roles: []
  hosts: []
  users:
  - "*"
  and_backend_roles: []
  description: "Allow full access to an index named like the username"

kibana_user:
  reserved: false
  hidden: false
  backend_roles:
  - "kibanauser"
  - "$LDAP_ADMIN_GROUP"
  hosts: []
  users: []
  and_backend_roles: []
  description: "Maps the lldap $LDAP_ADMIN_GROUP group to kibana_user"
EOF
# uid 1000 is wazuh-indexer inside the image, and the container runs as that
# user: root-owned 640 files are simply invisible to it. 640 and not 644
# because config.yml carries the LDAP bind password in plaintext - the
# plugin has no way to read it from anywhere else - so the directory above
# is what keeps it off the rest of the host.
chown 1000:1000 "$CFG/config.yml" "$CFG/roles_mapping.yml"
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
