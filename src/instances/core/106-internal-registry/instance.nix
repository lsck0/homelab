# docker image registry and its ui, internal only
{
  lib,
  net,
  roles,
  swarmManagers,
  profiles,
  ...
}:
let
  apiPort = 5000;
  # docker clients: no browser login, image layers the waf rules misread, nobody outside the lab; no card
  dockerClients =
    lib.subtractLists [ "sso" "waf" "bodyLimit" "internet" "cloudflare" ] profiles.hardenedInternal ++ profiles.observed;
  # by socket address: the deploy controller, the forgejo runner's ci and the workstation
  pushers =
    map net.hostSource [
      roles.app-builder
      roles.ci
    ]
    ++ [ "${net.wan.workstation}/32" ];
  pushUsers = {
    ci = "registry-push-password";
    builder = "registry-builder-password";
  };
in
{
  vm = {
    bootPhase = "dev";
    needs = [
      "containers"
      "nfs"
    ];
  };

  services = {
    # reads, for every holder of a registry credential at the address it holds it on: the swarms pull (their
    # managers hold `puller`), the pushers read what they push; the methods of the two routes are disjoint, so a
    # host that both pulls and pushes (the deploy controller) reaches each route with its own credential
    registry-api = {
      host = "registry";
      port = apiPort;
      methods = [
        "GET"
        "HEAD"
      ];
      sources = lib.unique ([ net.zones.apps.subnet ] ++ map net.hostSource swarmManagers ++ pushers);
      basicAuth = {
        puller = "registry-pull-password";
      }
      // pushUsers;
      on = dockerClients ++ [ "probe" ];
    };
    # writes; DELETE stays with the registry ui's own cleanup on this guest
    registry-push = {
      host = "registry";
      port = apiPort;
      methods = [
        "POST"
        "PUT"
        "PATCH"
      ];
      sources = pushers;
      basicAuth = pushUsers;
      # registry-api probes the same port
      on = dockerClients;
    };
    registry-ui = {
      port = 80;
      homepage = {
        group = "Dev";
        icon = "docker-moby";
        name = "Registry";
      };
      on = profiles.hardenedInternal ++ profiles.listed ++ profiles.observed;
    };
  };

  shares = {
    "data/registry" = { };
  };
}
