{ config, pkgs, inventory, ... }:
let
  # the image's searxng user (container/dist.dockerfile chowns its tree to 977)
  searxngUid = toString 977;
  # the image's valkey user and group
  valkeyUser = "999:1000";
  # the image's GRANIAN_PORT
  searxngPort = toString 8080;
  valkeyPort = toString 6379;
  # limiter counters live 10 min to 30 days at ~100 B each: tens of thousands of client ips fit
  valkeyMaxMemory = "16mb";
  # maxmemory plus the server's own ~10 MiB
  valkeyContainerMemory = "48m";
  # ~140 MiB: vm 30d peak 393 minus the idle base
  searxngContainerMemory = "256m";
  # a wedged worker costs at most this much search; each run is a journal line
  healthInterval = "5m";

  # own bridge with a fixed valkey address: the default one has no dns, and aardvark would need udp 53 opened
  network = "searxng";
  networkSubnet = "10.89.204.0/24";
  valkeyIp = "10.89.204.2";

  # vm-200 traefik -> anubis -> socket proxy reaches us from its own ip, the client in xff
  ingressIp = inventory."200".ip;
  # hermes reads format=json directly, past the 4 per hour api cap
  hermesIp = inventory."114".ip;

  secret = "/var/lib/searxng/secret";
  # under the unit's RuntimeDirectory: the rendered secret never lands on disk
  configDir = "/run/searxng/config";

  settings = (pkgs.formats.yaml { }).generate "searxng-settings.yml" {
    use_default_settings = true;
    general.donation_url = false;
    server = {
      secret_key = "@SECRET@";
      base_url = "https://search.lsck0.dev/";
      # engine traffic leaves from one ip, strangers' floods would get it captcha'd for everyone
      limiter = true;
      # forces link_token and refuses to start without valkey instead of running unlimited
      public_instance = true;
      # result thumbnails come through us, the client never talks to image hosts
      image_proxy = true;
      # POST breaks back and shared links, and the address bar searches via GET regardless
      method = "GET";
    };
    valkey.url = "valkey://${valkeyIp}:${valkeyPort}/0";
    search = {
      # every keystroke would go to the provider
      autocomplete = "";
      # json for hermes, everyone else is held to the limiter's api cap
      formats = [ "html" "json" ];
    };
    # a page never waits longer than this on one slow engine (wttr asks 9s, gentoo 10s)
    outgoing.max_request_timeout = 6.0;
    # off: html google (403 upstream, google cse stands in), qwant and mojeek (captcha this ip)
    engines = [
      { name = "bing"; disabled = false; }
      # google results, works again since the image's startpage anubis solver
      { name = "startpage"; inactive = false; disabled = false; }
      { name = "nixos wiki"; disabled = false; }
      { name = "duden"; disabled = false; }
      # onion engines need a tor proxy, they fail to load on every start
      { name = "ahmia"; inactive = true; }
      { name = "torch"; inactive = true; }
    ];
  };

  limiter = (pkgs.formats.toml { }).generate "searxng-limiter.toml" {
    botdetection = {
      # without the ingress here every client is its ip and shares one quota
      trusted_proxies = [ "127.0.0.0/8" "::1" "${ingressIp}/32" ];
      ip_limit.link_token = true;
      ip_lists = {
        pass_ip = [ "${hermesIp}/32" ];
        # not listed on searx.space
        pass_searxng_org = false;
      };
    };
  };

  units = [ "podman-searxng.service" "podman-searxng-valkey.service" ];
in {
  networking.hostName = "vm-204";

  systemd.services.podman-network-searxng = {
    description = "Podman network for searxng and its valkey";
    requiredBy = units;
    before = units;
    path = [ config.virtualisation.podman.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # dns off: containers keep the host's resolver
    script = ''
      podman network exists ${network} || podman network create --disable-dns --subnet=${networkSubnet} ${network}
    '';
  };

  # rendered every start; only the secret key is state, so no nas share
  systemd.services.podman-searxng.preStart = ''
    # generated here, a literal would be public in this repo
    [ -s ${secret} ] || (umask 077; head -c 32 /dev/urandom | base64 | tr -d '/+=' > ${secret})
    install -d -m 0700 -o ${searxngUid} -g ${searxngUid} ${configDir}
    (umask 077; sed "s|@SECRET@|$(cat ${secret})|" ${settings} > ${configDir}/settings.yml)
    install -m 0400 ${limiter} ${configDir}/limiter.toml
    chown ${searxngUid}:${searxngUid} ${configDir}/settings.yml ${configDir}/limiter.toml
  '';

  virtualisation.oci-containers.containers = {
    searxng-valkey = {
      image = "docker.io/valkey/valkey:9.1.2-alpine";
      networks = [ network ];
      user = valkeyUser;
      # limiter counters only: a restart just resets every client's window
      cmd = [
        "valkey-server"
        # reachable only from the searxng network, nothing publishes it
        "--bind" "0.0.0.0"
        "--protected-mode" "no"
        "--port" valkeyPort
        "--save" ""
        "--appendonly" "no"
        "--maxmemory" valkeyMaxMemory
        "--maxmemory-policy" "allkeys-lru"
      ];
      capabilities.ALL = false;
      extraOptions = [
        "--ip=${valkeyIp}"
        "--read-only"
        "--security-opt=no-new-privileges"
        "--memory=${valkeyContainerMemory}"
      ];
    };

    searxng = {
      image = "docker.io/searxng/searxng:2026.9.16-461f174b0";
      # pings valkey once at start and exits without it (public_instance)
      dependsOn = [ "searxng-valkey" ];
      networks = [ network ];
      ports = [ "80:${searxngPort}" ];
      # the entrypoint chowns only as root; the preStart already did
      user = "${searxngUid}:${searxngUid}";
      volumes = [ "${configDir}:/etc/searxng" ];
      capabilities.ALL = false;
      extraOptions = [
        # writes go to the image's /var/cache/searxng volume and podman's /tmp
        "--read-only"
        "--security-opt=no-new-privileges"
        "--memory=${searxngContainerMemory}"
        "--health-cmd=wget -q -O /dev/null http://127.0.0.1:${searxngPort}/healthz"
        "--health-interval=${healthInterval}"
        # the unit's Restart=always brings it back
        "--health-on-failure=kill"
      ];
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/searxng 0700 root root -"
    # the old rendered config, secret included; it renders to /run now
    "r /var/lib/searxng/settings.yml - - - - -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
  # the limiter trusts the ingress's xff: nobody else may reach the port to forge one or skip anubis
  homelab.ingressOnly.ports = [ 80 ];
  homelab.ingressOnly.portSources."80" = [ "${ingressIp}/32" ];
}
