{ config, lib, pkgs, nasMount, inventory, site, ... }:
let
  catalog = import ../modules/catalog.nix { inherit inventory lib; };
  routes = catalog.internal;
  # nixos services wake on demand; swarm apps run on every apps node
  vmRoutes = lib.filterAttrs (_: r: r ? vmid) routes;
  appRoutes = lib.filterAttrs (_: r: r ? app) routes;
  address = config.homelab.onDemand.address;

  # sso gateway for protected routes
  sso = "authelia";

  # push credentials: `ci` is a repo secret on github and forgejo that no runner holds and no fork sees;
  # `builder` belongs to the app builder alone, so a ci job that reads ci's secret still cannot push as it
  registryPushUsers = { ci = "registry-push-password"; builder = "registry-builder-password"; };
  registryHtpasswd = "/run/registry-auth/htpasswd";
  registryHost = "${routes.registry-api.host}.lsck0.dev";
  # by socket address, not forwarded headers: the ci vm and the workstation
  registryPushers = [ "10.100.0.117" site.lan.workstation ];
  # the swarm pulls without a credential, and only pulls: the workers run images, the manager resolves digests
  registryPullers = map (ip: "${ip}/32") (catalog.nodes ++ [ catalog.manager.ip ]);
  # the apps zone is a dmz: its registry pulls are the one route here it may use
  appsZone = let w = inventory.${toString (lib.head (lib.attrNames (lib.filterAttrs (_: v: v.type == "apps") inventory)))}; in
    "${lib.concatStringsSep "." (lib.take 3 (lib.splitString "." w.ip))}.0/${toString w.prefix}";
  notFromApps = rule: "(${rule}) && !ClientIP(`${appsZone}`)";
