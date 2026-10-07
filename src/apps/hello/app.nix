# the ci demo: lib/ here, a c http server
let
  dir = "src/apps/hello";
  silent = "a static c server sends none";
in
{
  enable = true;
  repo = "lsck0/homelab";
  branch = "master";
  build.web = { context = "${dir}/lib"; dockerfile = "${dir}/lib/Dockerfile"; };
  # this repo moves with every sync; hello only with its own folder
  watch = [ dir ];
  # main.c's port
  routes.hello = { service = "web"; targetPort = 8000; port = 20100; off.sso = "the public demo"; };
  homepage = { name = "Hello"; icon = "mdi-hand-wave"; };
  off = { traces = silent; profiles = silent; };
}
