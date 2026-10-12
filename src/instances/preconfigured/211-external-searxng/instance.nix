# privacy metasearch
{ lib, profiles, ... }: {
  vm = {
    bootPhase = "public";
    needs = [ "containers" ];
    kind.lxc = "an existing lxc with local state; recreating it as a vm needs a data migration";
    # podman needs keyctl; dmz, so never privileged
    features = "nesting=1,keyctl=1";
  };

  # engine traffic: neither strangers' searches nor the owner's point at the house ip, and engines rate-limit the tunnel
  on = profiles.vpnEgress;

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
      # anubis fronts it at the edge; the search query is in the url, which the access log would keep
      on = lib.subtractLists [ "cloudflare" "accessLog" ] profiles.hardenedExternal ++ profiles.listed ++ profiles.observed;
    };
  };
}
