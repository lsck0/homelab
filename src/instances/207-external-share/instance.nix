# public file sharing
{ ... }: {
  vm = {
    bootPhase = "public";
    needs = [ "containers" "nfs" ];
    memoryMiB = 1024;
  };

  idle = { stopAfter = "30m"; };

  services = {
    share = {
      port = 80;
      homepage = { group = "Public"; icon = "pingvin-share"; };
      off = { sso = "public file sharing"; cloudflare = "anubis fronts it at the edge"; bodyLimit = "file uploads"; };
    };
  };
}
