{ pkgs, nasMount, ... }:
let
  # Local inference on the Hermes VM (vm-126). No external AI provider, no API key.
  ollamaUrl = "http://10.100.0.126:11434";
  ollamaModel = "hermes3:8b";
in {
  networking.hostName = "vm-125";

  fileSystems = nasMount "/var/lib/paperless-ai" "paperless-ai"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  # paperless-ai reads its settings from /app/data/.env, which the setup wizard
  # normally writes. Seed it from the Paperless API token vm-113 already exports,
  # so the stack comes up configured without a manual wizard pass.
  systemd.services.paperless-ai-config = {
    description = "Seed paperless-ai configuration";
    before = [ "podman-paperless-ai.service" ];
    requiredBy = [ "podman-paperless-ai.service" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 30;
    };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/paperless-key.token"
      # vm-113 generates the token on first boot; wait for it rather than
      # writing a config that silently cannot talk to Paperless.
      for i in $(seq 1 60); do
        [ -s "$TOKEN_FILE" ] && break
        sleep 5
      done
      [ -s "$TOKEN_FILE" ] || { echo "Paperless API token not available"; exit 1; }

      mkdir -p /var/lib/paperless-ai
      umask 077
      cat > /var/lib/paperless-ai/.env <<EOF
      PAPERLESS_API_URL=http://10.100.0.113:8080/api
      PAPERLESS_API_TOKEN=$(cat "$TOKEN_FILE")
      AI_PROVIDER=ollama
      OLLAMA_API_URL=${ollamaUrl}
      OLLAMA_MODEL=${ollamaModel}
      SCAN_INTERVAL=*/30 * * * *
      ACTIVATE_TAGGING=yes
      ACTIVATE_CORRESPONDENTS=yes
      ACTIVATE_DOCUMENT_TYPE=yes
      ACTIVATE_TITLE=yes
      ACTIVATE_CUSTOM_FIELDS=no
      RESTRICT_TO_EXISTING_TAGS=no
      RESTRICT_TO_EXISTING_CORRESPONDENTS=no
      RESTRICT_TO_EXISTING_DOCUMENT_TYPES=no
      TOKEN_LIMIT=128000
      RESPONSE_TOKENS=1000
      EOF
      chown 1000:1000 /var/lib/paperless-ai/.env
    '';
  };

  virtualisation.oci-containers.containers.paperless-ai = {
    image = "docker.io/clusterzx/paperless-ai:latest";
    ports = [ "80:3000" ];
    volumes = [ "/var/lib/paperless-ai:/app/data" ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      PAPERLESS_AI_PORT = "3000";
      # RAG service runs inside the same container.
      RAG_SERVICE_URL = "http://localhost:8000";
      RAG_SERVICE_ENABLED = "true";
    };
    extraOptions = [ "--cap-drop=ALL" "--security-opt=no-new-privileges" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/paperless-ai 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
