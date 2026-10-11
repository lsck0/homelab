# the router's tor listeners (instances/300-router/main.nix): socks for the owner's own checks from the router itself,
# socksIsolated, one circuit per destination, for prowlarr's indexer searches (130-internal-arr's prowlarr and arr-wire),
# trans and dns for the guests whose egress is tor (instance.nix `egress`): their tcp redirected, their names asked
{ socks = 9050; socksIsolated = 9055; control = 9051; trans = 9040; dns = 9053; }
