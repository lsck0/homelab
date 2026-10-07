# nyangine's examples/web_server: one scratch image, the notes server
let
  silent = "the example server sends none";
in
{
  enable = false;
  repo = "lsck0/nyangine";
  branch = "master";
  stack = "examples/web_server/deploy/stack.yaml";
  build.web = { context = "."; dockerfile = "examples/web_server/Dockerfile"; };
  routes.nyangine = { service = "web"; targetPort = 8000; port = 20110; off.sso = "the public notes server"; };
  stateful = [ "web" ];
  # the notes
  volumes.web_server_data.backup = true;
  env.web.WEB_SERVER_ORIGIN = "https://nyangine.lsck0.dev";
  off = { traces = silent; profiles = silent; };
}
