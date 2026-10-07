# privacy metasearch
{ ... }: {
  vm = {
    bootPhase = "public";
    needs = [ "containers" ];
    kind.lxc = "pending migration, see the restructure report";
    # podman needs keyctl; dmz, so never privileged
    features = "nesting=1,keyctl=1";
  };

  # engine traffic: neither strangers' searches nor the owner's point at the house ip, and engines rate-limit the tunnel
  egress = { via = "vpn"; inbound = false; };

  idle = { stopAfter = "1h"; };

  services = {
    searxng = {
      host = "search";
      port = 80;
      # search forms only; the cap bounds what one client can make the edge buffer
      bodyLimitBytes = 32 * 1024 * 1024;
      # the query is in the url: no referrer leaves
      referrer = false;
      homepage = { group = "Public"; icon = "searxng"; name = "SearXNG"; };
      off = {
        sso = "public metasearch";
        cloudflare = "anubis fronts it at the edge";
        accessLog = "the search query is in the url";
      };
    };
  };
}
