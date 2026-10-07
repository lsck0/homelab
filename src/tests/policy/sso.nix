# every group authelia admits through (a forwardauth rule's subject, an oidc client's policy) exists in lldap's
# bootstrap: a group nobody can be put in leaves its page to the admins alone and `lab-user add` fails on it.
# The proxmox realm binds where the lab export says (scripts/pve-install.sh): that guest serves ldaps there, and its
# plain ldap, which would carry the password in clear, is closed to the network.
{ lib, configs, lab, inventory, ... }:
let
  hostsOf = running: lib.attrNames (lib.filterAttrs (_: running) configs);
  autheliaHosts = hostsOf (c: c.services.authelia.instances != { });
  lldapHosts = hostsOf (c: c.services.lldap.enable);
  lldapGroups = lib.concatMap (host: lib.splitString " " configs.${host}.systemd.services.lldap-bootstrap.environment.BOOTSTRAP_GROUPS)
    lldapHosts;

  groupsOf = subjects: map (lib.removePrefix "group:") (lib.filter (lib.hasPrefix "group:") (lib.flatten subjects));
  realm = (import ../../modules/lab-export.nix { inherit lib lab; }).ldap;
  realmHost = inventory.${toString realm.vmid}.name;
  directory = configs.${realmHost};
  open = directory.networking.firewall.allowedTCPPorts;
  ldaps = directory.services.lldap.settings.ldaps_options or { };
  plainPort = directory.services.lldap.settings.ldap_port;

  namedOf = settings: groupsOf (map (r: r.subject or [ ]) settings.access_control.rules)
    ++ groupsOf (lib.mapAttrsToList (_: p: map (r: r.subject) p.rules) settings.identity_providers.oidc.authorization_policies);
in
lib.optional (lib.length lldapHosts != 1) "lldap runs on [ ${toString lldapHosts} ], not on exactly one host"
++ lib.concatMap (host: lib.concatLists (lib.mapAttrsToList (instance: a:
  map (group: "${host}: authelia ${instance} admits group ${group}, which lldap's bootstrap never creates")
    (lib.subtractLists lldapGroups (lib.unique (namedOf a.settings)))
) configs.${host}.services.authelia.instances)) autheliaHosts
++ lib.optional (!(directory.services.lldap.enable && (ldaps.enabled or false) && (ldaps.port or null) == realm.port))
  "proxmox realm: ${realmHost} serves no ldaps on port ${toString realm.port}"
++ lib.optional (!lib.elem realm.port open) "proxmox realm: ${realmHost} does not open its ldaps port ${toString realm.port}"
++ lib.optional (lib.elem plainPort open) "proxmox realm: ${realmHost} opens plain ldap (${toString plainPort}) to the network"
