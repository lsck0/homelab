# paperless-ai: llm tagging for paperless
{ config, lib, pkgs, retry, hostIp, ... }:
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
  # its sqlite runs in wal mode, which nfs breaks; local, the nas keeps a nightly copy
  homelab.localState.paperless-ai = {
    path = "/var/lib/paperless-ai";
    share = "paperless-ai";
    unit = "podman-paperless-ai";
    sqlite = [ "documents.db" ];
    # paperless-ai-config rewrites it, with the api token, on every start
    exclude = [ ".env" ];
  };

  # settings live in /app/data/.env, normally wizard-written
  # new .env: restart the app with it
  systemd.services.podman-paperless-ai.restartTriggers = [ config.systemd.services.paperless-ai-config.script ];
  systemd.services.paperless-ai-config = {
    description = "Seed paperless-ai configuration";
    before = [ "podman-paperless-ai.service" ];
    requiredBy = [ "podman-paperless-ai.service" ];
    after = [ "paperless-ai-seed.service" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 30;
    };
    script = ''
      TOKEN_FILE="${config.homelab.tokens.dir}/paperless-key.token"
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
    # measured 1.3g resident, half again as headroom
    extraOptions = [ "--cap-drop=ALL" "--security-opt=no-new-privileges" "--memory=2g" ];
  };

  # the app runs as the container's root without capabilities (no DAC override), so its state must be root's own
  systemd.tmpfiles.rules = [
    "d /var/lib/paperless-ai 0700 root root -"
    "Z /var/lib/paperless-ai - root root -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
  # its /setup page asks for no login and the container holds the paperless api token
  homelab.ingressOnly.ports = [ 80 ];

  # consistent copy for the snapshot, the live file may be mid-write
  homelab.dbBackup.databases.paperless-ai.sqlite = "/var/lib/paperless-ai/documents.db";
}
