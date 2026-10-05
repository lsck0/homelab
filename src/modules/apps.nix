# the app catalog: a github repo and a branch per app, everything else is derived
#
# The builder on vm-117 (services/app-builder.nix) watches each enabled app's branch, builds the images of a new
# commit in the lab, parks them in registry.lsck0.dev pinned by digest, and hands the stack to a swarm manager
# in the apps zone (modules/swarm.nix), which layers the homelab on top: published ports, secrets from sops,
# encrypted overlay networks, state pinned to one node, and a policy check that refuses anything privileged.
# The edge (200-external-traefik.nix) routes `paths` behind crowdsec, anubis and the rate limits, the internal
# ingress routes `internal` behind authelia, vm-105 scrapes `metrics`, and the router opens exactly these ports.
#
# Per app, all optional but repo and branch:
#   enable     false: not built, deployed, routed, scraped or alerted on
#   repo       "owner/name" on github; branch: the branch deployed
#   stack      compose file in the repo; null: compose.yaml, docker-compose.yml or stack.yaml at the root,
#              else one service "web" built from the root Dockerfile
#   build      service -> { context; dockerfile; } for stack services that only name an image
#   watch      repo paths: deploy only when a commit touches them (an app inside a busier repo)
#   host       <host>.lsck0.dev on the public edge; default: the app's name
#   paths      url prefix -> { service; targetPort; port; anubis; waf; bodyLimit; health; }: port is the published
#              one, unique across apps; anubis defaults to "/" only, waf to on, bodyLimit to the template's 1 MiB
#   internal   <host> -> { service; targetPort; port }: behind authelia on the internal ingress
#   exclude    stack services the homelab replaces (monitoring, edge proxies)
#   stateful   services with volumes, pinned to the node labelled for state and backed up from it
#   dumps      name -> { service; command; }: a dump command run in the service's container, nightly to the nas
#   env        KEY -> value for every service; "{{name}}" is the sops secret <name>, see `secrets`
#   secrets    sops secret name -> generator for scripts/secrets-sync.sh ("hex:<bytes>", "garage-key-id")
#   override   compose overlay merged last (nix attrs)
#   headers    extra traefik headers settings on the app's public routes (csp, permissions policy, ...)
#   images     public images a stack may run besides its own builds, each pinned by digest
#   metrics    name -> { port; targetPort; service; path; } scraped every 15s by vm-105, never routed
#   telemetry  otlp traces and pyroscope profiles go to vm-105
let
  # a tcp forwarder, pinned: the one public image a stack here runs
  socat = "docker.io/alpine/socat:1.8.1.3@sha256:82ad20f6f6e29b91ff33b6662d24063522b1378f08fd8569cd3ab412cac13f50";
