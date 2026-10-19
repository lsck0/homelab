# nyangine's examples/web_server: one scratch image, the notes server
{ profiles, ... }:
{
  enable = false;
  repo = "lsck0/nyangine";
  branch = "master";
  stack = "examples/web_server/deploy/stack.yaml";
  build.web = {
    context = ".";
    dockerfile = "examples/web_server/Dockerfile";
  };
  routes.nyangine = {
    service = "web";
    targetPort = 8000;
    port = 20110;
    on = profiles.hardenedExternal ++ [ "probe" ];
  };
  stateful = [ "web" ];
  # the notes
  volumes.web_server_data.backup = true;
  env.web.WEB_SERVER_ORIGIN = "{{homelab.origin-nyangine}}";
  # scales to zero: the notes are read and written per request, the volume is archived asleep as awake
  on = profiles.observed ++ [
    "frontend"
    "homepage"
    "scaleToZero"
  ];
}
