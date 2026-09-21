{ config, lib, nasMount, ... }:
let
  routes = (import ../modules/routes.nix).internal;
  address = config.homelab.onDemand.address;

  # SSO gateway guarding the protected routes. Authelia (vm-101) serves both
  # ForwardAuth (this middleware) and OIDC (Forgejo/Nextcloud/Vaultwarden).
  sso = "authelia";
in {
  networking.hostName = "vm-100";

  # every backend goes through homelab.onDemand: VMs with enabled = "onDemand"
  # in instances.tf get a wake proxy on this host, the rest are reached directly.
  sops.secrets.proxmox-api-token = {};
  homelab.onDemand = {
    enable = true;
    side = "internal";
    tokenFile = config.sops.secrets.proxmox-api-token.path;
    # one local proxy port per route (20000 + position), since routes can share a VM.
    services = lib.listToAttrs (lib.imap0 (i: name: lib.nameValuePair name {
      inherit (routes.${name}) vmid;
      targetPort = routes.${name}.port;
      listenPort = 20000 + i;
    }) (lib.attrNames routes));
  };

  fileSystems = (nasMount "/var/lib/crowdsec" "crowdsec-internal")
    // (nasMount "/var/lib/traefik/acme" "traefik-acme-internal");

  homelab.traefik = {
    enable = true;

    middlewares.authelia = {
      forwardAuth = {
        address = "http://10.100.0.101:9091/api/authz/forward-auth";
        trustForwardHeader = true;
        authResponseHeaders = [
          "Remote-User"
          "Remote-Groups"
          "Remote-Email"
          "Remote-Name"
        ];
      };
    };

    # auth = "sso" gets Authelia ForwardAuth; "own", "token" and "portal" carry
    # their own authentication (see the header of modules/routes.nix).
    routers = lib.mapAttrs' (name: r: lib.nameValuePair "${name}-tls" ({
      rule = "Host(`${r.host}.lsck0.dev`)";
      service = name;
      entryPoints = [ "websecure" ];
    } // lib.optionalAttrs ((r.auth or "sso") == "sso") { middlewares = [ sso ]; })) routes // {
      traefik-dash-tls = { rule = "Host(`traefik.lsck0.dev`)";  service = "api@internal"; entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
      proxmox-tls      = { rule = "Host(`proxmox.lsck0.dev`)";  service = "proxmox";      entryPoints = [ "websecure" ]; middlewares = [ sso ]; };
    };

    services = lib.mapAttrs (name: r: {
      loadBalancer = {
        servers = [{ url = "${r.scheme or "http"}://${address.${name}}"; }];
      } // lib.optionalAttrs ((r.scheme or "http") == "https") { serversTransport = "self-signed"; };
    }) routes // {
      proxmox.loadBalancer = {
        servers = [{ url = "https://192.168.178.200:8006"; }];
        serversTransport = "self-signed";
      };
    };

    serversTransports.self-signed.insecureSkipVerify = true;
  };
}
