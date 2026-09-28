{ pkgs, nasMount, retry, ... }:
let
  # local ollama beside jellyfin on the rtx 2060; documents stay in the lab
  llmUrl = "http://10.100.0.134:11434";
  llmModel = "qwen3:4b";
in {
  networking.hostName = "vm-122";

  fileSystems = nasMount "/var/lib/paperless-ai" "paperless-ai"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  # settings live in /app/data/.env, normally wizard-written
  # new .env: restart the app with it
  systemd.services.podman-paperless-ai.restartTriggers = [ llmModel llmUrl ];
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
      # wait for vm-121's token, never write a dead config
      ${retry} 60 5 test -s "$TOKEN_FILE" || { echo "Paperless API token not available"; exit 1; }

      mkdir -p /var/lib/paperless-ai
      umask 077
      cat > /var/lib/paperless-ai/.env <<EOF
      PAPERLESS_API_URL=http://10.100.0.121:8080/api
      PAPERLESS_API_TOKEN=$(cat "$TOKEN_FILE")
      AI_PROVIDER=ollama
      OLLAMA_API_URL=${llmUrl}
      OLLAMA_MODEL=${llmModel}
      SCAN_INTERVAL=*/5 * * * *
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
    image = "docker.io/clusterzx/paperless-ai:3.0.9";
    ports = [ "80:3000" ];
    volumes = [ "/var/lib/paperless-ai:/app/data" ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      PAPERLESS_AI_PORT = "3000";
      # rag loads a local embedding model and thrashed the vm; classification skips it
      RAG_SERVICE_ENABLED = "false";
    };
    extraOptions = [ "--cap-drop=ALL" "--security-opt=no-new-privileges" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/paperless-ai 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
