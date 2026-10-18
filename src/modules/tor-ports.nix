# the router's tor listeners (instances/core/300-router/main.nix): socks for the owner's own checks from the router itself,
# socksIsolated, one circuit per destination, for prowlarr's indexer searches (121-internal-arr's prowlarr and arr-wire),
# trans and dns for the guests whose egress is tor (instance.nix `on`): their tcp redirected, their names asked;
# onionIngress, the edge's plain http entrypoint where the router's tor hands over an onion route's visitors
{ socks = 9050; socksIsolated = 9055; control = 9051; trans = 9040; dns = 9053; onionIngress = 8090; }
