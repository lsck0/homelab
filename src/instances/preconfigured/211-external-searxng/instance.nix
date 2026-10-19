# privacy metasearch
{ lib, profiles, ... }:
let
  port = 80;
in
{
  vm = {
    bootPhase = "public";
    needs = [ "containers" ];
    kind.lxc = "a vm's kernel would triple the ~165 MiB it holds awake and lengthen every wake";
    # podman needs keyctl; dmz, so never privileged
    features = "nesting=1,keyctl=1";
  };

  # engine traffic: neither strangers' searches nor the owner's point at the house ip, and engines rate-limit the tunnel
  on = profiles.vpnEgress;

  # a wake holds the first search 6 to 8 s, and 1h woke it 20 times in 4 days: an idle lxc costs ~165 MiB
  idle = {
    stopAfter = "4h";
  };

  grants = [
    {
      from = [ "operator" ];
      tcp = [ port ];
      why = "hermes' search skill calls the json api directly, which the limiter passes for its address (pass_ip)";
    }
    {
      from = [ "collector" ];
      tcp = [ port ];
      why = "vm-103 probes the host port while the guest is awake: the edge's probe would wake it";
    }
  ];

  services = {
    searxng = {
      host = "search";
      inherit port;
      # the limiter passes /healthz alone; at / it answered the probers' user agent with 429
      health = "/healthz";
      # search forms only; the cap bounds what one client can make the edge buffer
      bodyLimitBytes = 32 * 1024 * 1024;
      # the query is in the url: no referrer leaves
      referrer = false;
      homepage = {
        group = "Public";
        icon = "searxng";
        name = "SearXNG";
      };
      # anubis fronts it at the edge; the search query is in the url, which the access log would keep
      on = lib.subtractLists [ "cloudflare" "accessLog" ] profiles.hardenedExternal ++ profiles.listed ++ profiles.observed;
    };
  };
}
