# where every sops secret lives and who may open it: the one place that knows the secrets layout
#
# a secret is declared once, with the kind of its value (src/secrets/shared.nix lists the kinds):
#   - instance.nix `secrets`: that guest's alone, in its folder's secrets.sops.json
#   - app.nix `secrets` and app-<name>-redeploy-token: in the app folder's, for every host that reads one
#   - the router's own also holds <route>-onion-key for every onion route
#   - src/secrets/shared.nix and <client>-oidc-secret: read by two or more hosts, or none; in shared.sops.json, and
#     each reader's own generated secrets.shared.sops.json
# every file is encrypted to the admins and its readers. A host's home folder holds age.pub and age.sops (its key,
# admins only). scripts/secrets-sync.nu writes the files from `planOf`; modules/base points every secret at its file.
# `catalog` is src/secrets/shared.nix; a test passes its own.
{
  lib,
  lab ? null,
  catalog ? import ../secrets/shared.nix,
}:
let
  service = import ./service.nix { inherit lib; };

  catalogFile = "secrets/shared.sops.json";
  tfvarsFile = "terraform/terraform.tfvars.sops.json";
  ownName = "secrets.sops.json";
  sharedName = "secrets.shared.sops.json";
  keyName = "age.sops";
  # the kinds scripts/secrets-sync.nu generates a value of, adds empty (manual, public), or copies from the dotfiles;
  # guardsData:<generated kind> is generated only on --generate-guarded (src/secrets/shared.nix)
  generatedKindPattern = "hex:[1-9][0-9]*|wireguard|laravel-key|garage-key-id|onion";
  kindPattern = "(guardsData:)?(${generatedKindPattern})|manual|public|dotfiles:[A-Za-z0-9._-]+";
  # terraform's connection variables (terraform/main.tf), written by scripts/lib/proxmox.nu, read by no guest
  tfvars = {
    proxmox_api_token_id = "public";
    proxmox_api_token_secret = "manual";
    proxmox_datastore = "public";
    proxmox_ssh_port = "public";
    proxmox_ssh_user = "public";
  };
  # the token a ci job posts to deploy.<domain>/redeploy/<app> with (modules/swarm)
  deployTokenKind = "hex:32";
  onionKind = "guardsData:onion";
  oidcSecretKind = "hex:24";

  instanceList = lib.attrValues lab.instances;
  homeOf = i: if i.folder != null then i.folder else "generated/nodes/${i.name}";

  entriesOf =
    {
      file,
      home ? null,
    }:
    lib.mapAttrsToList (
      name: kind: {
        inherit
          name
          kind
          file
          home
          ;
      }
    );
  ownEntriesOf =
    i:
    entriesOf {
      file = "${homeOf i}/${ownName}";
      home = homeOf i;
    };
  # the router's tor publishes every onion route with its own key; a lost key loses the address
  router = lib.findFirst (i: i.zone == "router") (throw "modules/secrets.nix: no instance is the router") instanceList;
  onionKeys = lib.mapAttrs' (name: _: lib.nameValuePair (service.onionKeyOf name) onionKind) (
    lib.filterAttrs (_: r: r.onion) lab.catalog.external
  );
  entries =
    lib.concatMap (i: ownEntriesOf i i.config.secrets) instanceList
    ++ ownEntriesOf router onionKeys
    ++ lib.concatLists (
      lib.mapAttrsToList (
        app: a:
        entriesOf { file = "${lab.layout.custom}/${app}/${ownName}"; } (
          a.secrets // { "app-${app}-redeploy-token" = deployTokenKind; }
        )
      ) lab.appsCatalog.apps
    )
    ++ entriesOf { file = catalogFile; } catalog
    ++ entriesOf { file = tfvarsFile; } tfvars
    ++ map (c: {
      name = c.secret;
      kind = oidcSecretKind;
      file = catalogFile;
      home = null;
    }) lab.oidc;
  byName = lib.groupBy (e: e.name) entries;
  declared = lib.mapAttrs (_: es: removeAttrs (lib.head es) [ "name" ]) byName;

  hostOf = hostName: lib.findFirst (i: i.config.hostName == hostName) null instanceList;

  # a host reads a secret from the file that holds it, a shared one from its own copy
  fileOf =
    host: key:
    let
      d = declared.${key} or null;
    in
    if d != null && d.file != catalogFile then d.file else "${homeOf host}/${sharedName}";

  planOf =
    configs:
    let
      readsOf = c: lib.sort lib.lessThan (lib.unique (map (s: s.key) (lib.attrValues c.sops.secrets)));
      hosts = lib.mapAttrs (
        name: c:
        let
          i = lab.instances.${lab.hosts.${name}.id};
        in
        {
          inherit i;
          reads = readsOf c;
          home = homeOf i;
        }
      ) configs;
      readEntries = lib.concatLists (
        lib.mapAttrsToList (
          name: h:
          map (key: {
            inherit key;
            file = fileOf h.i key;
            reader = name;
          }) h.reads
        ) hosts
      );

      problems =
        lib.concatLists (
          lib.mapAttrsToList (
            name: es:
            lib.optional (lib.length es > 1)
              "secret ${name} is declared ${toString (lib.length es)} times, for ${lib.concatMapStringsSep " and " (e: e.file) es}"
          ) byName
        )
        ++ lib.concatMap (
          e: lib.optional (builtins.match kindPattern e.kind == null) "secret ${e.name} (${e.file}): unknown kind ${e.kind}"
        ) entries
        ++ lib.concatMap (
          e:
          let
            d = declared.${e.key} or null;
          in
          if d == null then
            [
              (
                "${e.reader} reads ${e.key}, which nothing declares: add it to its instance.nix `secrets` "
                + "(only this host reads it) or to src/secrets/shared.nix"
              )
            ]
          else
            lib.optional (d.home != null && d.home != hosts.${e.reader}.home)
              "${e.reader} reads ${e.key}, which ${d.home}/instance.nix declares as its own: a secret two hosts read belongs in src/secrets/shared.nix"
        ) readEntries;
    in
    {
      secrets = lib.mapAttrs (_: d: { inherit (d) kind file; }) declared;
      hosts = lib.mapAttrs (_: h: {
        inherit (h) home;
        inherit (h.i.config) hostName;
        shared = lib.filter (key: (declared.${key}.file or null) == catalogFile) h.reads;
      }) hosts;
      # every sops file -> the configurations that read it, besides the admins
      files =
        lib.genAttrs (lib.unique (map (d: d.file) (lib.attrValues declared))) (_: [ ])
        // lib.mapAttrs' (_: h: lib.nameValuePair "${h.home}/${keyName}" [ ]) hosts
        // lib.mapAttrs (_: es: lib.unique (map (e: e.reader) es)) (lib.groupBy (e: e.file) readEntries);
      inherit problems;
    };
in
{
  inherit
    declared
    hostOf
    fileOf
    planOf
    homeOf
    catalogFile
    tfvarsFile
    sharedName
    ownName
    keyName
    kindPattern
    ;
}
