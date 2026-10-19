{
  config,
  lib,
  pkgs,
  inventory,
  catalog,
  site,
  lab,
  ...
}:
let
  net = import ../../../modules/net.nix { inherit lib inventory site; };
  route = catalog.external.searxng;
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

  # the edge's traefik -> anubis -> socket proxy reaches us from its own ip, the client in xff
  ingressIp = net.ipOf net.zones.external.ingress;
  # hermes reads format=json directly, past the 4 per hour api cap
  hermesIp = inventory.${lab.roles.operator}.ip;

  stateDir = "/var/lib/searxng";
  secret = "${stateDir}/secret";
  # under the unit's RuntimeDirectory: the rendered secret never lands on disk
  configDir = "/run/searxng/config";

  settings = (pkgs.formats.yaml { }).generate "searxng-settings.yml" {
    use_default_settings = true;
    general.donation_url = false;
    server = {
      secret_key = "@SECRET@";
      base_url = "https://${route.host}.${site.domain}/";
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
      formats = [
        "html"
        "json"
      ];
    };
    outgoing = {
      # a page waits for its slowest engine; every working engine answers under 1.2 s at p95 through the tunnel
      request_timeout = 2.0;
      # the cap on an engine's own longer timeout (wttr asks 9 s, gentoo 10 s)
      max_request_timeout = 6.0;
    };
    # off: google html and qwant (403 on this exit), mojeek (altcha captcha, answers nothing), google cse stands in
    engines = [
      {
        name = "bing";
        disabled = false;
      }
      # google's ranking through its anubis solver: bing and duckduckgo web both rank bing's index, so it counts double
      {
        name = "startpage";
        inactive = false;
        disabled = false;
        weight = 2;
      }
      # the html endpoint refuses curl_cffi's chrome tls with a 403; duckduckgo web speaks firefox tls and answers
      {
        name = "duckduckgo";
        disabled = true;
      }
      {
        name = "duckduckgo web";
        disabled = false;
      }
      # a proof-of-work captcha on this exit: every end of its suspension cost one search the full timeout
      {
        name = "brave";
        disabled = true;
      }
      {
        name = "brave.images";
        disabled = true;
      }
      {
        name = "brave.videos";
        disabled = true;
      }
      {
        name = "brave.news";
        disabled = true;
      }
      # infobox only and 429'd on this exit every wake; wikidata's infobox stands in, the web engines still rank articles
      # (a query wikidata misses shows no infobox)
      {
        name = "wikipedia";
        disabled = true;
      }
      # the infobox when sparql answers in time; it misses a few queries in ten, and a page it holds ends about 0.5 s
      # after its timeout (2.0 s at 1.5), so 1.0 keeps that page near 1.5 s
      {
        name = "wikidata";
        timeout = 1.0;
      }
      {
        name = "nixos wiki";
        disabled = false;
      }
      {
        name = "duden";
        disabled = false;
      }
      # onion engines need a tor proxy, they fail to load on every start
      {
        name = "ahmia";
        inactive = true;
      }
      {
        name = "torch";
        inactive = true;
      }
    ];
    hostnames = {
      high_priority = [
        "(.*\\.)?wikipedia\\.org$"
        "wiki\\.archlinux\\.org$"
        "wiki\\.nixos\\.org$"
        "(.*\\.)?github\\.com$"
        "(.*\\.)?stackoverflow\\.com$"
      ];
      remove = [ "(.*\\.)?pinterest\\.[a-z.]+$" ];
    };
  };

  limiter = (pkgs.formats.toml { }).generate "searxng-limiter.toml" {
    botdetection = {
      # without the ingress here every client is its ip and shares one quota
      trusted_proxies = [
        "127.0.0.0/8"
        "::1"
        "${ingressIp}/32"
      ];
      ip_limit.link_token = true;
      ip_lists = {
        pass_ip = [ "${hermesIp}/32" ];
        # not listed on searx.space
        pass_searxng_org = false;
      };
    };
  };

  units = [
    "podman-searxng.service"
    "podman-searxng-valkey.service"
  ];
  # an unprivileged lxc maps no full uid range, so root's podman takes itself for rootless and keeps its netns under
  # the runtime dir; /run/user/0 is the ssh session's, whose logout wiped them and failed the next stop (status 125)
  podmanRuntimeDir = "/run/podman-runtime";
in
{
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

  systemd.services.podman-searxng.environment.XDG_RUNTIME_DIR = podmanRuntimeDir;
  systemd.services.podman-searxng-valkey.environment.XDG_RUNTIME_DIR = podmanRuntimeDir;
  systemd.services.podman-searxng.path = [ pkgs.iptables ];

  # rendered every start; only the secret key is state, so no nas share
  systemd.services.podman-searxng.preStart = ''
    # a container whose teardown failed leaves its port's dnat ahead of the next one's (the network's dn chain): nothing
    # publishes on this network now, so its jumps and dn chains go
    jumps=$(iptables-save -t nat | grep -F -- '--comment "dnat name: ${network} id: ' || true)
    {
      echo '*nat'
      sed -n 's/^-A /-D /p' <<< "$jumps"
      sed -n 's/.* -j \(NETAVARK-DN-[0-9A-F]*\)$/-F \1/p' <<< "$jumps" | sort -u
      echo COMMIT
    } | iptables-restore --noflush
    # generated here, a literal would be public in this repo
    [ -s ${secret} ] || (umask 077; head -c 32 /dev/urandom | base64 | tr -d '/+=' > ${secret})
    install -d -m 0700 -o ${searxngUid} -g ${searxngUid} ${configDir}
    (umask 077; sed "s|@SECRET@|$(cat ${secret})|" ${settings} > ${configDir}/settings.yml)
    install -m 0400 ${limiter} ${configDir}/limiter.toml
    chown ${searxngUid}:${searxngUid} ${configDir}/settings.yml ${configDir}/limiter.toml
  '';

  virtualisation.oci-containers.containers = {
    searxng-valkey = {
      image = "docker.io/valkey/valkey:9.1.2-alpine@sha256:48332870af354a799964c0012ae1194a0bf2bf894eb508f945810596dc2d8d11";
      networks = [ network ];
      user = valkeyUser;
      # limiter counters only: a restart just resets every client's window
      cmd = [
        "valkey-server"
        # reachable only from the searxng network, nothing publishes it
        "--bind"
        "0.0.0.0"
        "--protected-mode"
        "no"
        "--port"
        valkeyPort
        "--save"
        ""
        "--appendonly"
        "no"
        "--maxmemory"
        valkeyMaxMemory
        "--maxmemory-policy"
        "allkeys-lru"
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
      image = "docker.io/searxng/searxng:2026.9.16-461f174b0@sha256:a31763b7af3caf6ae9aac1816ba774214eb550252e06a4998f276ded8d60461b";
      # pings valkey once at start and exits without it (public_instance)
      dependsOn = [ "searxng-valkey" ];
      networks = [ network ];
      ports = [ "${toString route.port}:${searxngPort}" ];
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
    "d ${podmanRuntimeDir} 0700 root root -"
    "d ${stateDir} 0700 root root -"
    # the old rendered config, secret included; it renders to /run now
    "r ${stateDir}/settings.yml - - - - -"
  ];
}
