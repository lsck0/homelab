# webapp-template's core; its own monitoring and edge services stay out, the homelab provides them
let
  public = "the template's public web app";
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
  # the server's published port: its api route and its metrics
  serverPort = 20121;
  # a tcp forwarder, pinned: the one public image the stack runs besides its own builds
  socat = "docker.io/alpine/socat:1.8.1.3@sha256:82ad20f6f6e29b91ff33b6662d24063522b1378f08fd8569cd3ab412cac13f50";
in
{
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
  routes = {
    wat = { service = "client"; targetPort = 80; port = 20120; off.sso = public; inherit headers; };
    wat-api = {
      path = "/api";
      service = "server";
      targetPort = 80;
      port = serverPort;
      health = "/api/health";
      off = { sso = public; anubis = "api calls run no proof of work"; };
      inherit headers;
    };
    # presigned s3 urls into garage, with the template's 100 MiB upload cap
    wat-user-files = {
      path = "/user-files";
      service = "garage";
      targetPort = 3900;
      port = 20122;
      bodyLimitBytes = 100 * 1024 * 1024;
      off = { sso = public; anubis = "presigned urls are fetched by scripts"; waf = "file uploads the rules misread"; };
      inherit headers;
    };
    # the sql console, never public; pgweb asks for its basic auth on /, so no health check
    wat-db = { zone = "internal"; host = "wat-db"; service = "pgweb"; targetPort = 8081; port = 20123; health = null; };
  };
  # consistent sql, nightly to the nas; the volume itself is not archived (see `volumes`)
  dumps.postgres = { service = "postgres"; command = "pg_dumpall -U admin"; };
  exclude = [
    "nginx" "anubis" "labyrinth"
    "autoheal" "cadvisor" "grafana" "loki" "nginx-metrics" "prometheus" "promtail" "tempo"
  ];
  stateful = [ "postgres" "redis" "garage" "ollama" ];
  volumes = {
    # user uploads behind /user-files: archived nightly
    prod_garage_data.backup = true;
    # `dumps` is the consistent copy; a file copy of a live cluster is not
    prod_postgres_data.backup = false;
    # sessions and caches, rebuilt on start
    prod_redis_data.backup = false;
    # models, pulled again
    prod_ollama_data.backup = false;
  };
  # per service, from the template's own scripts: a secret reaches only the services that read it
  env = let
    otel = {
      OTEL_EXPORTER_OTLP_ENDPOINT = "{{homelab.otlp-grpc}}";
      # swarm fills these per task; they are loki's host and container_name, so a trace links to its logs
      OTEL_RESOURCE_ATTRIBUTES = "host.name={{.Node.Hostname}},container.name={{.Service.Name}}.{{.Task.Slot}}";
    };
    garageFiles = {
      GARAGE_FILES_KEY_ID = "{{wat-garage-files-key-id}}";
      GARAGE_FILES_SECRET_KEY = "{{wat-garage-files-secret}}";
    };
    garageRoot = {
      AWS_ACCESS_KEY_ID = "{{wat-garage-root-key-id}}";
      AWS_SECRET_ACCESS_KEY = "{{wat-garage-root-secret}}";
    };
    postgresRoot.POSTGRES_ROOT_PASSWORD = "{{wat-postgres-root-password}}";
  in {
    server = otel // garageFiles // {
      PUBLIC_URL = "https://wat.lsck0.dev";
      DEFAULT_USER_PASSWORD = "{{wat-default-user-password}}";
      DATABASE_URL = "postgres://admin:{{wat-postgres-password}}@postgres:5432/root";
    };
    ai = otel;
    # initdb, its init.sh (the root role) and the wal-g loop into garage
    postgres = postgresRoot // garageRoot // {
      POSTGRES_PASSWORD = "{{wat-postgres-password}}";
      PGPASSWORD = "{{wat-postgres-password}}";
    };
    pgweb = postgresRoot // {
      PGWEB_AUTH_USER = "admin";
      PGWEB_AUTH_PASS = "{{wat-pgweb-password}}";
    };
    postgres-metrics = postgresRoot;
    # start.sh creates the root and the files keys
    garage = garageFiles // {
      GARAGE_RPC_SECRET = "{{wat-garage-rpc-secret}}";
      GARAGE_ROOT_KEY_ID = "{{wat-garage-root-key-id}}";
      GARAGE_ROOT_SECRET_KEY = "{{wat-garage-root-secret}}";
    };
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
    command = [ "TCP-LISTEN:4040,fork,reuseaddr" "TCP:{{homelab.pyroscope}}" ];
  };
  # the postgres service's wal-g loop pushes a base backup into garage nightly
  alerts.walg_stale = let staleSeconds = 26 * 3600; in {
    title = "wat WAL-G backup stale";
    category = "backups";
    datasource = "loki";
    rangeSeconds = staleSeconds;
    expr = "sum(count_over_time({swarm_service=\"wat_postgres\"} |= \"Backup completed successfully\" [${toString staleSeconds}s]))";
    op = "lt"; threshold = 1;
    for = "30m";
    # no success line in the window is no series at all
    noData = "Alerting";
    severity = "critical"; telegram = true;
    summary = "wat postgres: no WAL-G base backup in over 26h";
    description = "The stack's wal-g loop has not logged a successful backup-push. Its log: {swarm_service=\"wat_postgres\"} in Loki.";
  };
  metrics = {
    server = { service = "server"; targetPort = 80; port = serverPort; path = "/api/metrics"; };
    postgres = { service = "postgres-metrics"; targetPort = 9187; port = 20124; path = "/metrics"; };
    redis = { service = "redis-metrics"; targetPort = 9121; port = 20125; path = "/metrics"; };
    garage = { service = "garage"; targetPort = 3903; port = 20126; path = "/metrics"; };
  };
}
