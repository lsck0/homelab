# the collector's rules (modules/lab `problems`), table by table: every broken tree below is refused with a
# line naming the fix, and the real tree holds. A tree is the real zones, site and swarm plus the given folders.
# Adding is one folder: the real tree plus a copy of each template (instances/_template, apps/_template) is a lab
# whose new guest is a host with an address, a route, a card, its grants and shares, and whose new app is in the
# catalog. The desktop clients' lab.json (modules/lab-export.nix) keeps its guests' shape.
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
  cidr = import ../../cidr.nix { inherit lib; };

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
    role-named-like-a-source = { folders."199-internal-demo" = instance ''{ roles = [ "lan" ]; }''; expect = "is a grant source's name already"; };
  };

  # -----------------------------------------------------------------------------
  # ADDING: the real tree plus each template, copied the way the templates say
  # -----------------------------------------------------------------------------

  added = { id = "199"; zone = "internal"; service = "demo"; app = "sample"; share = "data/demo"; port = 80; };
  addedFolder = "${added.id}-${added.zone}-${added.service}";
  # the template's instance.nix as copied, plus the two facts it leaves out
  addedInstance = pkgs.writeText "instance.nix" ''
    { ... }: {
      imports = [ ./template.nix ];
      shares."${added.share}" = { };
      grants = [ { from = [ "operator" ]; tcp = [ ${toString added.port} ]; why = "the test's grant"; } ];
    }
  '';
  addedTree = pkgs.runCommand "lab-added" { } ''
    cp -r ${../../..} $out && chmod -R u+w $out
    cp -r $out/instances/_template $out/instances/${addedFolder}
    mv $out/instances/${addedFolder}/instance.nix $out/instances/${addedFolder}/template.nix
    cp ${addedInstance} $out/instances/${addedFolder}/instance.nix
    cp -r $out/apps/_template $out/apps/${added.app}
  '';
  grown = import ../default.nix { inherit lib; root = addedTree; };
  addedIp = grown.inventory.${added.id}.ip or null;
  zoneSubnet = (import ../../net.nix { inherit lib; inherit (grown) inventory site; }).zones.${added.zone}.subnet;
  addedChecks = {
    "the tree holds" = grown.problems == [ ];
    "the folder is a host" = (grown.hosts.${addedFolder}.main or null) != null;
    "the guest has its zone's address" = addedIp == cidr.host zoneSubnet (lib.toInt added.id);
    "its service is a route" = (grown.routes.${added.service}.vmid or null) == lib.toInt added.id;
    "its service has a card" = lib.any (c: c.route == added.service) grown.homepage;
    "its grant names the role's guest" = lib.any (g: g.to == added.id && g.from == [ grown.roles.operator ]) grown.grants;
    "its share is exported to it" = lib.any (s: s.path == "/srv/nas/${added.share}") (grown.nasClients.${addedIp} or [ ]);
    "the app is in the catalog" = grown.catalog.apps ? ${added.app};
  };

  # -----------------------------------------------------------------------------
  # EXPORT: lab.json's guests as the desktop clients read them
  # -----------------------------------------------------------------------------

  exportGuestKeys = [ "enabled" "idle" "ip" "name" "powered" "zone" ];
  exportProblems = lib.concatLists (lib.mapAttrsToList (id: g:
    lib.optional (lib.attrNames g != exportGuestKeys) "lab.export guest ${id} has [ ${toString (lib.attrNames g)} ], not [ ${toString exportGuestKeys} ]"
    ++ lib.optional (!(lib.isBool g.powered && (g.idle == null || lib.isString g.idle) && lib.elem g.enabled [ "true" "false" "onDemand" ]))
      "lab.export guest ${id}: ${builtins.toJSON g}"
  ) (import ../../lab-export.nix { inherit lib; lab = import ../default.nix { inherit lib; }; }).guests);

  failures = lib.concatLists (lib.mapAttrsToList (name: c: let problems = problemsOf c.folders; in
    lib.optional (!(lib.any (lib.hasInfix c.expect) problems))
      "refused.${name}: no problem says \"${c.expect}\"; problems: ${builtins.toJSON problems}") refused)
    ++ map (p: "the real tree: ${p}") (import ../default.nix { inherit lib; }).problems
    ++ map (check: "adding ${addedFolder} and apps/${added.app}: ${check} fails; problems: ${builtins.toJSON grown.problems}")
      (lib.attrNames (lib.filterAttrs (_: ok: !ok) addedChecks))
    ++ exportProblems;
in
pkgs.runCommand "lab" { } (if failures == [ ] then ''
  echo "lab: ${toString (lib.length (lib.attrNames refused))} broken trees refused, the real tree and a copy of each template hold"
  touch $out
'' else ''
  cat ${pkgs.writeText "lab-failures" (lib.concatLines failures)} >&2
  exit 1
'')
