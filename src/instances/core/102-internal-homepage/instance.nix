# dashboard / service landing page
{ profiles, ... }: {
  vm = {
    bootPhase = "apps";
    needs = [ "containers" "nfs" ];
    kind.lxc = "an existing lxc with local state; recreating it as a vm needs a data migration";
    # nfs mounts need a privileged container
    privileged = true;
    features = "nesting=1,mount=nfs";
  };

  services = {
    # the dashboard itself, no card on it
    homepage = { host = "homelab"; port = 80; guest = true; on = profiles.hardenedInternal ++ [ "probe" ] ++ profiles.observed; };
  };

  secrets = {
    proxmox-user = "public"; # init.nu: homepage@pve!homepage
    proxmox-pass = "manual"; # init.nu: the homepage api token
  };

  # reads every widget's token (modules/lab)
  roles = [ "dashboard" ];

  shares = {
    "data/homepage" = { };
  };
}
