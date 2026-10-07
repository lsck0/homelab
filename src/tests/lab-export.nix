# lab-wide: the workstation's interface to every collected fact (flake output lab.export)
# lab.export's shape (modules/lab-export.nix): every key the desktop clients read, with its type. A new key is no new
# schema and passes; the tables prove the checker refuses each kind of break.
{ pkgs, lib, specialArgs, ... }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  export = import ../modules/lab-export.nix { inherit lib; inherit (specialArgs) lab; };

  # a shape: a nix type name, { nullOr; }, { enum; }, { attrsOf; }, { listOf; }, or a record whose every key is required
  str = "string";
  int = "int";
  bool = "bool";
  nullOr = shape: { nullOr = shape; };
  enum = values: { enum = values; };
  attrsOf = shape: { attrsOf = shape; };
  listOf = shape: { listOf = shape; };

  shape = {
    schema = enum [ 1 ];
    domain = str;
    router = str;
    zones = attrsOf { subnet = str; router = str; ingress = nullOr int; };
    guests = attrsOf {
      name = str;
      zone = str;
      ip = str;
      powered = bool;
      idle = nullOr str;
      enabled = enum [ "true" "false" "onDemand" ];
    };
    routes = attrsOf {
      host = str;
      path = str;
      zone = enum [ "internal" "external" ];
      protocol = enum [ "http" "tcp" "udp" ];
      vmid = nullOr int;
      app = nullOr str;
      port = int;
      health = nullOr str;
    };
    infra = listOf { name = str; href = nullOr str; ping = nullOr str; };
    proxmox = { ip = str; url = str; };
    monitoring = { prometheus = str; loki = str; grafana = str; dashboard = str; accessLog = str; };
    ntfy = { url = str; topics = attrsOf str; desktop = listOf str; };
    ldap = { baseDn = str; adminGroup = str; };
  };

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  violationsOf = path: s: value:
    if builtins.isString s then
      lib.optional (builtins.typeOf value != s) "${path}: a ${builtins.typeOf value}, not a ${s}"
    else if s ? nullOr then lib.optionals (value != null) (violationsOf path s.nullOr value)
    else if s ? enum then
      lib.optional (!(lib.elem value s.enum)) "${path}: ${builtins.toJSON value} is none of ${builtins.toJSON s.enum}"
    else if s ? attrsOf then
      if builtins.isAttrs value then lib.concatLists (lib.mapAttrsToList (key: v: violationsOf "${path}.${key}" s.attrsOf v) value)
      else [ "${path}: not an attribute set" ]
    else if s ? listOf then
      if builtins.isList value then lib.concatLists (lib.imap0 (i: v: violationsOf "${path}[${toString i}]" s.listOf v) value)
      else [ "${path}: not a list" ]
    else if builtins.isAttrs value then
      lib.concatLists (lib.mapAttrsToList (key: field:
        if value ? ${key} then violationsOf "${path}.${key}" field value.${key} else [ "${path}.${key}: missing" ]) s)
    else [ "${path}: not a record" ];

  violations = violationsOf "lab.export" shape;

  # -----------------------------------------------------------------------------
  # TABLES
  # -----------------------------------------------------------------------------

  aGuest = lib.head (lib.attrNames export.guests);
  # a broken export -> a line of the violations must contain this
  refused = {
    enum-value = { tampered = lib.recursiveUpdate export { guests.${aGuest}.enabled = "yes"; }; expect = "is none of"; };
    retyped = { tampered = lib.recursiveUpdate export { guests.${aGuest}.powered = "true"; }; expect = "not a bool"; };
    missing-key = { tampered = export // { monitoring = removeAttrs export.monitoring [ "loki" ]; }; expect = "monitoring.loki: missing"; };
    not-null = { tampered = lib.recursiveUpdate export { routes.grafana.port = null; }; expect = "routes.grafana.port: a null"; };
  };
  # a new key is no new schema
  accepted = { new-key = export // { extra = { }; }; };

  failures = map (v: "the real export: ${v}") (violations export)
    ++ lib.concatLists (lib.mapAttrsToList (name: c: let found = violations c.tampered; in
      lib.optional (!(lib.any (lib.hasInfix c.expect) found)) "refused.${name}: no violation says \"${c.expect}\"; violations: ${builtins.toJSON found}") refused)
    ++ lib.concatLists (lib.mapAttrsToList (name: tampered: map (v: "accepted.${name}: ${v}") (violations tampered)) accepted);
in
pkgs.runCommand "lab-export" { } (if failures == [ ] then ''
  echo "lab-export: the export holds its shape, ${toString (lib.length (lib.attrNames refused))} broken exports refused"
  touch $out
'' else ''
  cat ${pkgs.writeText "lab-export-failures" (lib.concatLines failures)} >&2
  exit 1
'')
