# public lsck0 pacman mirror; vm (nfs is internal, dmz gets an ssh push instead)
{ ... }: {
  vm = {
    bootPhase = "dev";
    # the packages (30G, growing) plus archrepo-build.sh's hardlinked daily snapshots (~1G each, SNAPSHOT_KEEP_DAYS)
    diskGiB = 64;
  };

  services = {
    mirror = {
      port = 80;
      # a read-only file server: pacman only fetches
      methods = [ "GET" "HEAD" ];
      # a pacman sync fetches hundreds of packages back to back: the default burst cut it off every ~100 files
      limitScale = 20;
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
      off = {
        guard = "the house's pacman fetches straight from here (arch-dotfiles pacman.conf); public and signed";
        sso = "public pacman mirror";
        anubis = "pacman clients run no proof of work";
        captcha = "pacman solves no captcha";
        cloudflare = "pacman pulls large binaries, not through the proxy";
        waf = "crs rule 920440 refuses the .db extension, and the repo database is lsck0.db";
      };
    };
  };
}
