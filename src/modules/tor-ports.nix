# the router's tor listeners (instances/300-router/main.nix): socks for the owner's own checks from the router itself,
# socksIsolated, one circuit per destination, for prowlarr's indexer searches (130-internal-arr's prowlarr and arr-wire)
{ socks = 9050; socksIsolated = 9055; control = 9051; }