in {
  networking.hostName = "vm-100";

  # backends wake via homelab.onDemand
  # wake@pve!ondemand: vm status, start, shutdown only, not the terraform admin token
  sops.secrets.proxmox-wake-token = {};
  homelab.onDemand = {
    enable = true;
    side = "internal";
    tokenFile = config.sops.secrets.proxmox-wake-token.path;
    # port 20000 + index, routes can share a vm
    services = lib.recursiveUpdate (lib.listToAttrs (lib.imap0 (i: name: lib.nameValuePair name {
      inherit (routes.${name}) vmid;
      targetPort = routes.${name}.port;
      listenPort = 20000 + i;
    }) (lib.attrNames vmRoutes))) {
      # nightly package build, kept up while it runs
      archbuild = { busyPath = "/busy"; wakeAt = "03:00"; };
      # daily bank import (124-internal-firefly.nix, 05:00)
      firefly = { wakeAt = "05:00"; };
    };
  };

  fileSystems = (nasMount "/var/lib/crowdsec" "crowdsec-internal")
    // (nasMount "/var/lib/traefik/acme" "traefik-acme-internal");

  homelab.traefik = {
    enable = true;

    # sso login runs in a same-origin iframe
    sameOriginFrameRouters = [ "jellyfin-tls" ];
    # vm-200 relays external hosts here; keep the client address it saw, not the relay
    trustedProxies = [ "10.200.0.200/32" ];

    authelia.address = "http://10.100.0.101:9091/api/authz/forward-auth";

    # the edge's defence here too, for lan clients and relayed ones alike; relayed clients keep their real ip
    crowdsecBouncer = {
      enable = true;
      appsec = true;
      # native clients and bulk transfers the owasp rules misread: tailscale, the hass app, nix and docker pushes, git
      noAppsecRouters = [ "headscale-tls" "homeassistant-tls" "attic-tls" "registry-api-tls" "registry-push-tls" "forgejo-tls" ];
      # never ban the house or the lab; internet clients arrive relayed with their own address
      whitelistCidrs = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" ];
    };
    # robots.txt, llms.txt and the labyrinth, as on the edge
    botDefense.enable = true;

    middlewares = {
      registry-pullers.ipAllowList.sourceRange = registryPullers;
      registry-auth.basicAuth = { usersFile = registryHtpasswd; realm = "registry"; removeHeader = true; };
    }
    # redirect the app's login page to authelia, whatever query it carries (?redirect_to= still served the form)
    // lib.mapAttrs' (name: r: lib.nameValuePair "${name}-login" {
      redirectRegex = {
        regex = "^https://${r.host}\\.lsck0\\.dev${lib.escapeRegex r.loginRedirect.path}(\\?.*)?$";
        replacement = "https://${r.host}.lsck0.dev${r.loginRedirect.to}";
      };
    }) (lib.filterAttrs (_: r: r ? loginRedirect) routes);

    # "sso" gets forwardauth, "own" does not
    routers = lib.mapAttrs' (name: r: lib.nameValuePair "${name}-tls" ({
      rule = notFromApps "Host(`${r.host}.lsck0.dev`)";
      service = name;
      entryPoints = [ "websecure" ];
    } // lib.optionalAttrs ((r.auth or "sso") == "sso" || r ? loginRedirect) {
      middlewares = lib.optional ((r.auth or "sso") == "sso") sso
        ++ lib.optional (r ? loginRedirect) "${name}-login";
    })) (removeAttrs routes [ "registry-api" ]) // {
      # read-only for the swarm hosts
      registry-api-tls = {
        rule = "Host(`${registryHost}`) && (Method(`GET`) || Method(`HEAD`))";
        service = "registry-api";
        entryPoints = [ "websecure" ];
        middlewares = [ "registry-pullers" ];
      };
      # every request a pusher makes needs the credential, so docker's first ping already gets the challenge
      registry-push-tls = {
        rule = notFromApps "Host(`${registryHost}`) && (${lib.concatMapStringsSep " || " (ip: "ClientIP(`${ip}`)") registryPushers})";
        service = "registry-api";
        entryPoints = [ "websecure" ];
        priority = 1000;
        middlewares = [ "registry-auth" ];
      };

      traefik-dash-tls = { rule = notFromApps "Host(`traefik.lsck0.dev`)"; service = "api@internal"; entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      proxmox-tls      = { rule = notFromApps "Host(`proxmox.lsck0.dev`)"; service = "proxmox";      entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
    };

    services = lib.mapAttrs (name: r: {
      loadBalancer.servers = [{ url = "http://${address.${name}}"; }];
    }) vmRoutes // lib.mapAttrs (name: r: {
      loadBalancer = {
        servers = map (ip: { url = "http://${ip}:${toString r.port}"; }) r.nodes;
      } // lib.optionalAttrs (r.health != null) {
        healthCheck = { path = r.health; interval = "10s"; timeout = "3s"; };
      };
    }) appRoutes // {
      proxmox.loadBalancer = {
        servers = [{ url = "https://${site.lan.proxmox}:8006"; }];
        serversTransport = "self-signed";
      };
    };

    serversTransports.self-signed.insecureSkipVerify = true;
  };

  sops.secrets.registry-push-password.restartUnits = [ "registry-htpasswd.service" "traefik.service" ];
  sops.secrets.registry-builder-password.restartUnits = [ "registry-htpasswd.service" "traefik.service" ];
  systemd.services.registry-htpasswd = {
    description = "Render the registry push credential for traefik";
    before = [ "traefik.service" ];
    requiredBy = [ "traefik.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = "registry-auth";
      RuntimeDirectoryMode = "0750";
      Group = "traefik";
    };
    # bcrypt from stdin: the password never reaches an argv
    script = ''
      umask 027
      : > ${registryHtpasswd}.tmp
      ${lib.concatStrings (lib.mapAttrsToList (user: secret: ''
        ${pkgs.apacheHttpd}/bin/htpasswd -niB ${user} < ${config.sops.secrets.${secret}.path} >> ${registryHtpasswd}.tmp
      '') registryPushUsers)}
      mv ${registryHtpasswd}.tmp ${registryHtpasswd}
    '';
  };
}
