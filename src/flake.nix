# the lab: one nixos configuration per instance folder and swarm node, the collected facts (`lab`), the checks
#
# Checks: every src/tests/<name>.nix but the shared stand-ins (the lab-wide tests), every
# src/instances/<name>/tests/<test>.nix and every src/modules/<name>/tests/<test>.nix (a test lives with what it tests)
# is a check named by its file; adding a test is adding its file. A test is a function of
# { pkgs, lib, inputs, specialArgs, ... } (specialArgs: the hosts' own, the lab's facts) returning a derivation; a
# seeded one also takes `seed` with a default and lists past failing seeds in passthru.regressionSeeds, and its check
# runs the default seed and every regression seed.
#   nix build .#checks.x86_64-linux.<name>
#   nix build .#legacyPackages.x86_64-linux.seeded.<name>.<seed>     (one seed of a seeded test)
{
  description = "Homelab NixOS Configurations";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    # github deprecates runners faster than stable updates
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    # hermes agent (vm-114)
    hermes-agent.url = "github:NousResearch/hermes-agent";
    # owner's personal skills, passed to hermes as-is
    dotfiles.url = "github:lsck0/arch-dotfiles";
    dotfiles.flake = false;
  };

  outputs = { self, nixpkgs, sops-nix, ... }@inputs:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    lib = nixpkgs.lib;

    # every fact about the guests and apps, collected from src/instances/*/ and src/apps/*/ (modules/lab)
    lab = let collected = import ./modules/lab { inherit lib; }; in
      assert lib.assertMsg (collected.problems == [ ]) "the lab's instances break its rules:\n${lib.concatLines collected.problems}";
      collected;
    inherit (lab) inventory site;
    # every running guest's nas mounts by address: vm-109 exports exactly these, the router opens nfs to them
    nasClients = import ./modules/nas-clients.nix {
      inherit lib inventory;
      configs = lib.mapAttrs (_: sys: sys.config) (removeAttrs self.nixosConfigurations [ "109-internal-nas" ]);
    };
    specialArgs = { inherit inputs inventory nasClients site lab; };

    common = {
      imports = [
        ./modules/base
        ./modules/egress-vpn.nix
        sops-nix.nixosModules.sops
      ];
    };

    # the checks (header): src/tests/stubs.nix is the shared stand-ins, no test
    testsIn = dir: lib.mapAttrs' (file: _: lib.nameValuePair (lib.removeSuffix ".nix" file) (dir + "/${file}"))
      (lib.filterAttrs (file: kind: kind == "regular" && lib.hasSuffix ".nix" file) (builtins.readDir dir));
    folderTests = dir: map (folder: testsIn (dir + "/${folder}/tests"))
      (lib.attrNames (lib.filterAttrs (folder: kind: kind == "directory" && builtins.pathExists (dir + "/${folder}/tests"))
        (builtins.readDir dir)));
    testSets = [ (removeAttrs (testsIn ./tests) [ "stubs" ]) ] ++ folderTests ./instances ++ folderTests ./modules;
    testNamesTwice = lib.attrNames (lib.filterAttrs (_: names: lib.length names > 1)
      (lib.groupBy (name: name) (lib.concatMap lib.attrNames testSets)));
    testFiles = assert lib.assertMsg (testNamesTwice == [ ]) "two tests share a name, which names their check: ${toString testNamesTwice}";
      lib.mergeAttrsList testSets;
    testNames = lib.attrNames testFiles;
    testOf = name: args: import testFiles.${name} ({ inherit pkgs lib inputs specialArgs; } // args);
    testIsSeeded = name: (builtins.functionArgs (import testFiles.${name})) ? seed;
    # seeds are 16 bit: enough schedules to sample from, few enough to list as attribute names
    seedMax = 65535;
  in {
    checks.${system} = lib.genAttrs testNames (name: let test = testOf name { }; in
      if !(testIsSeeded name) || (test.regressionSeeds or [ ]) == [ ] then test
      else pkgs.linkFarm "${name}-seeds" ([ { name = "default"; path = test; } ]
        ++ map (seed: { name = "seed-${toString seed}"; path = testOf name { inherit seed; }; }) test.regressionSeeds));

    legacyPackages.${system} = {
      seeded = lib.genAttrs (lib.filter testIsSeeded testNames) (name:
        lib.genAttrs (map toString (lib.range 0 seedMax)) (seed: testOf name { seed = lib.toInt seed; }));

      # where every secret lives (modules/secrets.nix): `declared` from the folders alone, `plan` (what
      # scripts/secrets-sync.sh converges to) from every host's sops-nix secrets as well
      secrets = let s = import ./modules/secrets.nix { inherit lib lab; }; in {
        inherit (s) declared;
        plan = s.planOf (lib.mapAttrs (_: sys: sys.config) self.nixosConfigurations);
      };
    };

    # every tool the scripts and sync.sh run, pinned by flake.lock: `nix develop ./src`
    devShells.${system}.default = let
      # terraform is BSL
      pkgsUnfree = import nixpkgs { inherit system; config.allowUnfreePredicate = p: lib.getName p == "terraform"; };
    in pkgs.mkShell {
      packages = (with pkgs; [
        # sops encrypts to the admin YubiKey recipient only through its plugin
        sops age age-plugin-yubikey jq openssl
        openssh sshpass git curl gh python3 wireguard-tools shellcheck
      ]) ++ [ pkgsUnfree.terraform ];
    };

    packages.${system} = {
      cloud-image = import ./modules/cloud-image.nix {
        inherit pkgs lib nixpkgs specialArgs;
        common = { imports = [ common ./modules/platform-vm.nix ]; };
      };
      # proxmox vztmpl: sync.sh uploads it before terraform creates containers
      lxc-template = (lib.nixosSystem {
        inherit system specialArgs;
        modules = [ common ./modules/platform-lxc.nix ];
      }).config.system.build.tarball;
    };

    # the collected facts: terraform reads `lab.terraform` (lib.tf), scripts the inventory (`nix eval .#lab.inventory`),
    # sync.sh writes `lab.export` to generated/lab.json, the desktop clients' interface (modules/lab-export.nix)
    lab = lab // { export = import ./modules/lab-export.nix { inherit lib lab; }; };

    # one configuration per instance folder (its main.nix) and per generated swarm node (modules/swarm alone);
    # the hostname comes from the folder, so a host cannot claim another's
    nixosConfigurations = lib.mapAttrs (_: host: lib.nixosSystem {
      inherit system specialArgs;
      modules = [ common ./modules/platform-${host.kind}.nix { networking.hostName = host.hostName; } ]
        ++ lib.optional (host.main != null) host.main;
    }) lab.hosts;
  };
}
