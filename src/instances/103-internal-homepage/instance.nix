# dashboard / service landing page
{ ... }: {
  vm = {
    bootPhase = "apps";
    needs = [ "containers" "nfs" ];
    kind.lxc = "pending migration, see the restructure report";
    # nfs mounts need a privileged container
    privileged = true;
    features = "nesting=1,mount=nfs";
  };

  services = {
    homepage = { host = "homelab"; port = 80; guest = true; off = { homepage = "the dashboard itself"; }; };
  };

  secrets = {
    proxmox-user = "public"; # init.sh: homepage@pve!homepage
    proxmox-pass = "manual"; # init.sh: the homepage api token
  };
}
