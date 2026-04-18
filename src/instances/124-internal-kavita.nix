{ ... }: {
  networking.hostName = "vm-124";

  fileSystems."/srv/manga" = {
    device = "10.100.0.110:/srv/nas/media/manga";
    fsType = "nfs";
    options = [ "nfsvers=4" "rw" "soft" "timeo=15" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
  };

  virtualisation.oci-containers.containers.kavita = {
    image = "jvmilazz0/kavita:latest";
    ports = [ "80:5000" ];
    volumes = [
      "/var/lib/kavita:/kavita/config"
      "/srv/manga:/manga:ro"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/kavita 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
