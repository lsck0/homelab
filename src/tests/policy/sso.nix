# every group authelia admits through (a forwardauth rule's subject, an oidc client's policy) exists in lldap's
# bootstrap: a group nobody can be put in leaves its page to the admins alone and `lab-user add` fails on it.
# The proxmox realm binds where the lab export says (scripts/pve-install.nu): that guest serves ldaps there, and its
# plain ldap, which would carry the password in clear, is closed to the network.
# The sso session reaches authelia and the portal alone: every other router of an ingress strips it, but a relay, which
# leaves it to the ingress it relays to. A backend that logs or replays it would hold every sso route of its user.
{
  lib,
  configs,
  lab,
  inventory,
  site,
  ...
}:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  hostsOf = running: lib.attrNames (lib.filterAttrs (_: running) configs);
  ingressHosts = hostsOf (c: c.services.traefik.enable);
  portal = "Host(`${net.fqdn lab.routes.authelia.host}`)";
  # a forwardauth whose answer replaces the request's cookies, by a gate that drops the session from them
  rewritesCookies = http: m: lib.elem "Cookie" ((http.middlewares.${m} or { }).forwardAuth.authResponseHeaders or [ ]);
  sessionKept =
    host: name: router:
    let
      middlewares = router.middlewares or [ ];
      inherit (configs.${host}.services.traefik.dynamicConfigOptions) http;
      stripped =
        lib.any (rewritesCookies http) middlewares
        && lib.elem net.autheliaSessionCookie configs.${host}.homelab.traefik.gate.settings.stripCookies;
    in
    lib.optional (
      !(
        lib.elem "authelia" middlewares
        || lib.hasSuffix "-relay" (router.service or "")
        || lib.hasInfix portal router.rule
        || stripped
      )
    ) "${host}: router ${name} hands the sso session to its backend";
  autheliaHosts = hostsOf (c: c.services.authelia.instances != { });
  lldapHosts = hostsOf (c: c.services.lldap.enable);
  lldapGroups = lib.concatMap (
    host: lib.splitString " " configs.${host}.systemd.services.lldap-bootstrap.environment.BOOTSTRAP_GROUPS
  ) lldapHosts;

  groupsOf = subjects: map (lib.removePrefix "group:") (lib.filter (lib.hasPrefix "group:") (lib.flatten subjects));
  realm = (import ../../modules/lab-export.nix { inherit lib lab; }).ldap;
  realmHost = inventory.${toString realm.vmid}.name;
  directory = configs.${realmHost};
  open = directory.networking.firewall.allowedTCPPorts;
  ldaps = directory.services.lldap.settings.ldaps_options or { };
  plainPort = directory.services.lldap.settings.ldap_port;

  namedOf =
    settings:
    groupsOf (map (r: r.subject or [ ]) settings.access_control.rules)
    ++ groupsOf (
      lib.mapAttrsToList (_: p: map (r: r.subject) p.rules) settings.identity_providers.oidc.authorization_policies
    );
in
lib.concatMap (
  host:
  lib.concatLists (
    lib.mapAttrsToList (sessionKept host) (
      lib.filterAttrs (
        _: r: lib.elem "websecure" (r.entryPoints or [ ])
      ) configs.${host}.services.traefik.dynamicConfigOptions.http.routers
    )
  )
) ingressHosts
++ lib.optional (lib.length lldapHosts != 1) "lldap runs on [ ${toString lldapHosts} ], not on exactly one host"
++ lib.concatMap (
  host:
  lib.concatLists (
    lib.mapAttrsToList (
      instance: a:
      map (group: "${host}: authelia ${instance} admits group ${group}, which lldap's bootstrap never creates") (
        lib.subtractLists lldapGroups (lib.unique (namedOf a.settings))
      )
    ) configs.${host}.services.authelia.instances
  )
) autheliaHosts
++ lib.optional (
  !(directory.services.lldap.enable && (ldaps.enabled or false) && (ldaps.port or null) == realm.port)
) "proxmox realm: ${realmHost} serves no ldaps on port ${toString realm.port}"
++ lib.optional (
  !lib.elem realm.port open
) "proxmox realm: ${realmHost} does not open its ldaps port ${toString realm.port}"
++ lib.optional (lib.elem plainPort open) "proxmox realm: ${realmHost} opens plain ldap (${toString plainPort}) to the network"
