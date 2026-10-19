# dashboard / service landing page
{ profiles, ... }:
{
  vm = {
    bootPhase = "apps";
    needs = [
      "containers"
      "nfs"
    ];
    # two homepage containers, 110 MB each, besides the system
    memoryMiB = 1024;
  };

  services = {
    # the dashboards themselves, no card on them: the admins' with the widgets, and the one everybody else opens
    homepage = {
      host = "homelab";
      port = 80;
      on = profiles.hardenedInternal ++ [ "probe" ] ++ profiles.observed;
    };
    start = {
      host = "start";
      port = 81;
      guest = true;
      on = profiles.hardenedInternal ++ [ "probe" ] ++ profiles.observed;
    };
  };

  secrets = {
    proxmox-user = "public"; # init.nu: homepage@pve!homepage
    proxmox-pass = "manual"; # init.nu: the homepage api token
  };

  # reads every widget's token (modules/lab)
  roles = [ "dashboard" ];
}
