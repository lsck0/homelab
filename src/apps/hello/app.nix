# the ci demo: lib/ here, a c http server
let
  dir = "src/apps/hello";
  silent = "a static c server sends none";
in
{
  enable = true;
  repo = "lsck0/homelab";
  branch = "master";
  build.web = {
    context = "${dir}/lib";
    dockerfile = "${dir}/lib/Dockerfile";
    # fetched by hash, not vendored (tests/hello.nix builds it the same way)
    args = {
      HTTPSERVER_URL = "https://raw.githubusercontent.com/jeremycw/httpserver.h/40a1680547abf50b52099ee5aa5ec3a6282c5084/httpserver.h";
      HTTPSERVER_SHA256 = "acbc80c54dd221caa103053ec38b59eed5606f2d5a81e4c6dfe38cdb9e8150e4";
    };
  };
  # this repo moves with every sync; hello only with its own folder
  watch = [ dir ];
  # main.c's port
  routes.hello = { service = "web"; targetPort = 8000; port = 20100; off.sso = "the public demo"; };
  homepage = { name = "Hello"; icon = "mdi-hand-wave"; };
  # one static c server
  resources.web.memoryMiB = 128;
  reservation.memoryMiB = 128;
  # scales to zero: a static page with no job of its own and no client holding a connection
  off = { traces = silent; profiles = silent; };
}
