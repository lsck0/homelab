# what the guest is for, in one line
#
# Copy this folder to src/instances/<vmid>-<zone>-<service>/: the vmid inside the zone's range (src/generated/zones.json
# `vmids`), the zone internal or external. Everything below is optional and defaulted (modules/instance-schema.nix,
# modules/service.nix): a service is exposed at <name>.<domain> by its zone's ingress with every protection and
# telemetry feature on; turn one off with `off.<feature> = "<why>";`.
{ ... }: {
  vm.bootPhase = "apps";

  services.demo = {
    port = 80;
    homepage.icon = "mdi-web";
  };
}
