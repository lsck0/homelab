# build caches: attic (nix) + sccache redis
{ net, ... }: {
  vm = {
    bootPhase = "dev";
    # 63 MiB peak over 7d; redis caps itself at 256mb
    memoryMiB = 512;
    diskGiB = 40;
  };

  grants = [
    { from = [ "105" ]; tcp = [ net.ports.redis ]; why = "vm-105's blackbox check of sccache's redis"; }
  ];

  services = {
    attic = {
      port = 8080;
      off = {
        guard = "every lab host substitutes from it directly";
        sso = "nix clients use attic tokens";
        anubis = "nix clients run no proof of work";
        waf = "nar uploads the rules misread";
        internet = "only the lab's nix clients";
        homepage = "no web ui";
        bodyLimit = "nar uploads";
      };
    };
  };

  secrets = { attic-server-token = "manual"; };
}
