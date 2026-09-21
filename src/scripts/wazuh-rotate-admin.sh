#!/usr/bin/env bash
# Point the Wazuh indexer's `admin` account at the Authelia password.
#
# Run it ON vm-107:
#
#   ssh root@10.100.0.107 'bash -s' < src/scripts/wazuh-rotate-admin.sh
#
# Why this is not part of 107-internal-wazuh.nix: that unit only rewrites the
# credentials when the compose file still carries the upstream demo password
# (`INDEXER_PASSWORD=SecretPassword`). An earlier revision of this lab replaced
# it with a generated value, so the guard never matches again and the "use the
# Authelia password" step silently never runs. Worse, the indexer seeds users
# from internal_users.yml on FIRST start only; once the data volume exists the
# file is ignored and the hash has to be pushed into the running cluster with
# securityadmin.sh, which needs the admin certificate. That is what this does.
#
# Safe to re-run. It backs both files up, verifies the new password works
# before touching docker-compose.yml, and restores the config on failure.
set -euo pipefail

cd /opt/wazuh-docker/single-node
IDX=single-node-wazuh.indexer-1
STAMP=$(date +%Y%m%d-%H%M%S)

A=$(cat /var/lib/wazuh/admin-pass)
[ -n "$A" ] || { echo "ERROR: /var/lib/wazuh/admin-pass is empty"; exit 1; }

cp -a config/wazuh_indexer/internal_users.yml config/wazuh_indexer/internal_users.yml.bak-"$STAMP"
cp -a docker-compose.yml docker-compose.yml.bak-"$STAMP"
echo ">>> backups written: *.bak-$STAMP"

# the password is passed through the environment the whole way. It is the
# Authelia one and may contain "/" or a trailing "\", either of which a shell
# or sed round-trip would mangle.
HASH=$(docker exec -e P="$A" "$IDX" sh -c \
  '/usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p "$P"' | tr -d '\r' | tail -1)
case "$HASH" in
  \$2*) ;;
  *) echo "ERROR: hash.sh returned: $HASH"; exit 1 ;;
esac
echo ">>> bcrypt hash generated"

H="$HASH" awk '
  /^[a-z_-]+:$/ { user = $0 }
  /^  hash:/ && user == "admin:" { print "  hash: \"" ENVIRON["H"] "\""; next }
  { print }' config/wazuh_indexer/internal_users.yml > /tmp/iu.yml
grep -q "$HASH" /tmp/iu.yml || { echo "ERROR: hash not written"; exit 1; }
mv /tmp/iu.yml config/wazuh_indexer/internal_users.yml

echo ">>> pushing internalusers to the running indexer"
docker exec "$IDX" sh -c '
  export JAVA_HOME=/usr/share/wazuh-indexer/jdk
  /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
    -f /usr/share/wazuh-indexer/config/opensearch-security/internal_users.yml \
    -t internalusers -icl -nhnv \
    -cacert /usr/share/wazuh-indexer/config/certs/root-ca.pem \
    -cert /usr/share/wazuh-indexer/config/certs/admin.pem \
    -key /usr/share/wazuh-indexer/config/certs/admin-key.pem \
    -h localhost -p 9200' 2>&1 | tail -6

CODE=$(docker exec -e P="$A" "$IDX" sh -c \
  'curl -sk -u "admin:$P" https://localhost:9200/_cluster/health -o /dev/null -w "%{http_code}"')
echo ">>> login with the Authelia password: $CODE"
if [ "$CODE" != 200 ]; then
  echo "ABORT: the new password does not work. Restoring internal_users.yml."
  cp -a config/wazuh_indexer/internal_users.yml.bak-"$STAMP" config/wazuh_indexer/internal_users.yml
  exit 1
fi

# only now is it safe to teach the manager and the dashboard the new value.
A="$A" awk '
  /INDEXER_PASSWORD=/ {
    n = index($0, "INDEXER_PASSWORD=")
    print substr($0, 1, n - 1) "INDEXER_PASSWORD=" ENVIRON["A"]
    next
  }
  { print }' docker-compose.yml > /tmp/dc.yml
mv /tmp/dc.yml docker-compose.yml
echo ">>> docker-compose.yml updated ($(grep -c 'INDEXER_PASSWORD=' docker-compose.yml) occurrences)"

docker compose up -d 2>&1 | tail -4
sleep 20
docker ps --format '{{.Names}} {{.Status}}'