in
{
  apps = {
    # the ci demo: example/ in this repo, a c http server
    hello = {
      enable = true;
      repo = "lsck0/homelab";
      branch = "master";
      build.web = { context = "example"; dockerfile = "example/Dockerfile"; };
      # this repo moves with every sync; hello only with its own directory
      watch = [ "example" ];
      host = "hello";
      paths."/" = { service = "web"; targetPort = 8000; port = 20100; };
    };

    # nyangine's examples/web_server: one scratch image, the notes server
    nyangine = {
      enable = false;
      repo = "lsck0/nyangine";
      branch = "master";
      stack = "examples/web_server/deploy/stack.yaml";
      build.web = { context = "."; dockerfile = "examples/web_server/Dockerfile"; };
      host = "nyangine";
      paths."/" = { service = "web"; targetPort = 8000; port = 20110; };
      stateful = [ "web" ];
      env.WEB_SERVER_ORIGIN = "https://nyangine.lsck0.dev";
    };

    # webapp-template's core; its own monitoring and edge services stay out, the homelab provides them
    wat = {
      enable = false;
      repo = "lsck0/webapp-template";
      branch = "master";
      stack = "infrastructure/prod.compose.yml";
      # infrastructure/scripts/deploy.sh's image list, for the services the homelab keeps
      build = {
        ai = { context = "services/core/ai"; dockerfile = "services/core/ai/.docker/prod.Dockerfile"; };
        client = { context = "services/core/client"; dockerfile = "services/core/client/.docker/prod.Dockerfile"; };
        ollama = { context = "services/core/ollama"; dockerfile = "services/core/ollama/Dockerfile"; };
        server = { context = "services/core/server"; dockerfile = "services/core/server/.docker/prod.Dockerfile"; };
        pgweb = { context = "services/monitoring/pgweb"; dockerfile = "services/monitoring/pgweb/Dockerfile"; };
        postgres-metrics = { context = "services/monitoring/postgres-metrics"; dockerfile = "services/monitoring/postgres-metrics/Dockerfile"; };
        redis-metrics = { context = "services/monitoring/redis-metrics"; dockerfile = "services/monitoring/redis-metrics/Dockerfile"; };
        garage = { context = "services/storage/garage"; dockerfile = "services/storage/garage/Dockerfile"; };
        postgres = { context = "services/storage/postgres"; dockerfile = "services/storage/postgres/Dockerfile"; };
        redis = { context = "services/storage/redis"; dockerfile = "services/storage/redis/Dockerfile"; };
      };
      host = "wat";
      paths = {
        "/" = { service = "client"; targetPort = 80; port = 20120; };
        "/api" = { service = "server"; targetPort = 80; port = 20121; health = "/api/health"; };
        # presigned s3 urls into garage: no anubis, no waf, the template's 100 MiB upload cap
        "/user-files" = { service = "garage"; targetPort = 3900; port = 20122; anubis = false; waf = false; bodyLimit = 100 * 1024 * 1024; };
      };
      # the sql console, never public
      internal.wat-db = { service = "pgweb"; targetPort = 8081; port = 20123; };
      # consistent sql, nightly to the nas; the volume itself is not mirrored
      dumps.postgres = { service = "postgres"; command = "pg_dumpall -U admin"; };
      exclude = [
        "nginx" "anubis" "labyrinth"
        "autoheal" "cadvisor" "grafana" "loki" "nginx-metrics" "prometheus" "promtail" "tempo"
      ];
      stateful = [ "postgres" "redis" "garage" "ollama" ];
      env = {
        PUBLIC_URL = "https://wat.lsck0.dev";
        OTEL_EXPORTER_OTLP_ENDPOINT = "http://10.100.0.105:4317";
        # swarm fills these per task; they are loki's host and container_name, so a trace links to its logs
        OTEL_RESOURCE_ATTRIBUTES = "host.name={{.Node.Hostname}},container.name={{.Service.Name}}.{{.Task.Slot}}";
        DEFAULT_USER_PASSWORD = "{{wat-default-user-password}}";
        POSTGRES_PASSWORD = "{{wat-postgres-password}}";
        PGPASSWORD = "{{wat-postgres-password}}";
        DATABASE_URL = "postgres://admin:{{wat-postgres-password}}@postgres:5432/root";
        POSTGRES_ROOT_PASSWORD = "{{wat-postgres-root-password}}";
        PGWEB_AUTH_USER = "admin";
        PGWEB_AUTH_PASS = "{{wat-pgweb-password}}";
        GARAGE_RPC_SECRET = "{{wat-garage-rpc-secret}}";
        GARAGE_ROOT_KEY_ID = "{{wat-garage-root-key-id}}";
        GARAGE_ROOT_SECRET_KEY = "{{wat-garage-root-secret}}";
        AWS_ACCESS_KEY_ID = "{{wat-garage-root-key-id}}";
        AWS_SECRET_ACCESS_KEY = "{{wat-garage-root-secret}}";
        GARAGE_FILES_KEY_ID = "{{wat-garage-files-key-id}}";
        GARAGE_FILES_SECRET_KEY = "{{wat-garage-files-secret}}";
      };
      secrets = {
        wat-default-user-password = "hex:24";
        wat-postgres-password = "hex:24";
        wat-postgres-root-password = "hex:24";
        wat-pgweb-password = "hex:24";
        wat-garage-rpc-secret = "hex:32";
        wat-garage-root-key-id = "garage-key-id";
        wat-garage-root-secret = "hex:32";
        wat-garage-files-key-id = "garage-key-id";
        wat-garage-files-secret = "hex:32";
      };
      images = [ socat ];
      # the rust server pushes profiles to a hardcoded http://pyroscope:4040; this stand-in forwards them to vm-105
      override.services.pyroscope = {
        image = socat;
        command = [ "TCP-LISTEN:4040,fork,reuseaddr" "TCP:10.100.0.105:4040" ];
      };
      metrics = {
        server = { service = "server"; targetPort = 80; port = 20121; path = "/api/metrics"; };
        postgres = { service = "postgres-metrics"; targetPort = 9187; port = 20124; path = "/metrics"; };
        redis = { service = "redis-metrics"; targetPort = 9121; port = 20125; path = "/metrics"; };
        garage = { service = "garage"; targetPort = 3903; port = 20126; path = "/metrics"; };
      };
      telemetry = true;
      # services/core/nginx/security_headers.conf; the edge's own frame DENY and referrer policy are stricter
      headers = {
        contentSecurityPolicy = builtins.concatStringsSep " " [
          "base-uri 'self'; connect-src 'self'; default-src 'self'; font-src 'self' data:; form-action 'self';"
          "frame-ancestors 'self'; frame-src 'none'; img-src 'self' data:; media-src 'self' data:; object-src 'none';"
          "script-src 'self'; style-src 'self' 'unsafe-inline'; upgrade-insecure-requests; worker-src 'self';"
        ];
        permissionsPolicy = "geolocation=(), microphone=(), camera=(), fullscreen=(), payment=(), usb=(), accelerometer=(), gyroscope=(), magnetometer=(), autoplay=()";
        customResponseHeaders."Cache-Control" = "no-store";
      };
    };
  };

  # the swarm's manager, in the internal zone; every running vm of type "apps" is a worker
  swarm.manager = 140;
  # the worker holding every stateful service's volumes, dumped and backed up from there; moving it moves no data
  swarm.state = 150;

  # per-worker container metrics, scraped on every worker
  cadvisorPort = 9338;
}
