# a flake host evaluated over another collected lab (modules/lab withApps: a test's fixture apps): every fact the
# flake hands a host follows it, the catalog with them (modules/base)
#
#   hostWith = import ../../../tests/lib/host-with.nix { inherit inputs; };
#   grafana = hostWith (specialArgs.lab.withApps (apps: apps // { wat = apps.wat // { enable = true; }; })) "105-internal-grafana";
{ inputs }:
lab: host: (inputs.self.nixosConfigurations.${host}.extendModules {
  specialArgs = { inherit lab; inherit (lab) inventory site nasClients; instance = lab.hosts.${host}; };
}).config
