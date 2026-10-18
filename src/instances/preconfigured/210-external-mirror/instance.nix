# public lsck0 pacman mirror; vm (nfs is internal, dmz gets an ssh push instead)
{ lib, profiles, ... }: {
  vm = {
    bootPhase = "dev";
    # the packages (31G, growing), archrepo-build.nu's three hardlinked snapshots (newest, week start, month start) and
    # a full rebuild's 7.6G in one night
    diskGiB = 96;
  };

  services = {
    mirror = {
      port = 80;
      # a read-only file server: pacman only fetches
      methods = [ "GET" "HEAD" ];
      # a pacman sync fetches hundreds of packages back to back: the default burst cut it off every ~100 files
      limitScale = 20;
      # the internet gets the owner's own builds alone (archrepo-build.nu's internet tree), the house the full snapshot
      publicPrefix = "/public";
      homepage = {
        group = "Dev";
        icon = "arch-linux";
        name = "Arch Mirror";
        widget = {
          path = "/status.json";
          settings = { mappings = [ { field = "packages"; label = "Packages"; } { field = "failing"; label = "Failing"; } ]; };
          type = "customapi";
        };
      };
      # pacman, public and signed: the house fetches straight from here (arch-dotfiles pacman.conf), large binaries
      # past the proxy, with no proof of work or captcha; crs rule 920440 refuses the repo database lsck0.db. The
      # house syncs at the full speed of its network, past every limit
      on = lib.subtractLists [ "anubis" "captcha" "cloudflare" "guard" "waf" ] profiles.hardenedExternal
        ++ profiles.listed ++ profiles.observed ++ [ "houseUnlimited" ];
    };
  };
}
