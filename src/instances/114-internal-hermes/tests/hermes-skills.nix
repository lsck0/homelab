# hermes' skills, as vm-114 installs them, against the lab they describe: prose that restates the lab drifts, and
# this check (hermes_skills_test.py lists the rules) makes the drift a failing build
{ pkgs, lib, inputs, specialArgs, ... }:
let
  inherit (specialArgs) inventory site;
  net = import ../../../modules/net.nix { inherit lib inventory site; };
  configs = lib.mapAttrs (_: system: system.config) inputs.self.nixosConfigurations;
  hermes = configs."114-internal-hermes";
  routerName = "luca-router";

  # what a line run on each host may name
  hosts = lib.mapAttrsToList (_: config: {
    address = if config.networking.hostName == routerName then net.wan.address
      else (inventory.${lib.removePrefix "vm-" config.networking.hostName} or { ip = null; }).ip;
    name = config.networking.hostName;
    units = lib.attrNames config.systemd.services ++ map (t: "${t}.timer") (lib.attrNames config.systemd.timers);
    secrets = lib.attrNames config.sops.secrets;
    tools = lib.filter (lib.hasPrefix "lab-") (map lib.getName config.environment.systemPackages);
  }) configs;

  # <name>/SKILL.md, exactly the files hermes gets
  skillsPrefix = "skills/homelab/";
  skills = pkgs.linkFarm "hermes-skills-tree" (lib.mapAttrsToList
    (target: file: { name = lib.removePrefix skillsPrefix target; path = file; })
    (lib.filterAttrs (target: _: lib.hasPrefix skillsPrefix target) hermes.services.hermes-agent.hermesHomeFiles));

  facts = pkgs.writeText "hermes-skills-facts.json" (builtins.toJSON {
    inherit hosts;
    hermes = {
      address = inventory."114".ip;
      tools = map lib.getName (lib.filter (p: lib.hasPrefix "lab-" (lib.getName p) || lib.elem (lib.getName p) [ "pve" "vm" "mc" ])
        hermes.services.hermes-agent.extraPackages);
    };
    tokens = hermes.homelab.tokens.all;
    # the router answers ssh on its address in every zone too
    inherit routerName;
    routerAddresses = map (z: z.routerIp) (lib.attrValues net.zones);
    # "on vm-<id>" in prose
    vmAddresses = lib.mapAttrs (_: v: v.ip) inventory;
    # reachable over ssh, but no nixos host of this flake
    foreignHosts = [ site.lan.proxmox ];
    houseSubnet = net.wan.subnet;
    houseAddresses = lib.filter (v: builtins.match "[0-9.]+" v != null) (lib.attrValues site.lan);
    subnets = map (z: z.subnet) (lib.attrValues net.zones) ++ [ net.wireguard.subnet net.wan.subnet ];
  });
in
pkgs.runCommand "hermes-skills" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${./hermes_skills_test.py} ${facts} ${skills}
  touch $out
''
