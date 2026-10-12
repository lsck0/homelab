# what the guest is for, in one line
#
# Copy this folder to src/instances/preconfigured/<vmid>-<zone>-<service>/ (src/core/ when the lab needs it to
# function): the vmid inside the zone's range (src/generated/zones.json `vmids`), the zone internal or external.
# Everything below is optional and defaulted (modules/instance-schema.nix, modules/service.nix): a service is exposed
# at <name>.<domain> by its zone's ingress with every protection and telemetry feature on; turn one off with
# `off.<feature> = "<why>";`. A public service (`off.sso`) of the internal zone keeps prefixes of itself behind
# authelia, `ssoPaths = [ "/metrics" "/admin" ];`, for admins and its own group; the rest stays open, and the
# collector scrapes its `metrics` at the backend port, never through the ingress.
{ ... }: {
  vm.bootPhase = "apps";

  # its internet traffic through the router's vpn exit or tor, with a killswitch; lab traffic stays direct
  # egress.via = "tor";

  services.demo = {
    port = 80;
    homepage.icon = "mdi-web";
  };
}
