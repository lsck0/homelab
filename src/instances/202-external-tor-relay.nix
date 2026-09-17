{ config, pkgs, nasMount, ... }:
let
  orPort = 9001;
  keyBackup = "/var/lib/tor-keys";
in {
  networking.hostName = "vm-202";

  # identity keys live on the VM disk, which a VM recreate throws away. Back them
  # up to the NAS so a rebuilt relay keeps its fingerprint and its earned flags.
  fileSystems = nasMount keyBackup "tor-relay-keys";

  # non-exit middle relay. role = "relay" forces ExitPolicy to reject *:*,
  # so this node never carries traffic out to the open internet.
  services.tor = {
    enable = true;
    openFirewall = true;
    relay = {
      enable = true;
      role = "relay";
    };
    # A relay should not also route local application traffic.
    client.enable = false;

    settings = {
      Nickname = "lsck0relay";
      ORPort = [{ addr = "0.0.0.0"; port = orPort; }];
      # the relay sits behind NAT and sees only its DMZ address, so it cannot
      # guess its public IP. Point it at the DDNS record the router keeps
      # current (unproxied A record, Cloudflare must not hide the real IP).
      Address = "tor.lsck0.dev";
      # published in the public consensus and scraped by spammers.
      ContactInfo = config.homelab.acmeEmail;
      # cap throughput so the relay cannot saturate the home uplink.
      RelayBandwidthRate = "2 MBytes";
      RelayBandwidthBurst = "4 MBytes";
      # hibernate once the monthly volume budget is spent.
      AccountingMax = "500 GBytes";
      AccountingStart = "month 1 00:00";
    };
  };

  systemd.services.tor-key-restore = {
    description = "Restore Tor relay identity keys from NAS";
    before = [ "tor.service" ];
    requiredBy = [ "tor.service" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # only restore into a relay that has no identity yet, so a running
      # relay's live keys are never overwritten by a stale backup.
      [ -d /var/lib/tor/keys ] && exit 0
      [ -d ${keyBackup}/keys ] || exit 0
      mkdir -p /var/lib/tor
      cp -a ${keyBackup}/keys /var/lib/tor/keys
      chown -R tor:tor /var/lib/tor/keys
      chmod 700 /var/lib/tor/keys
    '';
  };

  systemd.services.tor-key-backup = {
    description = "Back up Tor relay identity keys to NAS";
    path = [ pkgs.coreutils pkgs.rsync ];
    serviceConfig = { Type = "oneshot"; };
    script = ''
      [ -d /var/lib/tor/keys ] || exit 0
      rsync -a --delete /var/lib/tor/keys/ ${keyBackup}/keys/
    '';
  };

  systemd.timers.tor-key-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "1d";
      Persistent = true;
    };
  };
}
