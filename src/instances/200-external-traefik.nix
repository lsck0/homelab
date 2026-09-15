{ config, lib, pkgs, nasMount, ... }:
let
  # On-demand Minecraft: vm-207 holds 20 GB of RAM to sit idle most of the day.
  # With this on, Traefik forwards to a local socket-activated proxy that boots
  # the VM on the first connection and shuts it down 30 minutes after the last
  # player leaves.
  #
  # Before flipping this to true:
  #   1. Create a Proxmox API token with VM.PowerMgmt and VM.Audit on vm-207.
  #   2. Add it to src/secrets.json as proxmox-api-token, formatted
  #      USER@REALM!TOKENID=SECRET (`sops src/secrets.json`).
  #
  # A Minecraft client gives up well before a cold VM finishes booting, so the
  # first join attempt after an idle period times out and has to be retried.
  minecraftOnDemand = false;

  minecraftBackend =
    if minecraftOnDemand then "127.0.0.1:26565" else "10.200.0.207:25565";
in
{
  networking.hostName = "vm-200";

  sops.secrets = lib.optionalAttrs minecraftOnDemand { proxmox-api-token = {}; };

  homelab.onDemand = lib.optionalAttrs minecraftOnDemand {
    enable = true;
    tokenFile = config.sops.secrets.proxmox-api-token.path;
    services.minecraft = {
      vmid = 207;
      listenPort = 26565;
      target = "10.200.0.207";
      targetPort = 25565;
      idleTimeout = "30m";
      # Proxmox boot plus a modded Minecraft server start.
      bootTimeout = 300;
    };
  };

  fileSystems = (nasMount "/var/lib/crowdsec" "crowdsec-external")
    // (nasMount "/var/lib/traefik/acme" "traefik-acme-external");

  homelab.traefik = {
    enable = true;

    entryPoints.minecraft.address = ":25565";

    routers = {
      headscale-tls    = { rule = "Host(`hs.lsck0.dev`)";          service = "headscale";    entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      searxng-tls      = { rule = "Host(`search.lsck0.dev`)";      service = "searxng";      entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      shlink-tls       = { rule = "Host(`shlink.lsck0.dev`)";      service = "shlink";       entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      privatebin-tls   = { rule = "Host(`paste.lsck0.dev`)";       service = "privatebin";   entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      share-tls        = { rule = "Host(`share.lsck0.dev`)";       service = "share";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      hello-tls        = { rule = "Host(`hello.lsck0.dev`)";       service = "hello";        entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
      # The calendar lives on the internal side; only this one host is relayed
      # through, so the TRMNL cloud can poll it without the DMZ reaching in.
      calendar-tls     = { rule = "Host(`cal.lsck0.dev`)";         service = "calendar";     entryPoints = [ "websecure" ]; tls.certResolver = "cloudflare"; };
    };

    services = {
      headscale.loadBalancer.servers    = [{ url = "http://10.200.0.201:80"; }];
      searxng.loadBalancer.servers      = [{ url = "http://10.200.0.202:80"; }];
      shlink.loadBalancer.servers       = [{ url = "http://10.200.0.203:80"; }];
      privatebin.loadBalancer.servers   = [{ url = "http://10.200.0.204:80"; }];
      share.loadBalancer.servers        = [{ url = "http://10.200.0.205:80"; }];
      hello.loadBalancer.servers        = [{ url = "http://10.200.0.208:80"; }];
      calendar.loadBalancer.servers     = [{ url = "https://10.100.0.100:443"; }];
      calendar.loadBalancer.serversTransport = "internal-traefik";
    };

    # Traefik takes SNI from the server URL, which is an IP here, so the
    # internal instance has to be told which certificate to present.
    serversTransports.internal-traefik.serverName = "cal.lsck0.dev";

    tcp = {
      routers.minecraft = {
        rule = "HostSNI(`*`)";
        service = "minecraft";
        entryPoints = [ "minecraft" ];
      };
      services.minecraft.loadBalancer.servers = [{ address = minecraftBackend; }];
    };
  };

  networking.firewall.allowedTCPPorts = [ 25565 ];
}
