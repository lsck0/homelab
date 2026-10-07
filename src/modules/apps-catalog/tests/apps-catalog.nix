# the app catalog's schema and lab-wide rules (modules/apps-catalog, modules/catalog.nix), table by table, at
# evaluation time: every broken catalog below fails with a message that names the fix, every well-formed one holds
# and evaluates through the hosts that consume it (router, edge, ingress, grafana, the swarm manager, the builder).
# Each refusal is one change to a catalog the positive control accepts.
{ pkgs, lib, inputs, specialArgs, ... }:
let
  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  base = specialArgs.lab.appsCatalog;
  # a well-formed app every case changes one thing of
  demo = {
    enable = true;
    repo = "lsck0/demo";
    branch = "master";
    routes.demo = { service = "web"; targetPort = 8000; port = 20130; off.sso = "the test's public fixture"; };
  };
  withApps = apps: lib.recursiveUpdate base { inherit apps; };
  withDemo = change: withApps { demo = lib.recursiveUpdate demo change; };

  evalCatalog = catalog: lib.evalModules {
    modules = [
      ../default.nix
      {
        options.assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
        config = {
          _module.args = { inherit (specialArgs) inventory site lab; };
          homelab.appsCatalog = catalog;
        };
      }
    ];
  };
  problemsOf = catalog: (evalCatalog catalog)._module.args.catalog.problems;
  # a schema error is a throw of the module system, which evaluation can catch
  evaluates = catalog: (builtins.tryEval (builtins.deepSeq (evalCatalog catalog).config.homelab.appsCatalog true)).success;

  # -----------------------------------------------------------------------------
  # TABLES
  # -----------------------------------------------------------------------------

  # catalog -> a line of the problems must contain this
  refused = {
    duplicate-port = { catalog = withApps { demo = demo; other = demo // { repo = "lsck0/other"; }; }; expect = "port 20130 is published for"; };
    port-outside-range = { catalog = withDemo { routes.demo.port = 8080; }; expect = "outside swarm.portRange"; };
    host-of-a-lab-service = { catalog = withDemo { routes.demo.host = "git"; }; expect = "host git.lsck0.dev is claimed by"; };
    route-of-a-lab-service = {
      catalog = withDemo { routes.grafana = { zone = "internal"; port = 20131; }; };
      expect = "route name grafana is claimed by";
    };
    host-in-both-zones = {
      catalog = withDemo { routes.demo-admin = { zone = "internal"; host = "demo"; port = 20131; }; };
      expect = "host demo.lsck0.dev is routed by both ingresses";
    };
    secret-without-generator = { catalog = withDemo { env.web.PASSWORD = "{{demo-password}}"; }; expect = "which `secrets` does not generate"; };
    generator-without-reference = { catalog = withDemo { secrets.demo-password = "hex:24"; }; expect = "is named by no env value"; };
    unknown-placeholder = { catalog = withDemo { env.web.A = "{{DEMO_PASSWORD}}"; }; expect = "is neither a secret"; };
    unknown-lab-endpoint = { catalog = withDemo { env.web.A = "{{homelab.loki}}"; }; expect = "is no lab endpoint"; };
    telemetry-endpoint-without-telemetry = {
      catalog = withDemo { off = { traces = "none"; profiles = "none"; }; env.web.A = "{{homelab.otlp-grpc}}"; };
      expect = "with traces and profiles off";
    };
    dump-of-a-stateless-service = { catalog = withDemo { dumps.db = { service = "db"; command = "true"; }; }; expect = "is not stateful"; };
    limits-above-a-worker = { catalog = withDemo { resources.web.memoryMiB = 8192; }; expect = "above swarm.taskMax.memoryMiB"; };
    excluded-but-used = { catalog = withDemo { exclude = [ "web" ]; }; expect = "drops web"; };
    publishes-nothing = { catalog = withDemo { routes = lib.mkForce { }; }; expect = "publishes nothing"; };
    app-name = { catalog = withApps { Demo = lib.recursiveUpdate demo { routes.demo.host = "demo"; }; }; expect = "an app name is"; };
    service-key = { catalog = withApps { grafana = demo; }; expect = "is an instance service's too"; };
    cadvisor-in-range = { catalog = lib.recursiveUpdate base { cadvisorPort = 20500; }; expect = "cadvisorPort 20500 lies inside"; };
    idle-tcp = {
      catalog = withDemo { routes.demo-game = { protocol = "tcp"; publicPort = 25565; port = 20131; }; idle.stopAfter = "30m"; };
      expect = "route demo-game: a tcp route goes from the router straight to its backend";
    };
  };

  # catalogs the schema itself rejects: an unknown field, a wrong type, a missing field
  invalid = {
    unknown-field = withDemo { statefull = [ "db" ]; };
    port-as-string = withDemo { routes.demo.port = "20130"; };
    trailing-slash = withDemo { routes.demo.path = "/api/"; };
    unknown-feature = withDemo { routes.demo.off.ssso = "a typo"; };
    missing-repo = withApps { demo = removeAttrs demo [ "repo" ]; };
    unpinned-image = withDemo { images = [ "docker.io/library/redis:8" ]; };
    climbing-build = withDemo { build.web.context = "../other"; };
    unknown-generator = withDemo { secrets.x = "random"; env.web.X = "{{x}}"; };
  };

  # every app of the real catalog enabled, an app left disabled by omission, an internal-only app
  accepted = {
    production = base;
    everything-enabled = lib.recursiveUpdate base { apps = lib.mapAttrs (_: _: { enable = true; }) base.apps; };
    enable-omitted = withApps { demo = removeAttrs demo [ "enable" ]; };
    internal-only = withApps { demo = removeAttrs demo [ "routes" ] // { routes.demo-admin = { zone = "internal"; port = 20131; }; }; };
    # repo and branch only: one route at demo.<domain>, behind the edge and authelia
    defaults-only = withApps { demo = removeAttrs demo [ "routes" ]; };
  };

  # the hosts that read the catalog, evaluated with it: what a consumer would choke on shows here
  consumers = {
    "300-router" = c: c.networking.nftables.ruleset;
    "200-external-traefik" = c: c.services.traefik.dynamicConfigOptions;
    "100-internal-traefik" = c: c.services.traefik.dynamicConfigOptions;
    "105-internal-grafana" = c: c.services.prometheus.scrapeConfigs;
    "140-internal-swarm" = c: map (unit: c.systemd.services.${unit}.serviceConfig.ExecStart) [ "swarm-converge" "app-builder" ];
    "250-apps-swarm" = c: c.networking.firewall.extraCommands;
  };
  # rendered as json: a store path stays a string, nothing is built
  consumerEvaluates = catalog: host: select: (builtins.tryEval (builtins.toJSON (select
    (inputs.self.nixosConfigurations.${host}.extendModules { modules = [ { homelab.appsCatalog = lib.mkForce catalog; } ]; }).config))).success;

  # -----------------------------------------------------------------------------
  # RESULTS
  # -----------------------------------------------------------------------------

  failures =
    lib.concatLists (lib.mapAttrsToList (name: c: let problems = problemsOf c.catalog; in
      lib.optional (!(lib.any (lib.hasInfix c.expect) problems))
        "refused.${name}: no problem says \"${c.expect}\"; problems: ${builtins.toJSON problems}") refused)
    ++ lib.concatLists (lib.mapAttrsToList (name: catalog:
      lib.optional (evaluates catalog) "invalid.${name}: the schema accepted it") invalid)
    ++ lib.concatLists (lib.mapAttrsToList (name: catalog: let problems = problemsOf catalog; in
      lib.optional (!(evaluates catalog)) "accepted.${name}: the schema rejected it"
      ++ map (p: "accepted.${name}: ${p}") problems
      ++ lib.concatLists (lib.mapAttrsToList (host: select:
        lib.optional (!(consumerEvaluates catalog host select)) "accepted.${name}: ${host} does not evaluate with it") consumers)
    ) accepted);
  count = attrs: toString (lib.length (lib.attrNames attrs));
in
pkgs.runCommand "apps-catalog" { } (if failures == [ ] then ''
  echo "apps-catalog: ${count refused} refusals, ${count invalid} schema rejections and ${count accepted} accepted catalogs hold"
  touch $out
'' else ''
  echo "apps-catalog: ${toString (lib.length failures)} failure(s):" >&2
  cat ${pkgs.writeText "apps-catalog-failures" (lib.concatLines failures)} >&2
  exit 1
'')
