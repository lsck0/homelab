# docker image registry and its ui, internal only
{ lib, net, swarmManagers, ... }:
let
  apiPort = 5000;
  # docker clients: no browser login, no proof of work, layers the waf rules misread, nobody outside the lab
  dockerClients = {
    sso = "docker clients cannot follow a browser login";
    anubis = "docker clients run no proof of work";
    waf = "image layers the rules misread";
    internet = "only the lab's builders and swarms";
    bodyLimit = "image layers";
    homepage = "no web ui; registry-ui has the card";
  };
  # by socket address: the deploy controller, the forgejo runner's ci and the workstation
  pushers = [ (net.hostSource "140") (net.hostSource "117") "${net.wan.workstation}/32" ];
  pushUsers = { ci = "registry-push-password"; builder = "registry-builder-password"; };
in {
  vm = {
    bootPhase = "dev";
    needs = [ "containers" "nfs" ];
  };

  services = {
    # reads, for every holder of a registry credential at the address it holds it on: the swarms pull (their
    # managers hold `puller`), the pushers read what they push; the methods of the two routes are disjoint, so a
    # host that both pulls and pushes (the deploy controller) reaches each route with its own credential
    registry-api = {
      host = "registry";
      port = apiPort;
      methods = [ "GET" "HEAD" ];
      sources = lib.unique ([ net.zones.apps.subnet ] ++ map net.hostSource swarmManagers ++ pushers);
      basicAuth = { puller = "registry-pull-password"; } // pushUsers;
      off = dockerClients;
    };
    # writes; DELETE stays with the registry ui's own cleanup on this guest
    registry-push = {
      host = "registry";
      port = apiPort;
      methods = [ "POST" "PUT" "PATCH" ];
      sources = pushers;
      basicAuth = pushUsers;
      off = dockerClients // { probe = "registry-api probes the same port"; };
    };
    registry-ui = { port = 80; homepage = { group = "Dev"; icon = "docker-moby"; name = "Registry"; }; };
  };
}
