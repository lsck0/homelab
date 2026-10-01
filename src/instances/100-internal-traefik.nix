{ config, lib, nasMount, site, ... }:
let
  routes = (import ../modules/routes.nix).internal;
  address = config.homelab.onDemand.address;

  # sso gateway for protected routes
  sso = "authelia";
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
    }) (lib.attrNames routes))) {
      # nightly package build, kept up while it runs
      archbuild = { busyPath = "/busy"; wakeAt = "03:00"; };
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

    middlewares = {
      # auth = "token" routes have no own gate
      registry-clients.ipAllowList.sourceRange = [
        "10.100.0.115/32"   # forgejo runner, pushes
        "10.100.0.117/32"   # github runner, pushes
        "10.200.0.209/32"   # swarm host, pulls
        "${site.lan.workstation}/32"  # the workstation, for manual inspection
      ];

      authelia.forwardAuth = {
        address = "http://10.100.0.101:9091/api/authz/forward-auth";
        trustForwardHeader = true;
        authResponseHeaders = [
          "Remote-User"
          "Remote-Groups"
          "Remote-Email"
          "Remote-Name"
        ];
      };
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
      rule = "Host(`${r.host}.lsck0.dev`)";
      service = name;
      entryPoints = [ "websecure" ];
    } // lib.optionalAttrs ((r.auth or "sso") == "sso" || r ? loginRedirect || name == "registry-api") {
      middlewares = lib.optional ((r.auth or "sso") == "sso") sso
        ++ lib.optional (r ? loginRedirect) "${name}-login"
        ++ lib.optional (name == "registry-api") "registry-clients";
    })) routes // {
      traefik-dash-tls = { rule = "Host(`traefik.lsck0.dev`)";  service = "api@internal"; entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      proxmox-tls      = { rule = "Host(`proxmox.lsck0.dev`)";  service = "proxmox";      entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
    };

    services = lib.mapAttrs (name: r: {
      loadBalancer.servers = [{ url = "http://${address.${name}}"; }];
    }) routes // {
      proxmox.loadBalancer = {
        servers = [{ url = "https://${site.lan.proxmox}:8006"; }];
        serversTransport = "self-signed";
      };
    };

    serversTransports.self-signed.insecureSkipVerify = true;
  };
}
