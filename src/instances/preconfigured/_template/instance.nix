# what the guest is for, in one line
#
# copy to src/instances/preconfigured/<vmid>-<zone>-<service>/, the vmid in the zone's range (src/generated/zones.json
# `vmids`); fields and defaults: modules/instance-schema.nix, modules/service.nix, README.md "Adding an instance"
_: {
  vm.bootPhase = "apps";

  # its internet traffic through the router's vpn exit or tor, with a killswitch; lab traffic stays direct
  # on = profiles.torEgress;

  services.demo.port = 80;
  # behind authelia, defended, on the dashboard, observed
  # services.demo.on = profiles.hardenedInternal ++ profiles.listed ++ profiles.observed;
  # protection per path: /api rate limited, the rest of the host plain
  # services.demo-api = { host = "demo"; path = "/api"; port = 80; on = [ "rateLimit" ]; };
}
