# paperless-ai: llm tagging for paperless; the host mounts /var/lib/homepage-tokens
{ lib, pkgs, nasMount, retry, hostIp, ... }:
let
  # local ollama beside jellyfin on the rtx 2060; documents stay in the lab
  llmUrl = "http://10.100.0.134:11434";
  # 7b: 4b left titles empty; no thinking model, answers are capped at 256 tokens
  llmModel = "qwen2.5:7b-instruct";
  prompt = lib.concatStringsSep " " [
    "Du analysierst deutsche Dokumente (Briefe, Rechnungen, Bescheide), oft als Handyfoto mit OCR-Fehlern."
    "Titel: kurz, deutsch, beschreibend, mit Absender und Gegenstand, z.B. 'Abwassergebühren 2026 Zweckverband Obereichsfeld'."
    "Korrespondent: die absendende Organisation oder Person, nie der Empfänger, keine Adressen oder Kundennummern."
    "Tags nur aus der vorgegebenen Liste, höchstens drei."
    "Datum: das Ausstellungsdatum des Dokuments."
  ];
in {
  fileSystems = nasMount "/var/lib/paperless-ai" "paperless-ai";

  # settings live in /app/data/.env, normally wizard-written
  # new .env: restart the app with it
  systemd.services.podman-paperless-ai.restartTriggers = [ llmModel llmUrl "homepage-bot" prompt "restrict-v2" ];
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
      # wait for paperless-setup's token, never write a dead config
      ${retry} 60 5 test -s "$TOKEN_FILE" || { echo "Paperless API token not available"; exit 1; }

      mkdir -p /var/lib/paperless-ai
      umask 077
      cat > /var/lib/paperless-ai/.env <<EOF
      # the host address: the container's loopback is its own
      PAPERLESS_API_URL=http://${hostIp}:8080/api
      PAPERLESS_API_TOKEN=$(cat "$TOKEN_FILE")
      # owner of that token (paperless-setup); unset aborts every scan
      PAPERLESS_USERNAME=homepage-bot
      AI_PROVIDER=ollama
      OLLAMA_API_URL=${llmUrl}
      OLLAMA_MODEL=${llmModel}
      SCAN_INTERVAL=*/5 * * * *
      ACTIVATE_TAGGING=yes
      ACTIVATE_CORRESPONDENTS=yes
      # types come from paperless keyword matching
      ACTIVATE_DOCUMENT_TYPE=no
      ACTIVATE_TITLE=yes
      ACTIVATE_CUSTOM_FIELDS=no
      RESTRICT_TO_EXISTING_TAGS=yes
      RESTRICT_TO_EXISTING_CORRESPONDENTS=no
      SYSTEM_PROMPT="${prompt}"
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
  # its /setup page asks for no login and the container holds the paperless api token
  homelab.ingressOnly.ports = [ 80 ];

  # consistent copy for the snapshot, the live file may be mid-write
  homelab.dbBackup.databases.paperless-ai.sqlite = "/var/lib/paperless-ai/documents.db";
}
