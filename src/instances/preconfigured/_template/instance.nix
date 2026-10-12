# what the guest is for, in one line
#
# Copy this folder to src/instances/preconfigured/<vmid>-<zone>-<service>/ (src/core/ when the lab needs it to
# function): the vmid inside the zone's range (src/generated/zones.json `vmids`), the zone internal or external.
# Everything below is optional and defaulted (modules/instance-schema.nix, modules/service.nix): a service is a plain
# route at <name>.<domain> through its zone's ingress to its port, nothing more; it opts into every protection and
# telemetry feature by name, usually as lists of modules/profiles.nix. A service of the internal zone without sso keeps
# prefixes of itself behind authelia, `ssoPaths = [ "/metrics" "/admin" ];`, for admins and its own group; the rest
# stays open, and the collector scrapes its `metrics` at the backend port, never through the ingress. The guest's
# firewall opens ssh, node-exporter and its services' ports; main.nix opens anything else itself.
{ ... }: {
  vm.bootPhase = "apps";

  # its internet traffic through the router's vpn exit or tor, with a killswitch; lab traffic stays direct
  # on = profiles.torEgress;

  services.demo.port = 80;
  # behind authelia, defended, on the dashboard, observed
  # services.demo.on = profiles.hardenedInternal ++ profiles.listed ++ profiles.observed;
  # protection per path: /api rate limited, the rest of the host plain
  # services.demo-api = { host = "demo"; path = "/api"; port = 80; on = [ "rateLimit" ]; };
}
