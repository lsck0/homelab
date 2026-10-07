# the collector's rules (modules/lab `problems`), table by table: every broken tree below is refused with a
# line naming the fix, and the real tree holds. A tree is the real zones, site and swarm plus the given folders.
{ pkgs, lib, ... }:
let
  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  treeOf = folders: pkgs.runCommand "lab-fixture" { } (''
    mkdir -p $out/instances $out/apps $out/generated
    cp ${../../../generated/zones.json} $out/generated/zones.json
    cp ${../../../generated/site.json} $out/generated/site.json
    cp ${../../../apps/swarm.nix} $out/apps/swarm.nix
  '' + lib.concatStrings (lib.mapAttrsToList (folder: files: "mkdir -p $out/instances/${folder}\n"
    + lib.concatStrings (lib.mapAttrsToList (file: text: "cp ${pkgs.writeText file text} $out/instances/${folder}/${file}\n") files)
  ) folders));
  instance = text: { "main.nix" = "{ ... }: { }"; "instance.nix" = text; };
  problemsOf = folders: (import ../default.nix { inherit lib; root = treeOf folders; }).problems;

  # -----------------------------------------------------------------------------
  # TABLES
  # -----------------------------------------------------------------------------

  # folders -> a line of the problems must contain this
  refused = {
    folder-name = { folders."1x-internal-demo" = instance "{ }"; expect = "an instance folder is"; };
    missing-instance-nix = { folders."199-internal-demo"."main.nix" = "{ ... }: { }"; expect = "holds main.nix and instance.nix"; };
    vmid-outside-zone = { folders."250-internal-demo" = instance "{ }"; expect = "outside zone internal's range"; };
    vmid-twice = {
      folders = { "199-internal-demo" = instance "{ }"; "199-internal-other" = instance "{ }"; };
      expect = "vmid 199 is claimed by";
    };
    service-twice = {
      folders = { "198-internal-demo" = instance "{ services.x.port = 80; }"; "199-internal-other" = instance "{ services.x.port = 80; }"; };
      expect = "service x is declared by";
    };
    lxc-with-pci = { folders."199-internal-demo" = instance ''{ vm = { kind.lxc = "test"; pci = [ "gpu" ]; }; }''; expect = "an lxc takes no pci devices"; };
    privileged-vm = { folders."199-internal-demo" = instance ''{ vm = { privileged = true; needs = [ "nfs" ]; }; }''; expect = "privileged is lxc only"; };
    guest-names-itself = { folders."199-internal-demo" = instance ''{ hostName = "demo"; }''; expect = "hostName is vm-199"; };
    idle-without-ingress = { folders."260-apps-demo" = instance ''{ idle.stopAfter = "30m"; }''; expect = "idle needs a zone whose ingress"; };
  };

  failures = lib.concatLists (lib.mapAttrsToList (name: c: let problems = problemsOf c.folders; in
    lib.optional (!(lib.any (lib.hasInfix c.expect) problems))
      "refused.${name}: no problem says \"${c.expect}\"; problems: ${builtins.toJSON problems}") refused)
    ++ map (p: "the real tree: ${p}") (import ../default.nix { inherit lib; }).problems;
in
pkgs.runCommand "lab" { } (if failures == [ ] then ''
  echo "lab: ${toString (lib.length (lib.attrNames refused))} broken trees refused, the real tree holds"
  touch $out
'' else ''
  cat ${pkgs.writeText "lab-failures" (lib.concatLines failures)} >&2
  exit 1
'')
