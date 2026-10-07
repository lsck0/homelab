# where every sops secret lives and who may open it: the one place that knows the secrets layout
#
# A secret is declared once, with the kind of its value (src/secrets/shared.nix lists the kinds):
#   - instances/<n>/instance.nix `secrets`: only that guest reads it; the value lives in its folder's
#     secrets.sops.json, encrypted to the admins and that guest
#   - apps/<name>/app.nix `secrets`, plus app-<name>-redeploy-token for every app: in the app folder's
#     secrets.sops.json, encrypted to the admins and every host that reads one of them (the manager, an own guest)
#   - src/secrets/shared.nix, plus <client>-oidc-secret for every oidc client: read by two or more hosts, or by
#     none; the value lives in src/secrets/shared.sops.json, admins only, and each reader gets the ones it reads in
#     its own generated secrets.shared.sops.json
# Every host has a home folder holding age.pub (its recipient) and age.sops (its private key, admins only): its
# instance folder, an app's own guest the app folder, a swarm worker (no folder of its own) generated/nodes/<name>/.
# src/scripts/secrets-sync.sh writes the files from `planOf`; modules/base points every secret at its file.
#
#   secrets = import ./secrets.nix { inherit lib lab; };
#   secrets.declared.kopia-password     # { kind = "guardsData:hex:24"; file = "instances/109-internal-nas/secrets.sops.json"; home = ...; }
#   secrets.fileOf host "attic-pull-token"   # "instances/109-internal-nas/secrets.shared.sops.json" (paths relative to src/)
#   secrets.planOf configs              # what secrets-sync.sh converges to, and the problems that stop it
#   (import ./secrets.nix { inherit lib; }).kindPattern   # the kinds alone, for a schema (no `lab` needed)
# `catalog` is src/secrets/shared.nix; a test passes its own.
{ lib, lab ? null, catalog ? import ../secrets/shared.nix }:
let
  # -------------------------------------------------------------------------------------------------------------
  # CONSTANTS
  # -------------------------------------------------------------------------------------------------------------

  catalogFile = "secrets/shared.sops.json";
  tfvarsFile = "terraform/terraform.tfvars.sops.json";
  ownName = "secrets.sops.json";
  sharedName = "secrets.shared.sops.json";
  keyName = "age.sops";
  # the kinds scripts/secrets-sync.sh generates a value of, adds empty (manual, public), or copies from the dotfiles;
  # guardsData:<generated kind> is generated only on --generate-guarded (src/secrets/shared.nix)
  generatedKindPattern = "hex:[1-9][0-9]*|wireguard|ntfy-token|garage-key-id";
  kindPattern = "(guardsData:)?(${generatedKindPattern})|manual|public|dotfiles:[A-Za-z0-9._-]+";
  # terraform's connection variables (terraform/main.tf), written by scripts/lib/proxmox.sh, read by no guest
  tfvars = {
    proxmox_api_token_id = "public";
    proxmox_api_token_secret = "manual";
    proxmox_datastore = "public";
    proxmox_ssh_port = "public";
    proxmox_ssh_user = "public";
  };
  # the token a ci job posts to deploy.<domain>/redeploy/<app> with (modules/swarm)
  deployTokenKind = "hex:32";
  oidcSecretKind = "hex:24";

  # -------------------------------------------------------------------------------------------------------------
  # DECLARATIONS
  # -------------------------------------------------------------------------------------------------------------

  instanceList = lib.attrValues lab.instances;
  guestApps = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (app: a:
    lib.optional ((a.placement or null) != null) (lib.nameValuePair (toString a.placement.vmid) app)) lab.appsCatalog.apps));
  homeOf = i:
    if i.dir != null then "instances/${i.name}"
    else if guestApps ? ${i.id} then "apps/${guestApps.${i.id}}"
    else "generated/nodes/${i.name}";

  entriesOf = { file, home ? null }: lib.mapAttrsToList (name: kind: { inherit name kind file home; });
  entries =
    lib.concatMap (i: entriesOf { file = "${homeOf i}/${ownName}"; home = homeOf i; } i.config.secrets) instanceList
    ++ lib.concatLists (lib.mapAttrsToList (app: a: entriesOf { file = "apps/${app}/${ownName}"; }
      ((a.secrets or { }) // { "app-${app}-redeploy-token" = deployTokenKind; })) lab.appsCatalog.apps)
    ++ entriesOf { file = catalogFile; } catalog
    ++ entriesOf { file = tfvarsFile; } tfvars
    ++ map (c: { name = c.secret; kind = oidcSecretKind; file = catalogFile; home = null; }) lab.oidc;
  byName = lib.groupBy (e: e.name) entries;
  declared = lib.mapAttrs (_: es: removeAttrs (lib.head es) [ "name" ]) byName;

  hostOf = hostName: lib.findFirst (i: i.config.hostName == hostName) null instanceList;

  # a host reads a secret from the file that holds it, a shared one from its own copy
  fileOf = host: key: let d = declared.${key} or null; in
    if d != null && d.file != catalogFile then d.file else "${homeOf host}/${sharedName}";

  # -------------------------------------------------------------------------------------------------------------
  # PLAN
  # -------------------------------------------------------------------------------------------------------------

  planOf = configs:
    let
      readsOf = c: lib.sort lib.lessThan (lib.unique (map (s: s.key) (lib.attrValues c.sops.secrets)));
      hosts = lib.mapAttrs (name: c: let i = lab.instances.${lab.hosts.${name}.id}; in {
        inherit i;
        reads = readsOf c;
        home = homeOf i;
      }) configs;
      readEntries = lib.concatLists (lib.mapAttrsToList (name: h:
        map (key: { inherit key; file = fileOf h.i key; reader = name; }) h.reads) hosts);

      problems =
        lib.concatLists (lib.mapAttrsToList (name: es: lib.optional (lib.length es > 1)
          "secret ${name} is declared ${toString (lib.length es)} times, for ${lib.concatMapStringsSep " and " (e: e.file) es}") byName)
        ++ lib.concatMap (e: lib.optional (builtins.match kindPattern e.kind == null) "secret ${e.name} (${e.file}): unknown kind ${e.kind}") entries
        ++ lib.concatMap (e: let d = declared.${e.key} or null; in
          if d == null then [ ("${e.reader} reads ${e.key}, which nothing declares: add it to its instance.nix `secrets` "
            + "(only this host reads it) or to src/secrets/shared.nix") ]
          else lib.optional (d.home != null && d.home != hosts.${e.reader}.home)
            "${e.reader} reads ${e.key}, which ${d.home}/instance.nix declares as its own: a secret two hosts read belongs in src/secrets/shared.nix"
        ) readEntries;
    in {
      secrets = lib.mapAttrs (_: d: { inherit (d) kind file; }) declared;
      hosts = lib.mapAttrs (_: h: {
        inherit (h) home;
        hostName = h.i.config.hostName;
        shared = lib.filter (key: (declared.${key}.file or null) == catalogFile) h.reads;
      }) hosts;
      # every sops file -> the configurations that read it, besides the admins
      files = lib.genAttrs (lib.unique (map (d: d.file) (lib.attrValues declared))) (_: [ ])
        // lib.mapAttrs' (_: h: lib.nameValuePair "${h.home}/${keyName}" [ ]) hosts
        // lib.mapAttrs (_: es: lib.unique (map (e: e.reader) es)) (lib.groupBy (e: e.file) readEntries);
      inherit problems;
    };
in
{
  inherit declared hostOf fileOf planOf homeOf catalogFile tfvarsFile sharedName ownName keyName kindPattern;
}
