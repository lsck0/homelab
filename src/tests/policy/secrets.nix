# the secrets and the nas state shares, as every real configuration holds them
#
# - placement (modules/secrets.nix): every secret a host reads is declared once; one only a single guest reads lives
#   in that guest's folder (its instance.nix `secrets`), a shared one in src/secrets/shared.nix and src/secrets/shared.sops.json
# - every secret comes from the file the layout names, and every file is on disk holding exactly its declared names
#   (a host's shared copy exactly the shared ones it reads), encrypted to exactly the admin recipients of
#   src/secrets/admins.txt plus its readers' age.pub; each host's recipient is its own; .sops.yaml has the same
#   rule for every file (a forgotten secrets-sync.sh run fails here, before a deploy)
# - the key that opens them is the one sync.sh pushes, /var/lib/sops-nix/key.txt; no ssh key doubles as an age key
# - no secret file is readable by others, and no sops placeholder leaks into a unit, where nothing would replace it
# - token shares: a host mounts its own token dir read-write iff it mints a token, every other token dir read-only
#   (what a producer mints is its instance.nix `tokens`)
# - db dumps: a host with databases mounts exactly its own dump dir, read-write, and no other host's
# - the dmz and the apps zone mount per-service state only
{ lib, configs, inventory, lab, src, ... }:
let
  # the rules live beside src/; a tree evaluated as `path:src` lacks them, a git checkout has them
  sopsConfig = ../../../.sops.yaml;
  adminRecipients = lib.sort lib.lessThan (lib.filter (r: r != "") (map
    (line: lib.head (lib.splitString " " (lib.trim (lib.head (lib.splitString "#" line)))))
    (lib.splitString "\n" (builtins.readFile (src + "/secrets/admins.txt")))));
  keyFile = "/var/lib/sops-nix/key.txt";
  # sops-nix's placeholder shape: <SOPS:<sha256 of the name>:PLACEHOLDER>
  placeholderMark = "<SOPS:";

  layout = import ../../modules/secrets.nix { inherit lib lab; };
  plan = layout.planOf configs;
  catalog = import ../../secrets/shared.nix;
  idOf = config: let m = builtins.match "vm-([0-9]+)" config.networking.hostName; in
    if m == null then null else lib.head m;
  zoneOf = config: if idOf config == null then null else inventory.${idOf config}.type or null;

  # one secret only a single folder host reads, declared as shared: it belongs in that folder
  readersOf = key: lib.attrNames (lib.filterAttrs (_: h: lib.elem key (h.shared)) plan.hosts);
  placementLaws = lib.concatMap (key: let readers = readersOf key; in
    lib.optional (lib.length readers == 1 && lib.hasPrefix "instances/" plan.hosts.${lib.head readers}.home)
      ("src/secrets/shared.nix declares ${key}, which only ${lib.head readers} reads: "
        + "move it to ${plan.hosts.${lib.head readers}.home}/instance.nix `secrets`")
  ) (lib.attrNames catalog);

  wiringLaws = name: config: let host = layout.hostOf config.networking.hostName; in
    lib.optionals (host != null && migrated) (map (s: "${name}: secret ${s.key} comes from ${toString s.sopsFile}, not ${layout.fileOf host s.key}")
      (lib.filter (s: toString s.sopsFile != "${toString src}/${layout.fileOf host s.key}") (lib.attrValues config.sops.secrets)))
    ++ lib.optional (config.sops.age.keyFile != keyFile) "${name}: sops reads its key from ${toString config.sops.age.keyFile}, not ${keyFile}"
    ++ lib.optional (config.sops.age.sshKeyPaths != [ ] || config.sops.gnupg.sshKeyPaths != [ ])
      "${name}: an ssh host key doubles as a sops key"
    ++ map (f: "${name}: ${f.path} is readable by others (mode ${f.mode})")
      (lib.filter (f: !(lib.hasSuffix "0" f.mode)) (lib.attrValues config.sops.secrets ++ lib.attrValues config.sops.templates));

  # the files on disk against the plan; recipients by name: the admins, and each host by its age.pub
  pubOf = c: lib.trim (builtins.readFile (src + "/${plan.hosts.${c}.home}/age.pub"));
  recipientsOf = file: lib.sort lib.lessThan (map (a: a.recipient) ((lib.importJSON (src + "/${file}")).sops.age or [ ]));
  wantRecipients = file: lib.sort lib.lessThan (adminRecipients ++ map pubOf plan.files.${file});
  namesWanted = file:
    if lib.hasSuffix "/${layout.sharedName}" file
    then lib.sort lib.lessThan (lib.findFirst (h: "${h.home}/${layout.sharedName}" == file) null (lib.attrValues plan.hosts)).shared
    else lib.attrNames (lib.filterAttrs (_: d: d.file == file) plan.secrets);
  isValues = file: lib.hasSuffix ".json" file && file != layout.tfvarsFile;
  fileLaws = file:
    if !(builtins.pathExists (src + "/${file}")) then [ "src/${file} is missing: run src/scripts/secrets-sync.sh --apply" ]
    else lib.optional (recipientsOf file != wantRecipients file)
      "src/${file} is encrypted to [ ${toString (recipientsOf file)} ], not the admins and its readers [ ${toString plan.files.${file}} ]"
    ++ lib.optional (isValues file && lib.attrNames (removeAttrs (lib.importJSON (src + "/${file}")) [ "sops" ]) != namesWanted file)
      "src/${file} does not hold exactly [ ${toString (namesWanted file)} ]: run src/scripts/secrets-sync.sh --apply";
  pubs = map (c: { inherit c; pub = pubOf c; }) (lib.filter (c: builtins.pathExists (src + "/${plan.hosts.${c}.home}/age.pub")) (lib.attrNames plan.hosts));
  uniqueRecipients = lib.concatLists (lib.mapAttrsToList (pub: es:
    lib.optional (lib.length es > 1 || lib.elem pub adminRecipients) "hosts ${toString (map (e: e.c) es)} share the recipient ${pub}")
    (lib.groupBy (e: e.pub) pubs));

  # .sops.yaml: "  - path_regex: src/<file regex>$" followed by "    age: <recipients>"
  ruleLines = lib.splitString "\n" (builtins.readFile sopsConfig);
  rules = lib.listToAttrs (lib.concatLists (lib.imap0 (i: line: let m = builtins.match "  - path_regex: src/(.*)\\$" line; in
    lib.optional (m != null) (lib.nameValuePair (builtins.replaceStrings [ "\\." ] [ "." ] (lib.head m))
      (lib.sort lib.lessThan (lib.splitString "," (lib.removePrefix "    age: " (lib.elemAt ruleLines (i + 1))))))) ruleLines));
  ruleLaws = lib.optionals (builtins.pathExists sopsConfig) (lib.concatMap (file:
    lib.optional ((rules.${file} or null) != wantRecipients file) ".sops.yaml has no rule for src/${file} to the admins and its readers"
  ) (lib.attrNames plan.files));

  migrated = !(builtins.pathExists (src + "/secrets.json"));
  layoutLaws = map (p: "secrets layout: ${p}") plan.problems ++ placementLaws
    ++ (if migrated then lib.concatMap fileLaws (lib.attrNames plan.files) ++ uniqueRecipients ++ ruleLaws
        else [ "src/secrets.json: the secrets are not per folder yet: run src/scripts/secrets-migrate.sh" ]);

  # every string a unit runs or is handed: a placeholder there is never replaced
  unitStrings = unit: lib.filter builtins.isString (
    [ (unit.script or "") (unit.preStart or "") (unit.postStart or "") ]
    ++ lib.attrValues (unit.environment or { })
    ++ lib.flatten (map (k: unit.serviceConfig.${k} or [ ]) [ "ExecStart" "ExecStartPre" "ExecStartPost" "Environment" ]));
  leakLaws = name: config: lib.concatLists (lib.mapAttrsToList (unit: u:
    lib.optional (lib.any (lib.hasInfix placeholderMark) (unitStrings u))
      "${name}: unit ${unit} contains a sops placeholder, which only templates replace") config.systemd.services);

  tokenLaws = name: config: let
    t = config.homelab.tokens;
    own = idOf config;
    mints = lib.attrNames (lib.filterAttrs (_: id: toString id == own) t.producers);
    tokenShares = lib.filter (s: builtins.match "/srv/nas/data/tokens/vm-[0-9]+" s.path != null) config.homelab.nasShares;
    ownShare = "/srv/nas/data/tokens/vm-${toString own}";
  in
    map (s: "${name}: mounts another producer's ${s.path} read-write")
      (lib.filter (s: s.path != ownShare && !s.readOnly) tokenShares)
    ++ lib.optional (mints != [ ] && !(lib.any (s: s.path == ownShare && !s.readOnly) tokenShares))
      "${name}: mints [ ${toString mints} ] without its own token dir mounted read-write"
    ++ lib.optional (mints == [ ] && lib.any (s: s.path == ownShare) tokenShares)
      "${name}: mounts a token dir of its own but mints nothing";

  dumpLaws = name: config: let
    dumpShares = lib.filter (s: lib.hasPrefix "/srv/nas/data/db-dumps" s.path) config.homelab.nasShares;
    ownDumps = "/srv/nas/data/db-dumps/${config.networking.hostName}";
    hasDatabases = config.homelab.dbBackup.databases != { };
  in
    map (s: "${name}: mounts ${s.path}, not its own dump dir") (lib.filter (s: s.path != ownDumps) dumpShares)
    ++ lib.optional (hasDatabases && !(lib.any (s: s.path == ownDumps && !s.readOnly) dumpShares))
      "${name}: dumps databases without its own dump dir mounted read-write";

  zoneLaws = name: config:
    lib.optionals (lib.elem (zoneOf config) [ "external" "apps" ]) (map (s: "${name}: dmz or apps host mounts ${s.path}")
      (lib.filter (s: !(lib.hasPrefix "/srv/nas/data/" s.path)) config.homelab.nasShares));
in
lib.concatLists (lib.mapAttrsToList (name: config:
  wiringLaws name config ++ leakLaws name config ++ tokenLaws name config ++ dumpLaws name config ++ zoneLaws name config
) configs) ++ layoutLaws
