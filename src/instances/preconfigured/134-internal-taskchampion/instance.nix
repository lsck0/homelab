# taskwarrior 3 sync server (taskchampion), at tasks.lsck0.dev for the owner's desktop and notebook
{
  lib,
  id,
  profiles,
  ...
}:
{
  vm = {
    # parked so atm gets its 8 GiB unballooned; "on" brings it back
    power = "off";
    bootPhase = "apps";
    # its sqlite on the guest's disk, mirrored to the nas (localState), and the nightly dump
    needs = [ "nfs" ];
  };

  services = {
    taskchampion = {
      host = "tasks";
      port = 10222;
      # taskwarrior clients from the house and wireguard, no browser: no portal, no internet name, encrypted history
      # segments the waf rules misread, snapshots past the body limit, a catch-up of many versions past the rate limit
      on =
        lib.subtractLists [ "sso" "internet" "cloudflare" "waf" "captcha" "bodyLimit" ] profiles.hardenedInternal
        ++ [
          "houseUnlimited"
          "probe"
        ]
        ++ profiles.observed;
    };
  };

  # the one client id both machines sync as; the server refuses every other (main.nix)
  secrets = {
    taskchampion-client-id = "dotfiles:taskwarrior-client-id";
  };

  shares = {
    "data/db-dumps/vm-${id}" = {
      mode = "0700";
    };
    "data/taskchampion".localState = true;
  };
}
