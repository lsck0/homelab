# paperless-ai: llm tagging for paperless
{ config, lib, pkgs, inventory, hostIp, catalog, ... }:
let
  port = catalog.internal.paperless-ai.port;
  containerPort = 3000;
  stateDir = "/var/lib/paperless-ai";
  # the local ollama on vm-134's gpu; documents stay in the lab
  ollama = import ../../../modules/ollama.nix;
  llmUrl = "http://${inventory.${toString ollama.vmid}.ip}:${toString ollama.port}";
  # its own superuser, ../main.nix says why
  apiUser = "paperless-ai";
  prompt = lib.concatStringsSep " " [
    "Du analysierst deutsche Dokumente (Briefe, Rechnungen, Bescheide), oft als Handyfoto mit OCR-Fehlern."
    "Titel: kurz, deutsch, beschreibend, mit Absender und Gegenstand, z.B. 'Abwassergebühren 2026 Stadtwerke Musterstadt'."
    "Korrespondent: die absendende Organisation oder Person, nie der Empfänger, keine Adressen oder Kundennummern."
    "Tags nur aus der vorgegebenen Liste, höchstens drei."
    "Datum: das Ausstellungsdatum des Dokuments."
  ];
in {
  # its sqlite runs in wal mode, which nfs breaks; local, the nas keeps a nightly copy
  homelab.localState.paperless-ai = {
    path = stateDir;
    unit = "podman-paperless-ai";
    sqlite = [ "documents.db" ];
    # paperless-ai-config rewrites it, with the api token, on every start
    exclude = [ ".env" ];
  };

  # its settings are /app/data/.env, normally wizard-written; a new one restarts the app
  systemd.services.podman-paperless-ai.restartTriggers = [ config.systemd.services.paperless-ai-config.script ];
  systemd.services.paperless-ai-config = {
    description = "Seed paperless-ai configuration";
    before = [ "podman-paperless-ai.service" ];
    requiredBy = [ "podman-paperless-ai.service" ];
    # paperless-setup migrated the db and made the owner, so the user below can be created
    after = [ "paperless-setup.service" ];
    wants = [ "paperless-setup.service" ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 30;
    };
    script = ''
      set -euo pipefail
      # its own api user and token, minted here: the token never leaves this vm
      token=$(${config.services.paperless.manage}/bin/paperless-manage shell -c "
      from django.contrib.auth.models import User
      from rest_framework.authtoken.models import Token
      user, _ = User.objects.get_or_create(username='${apiUser}', defaults={'email': '${apiUser}@internal'})
      user.is_staff = user.is_superuser = True
      user.save()
      print(Token.objects.get_or_create(user=user)[0].key)
      " | tail -1)
      [ -n "$token" ] || { echo "no API token from paperless-manage" >&2; exit 1; }

      mkdir -p ${stateDir}
      umask 077
      cat > ${stateDir}/.env <<EOF
      # the host address: the container's loopback is its own
      PAPERLESS_API_URL=http://${hostIp}:${toString config.services.paperless.port}/api
      PAPERLESS_API_TOKEN=$token
      # owner of that token; unset aborts every scan
      PAPERLESS_USERNAME=${apiUser}
      AI_PROVIDER=ollama
      OLLAMA_API_URL=${llmUrl}
      OLLAMA_MODEL=${ollama.model}
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
      # the prompt plus document text the model gets, and the answer it may write: a title, a correspondent and
      # three tags fit in far less than the 1000
      TOKEN_LIMIT=128000
      RESPONSE_TOKENS=1000
      EOF
    '';
  };

  virtualisation.oci-containers.containers.paperless-ai = {
    image = "docker.io/clusterzx/paperless-ai:3.0.9";
    ports = [ "${toString port}:${toString containerPort}" ];
    volumes = [ "${stateDir}:/app/data" ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      PAPERLESS_AI_PORT = toString containerPort;
      # rag loads a local embedding model and thrashed the vm; classification skips it
      RAG_SERVICE_ENABLED = "false";
    };
    # measured 1.3g resident, half again as headroom
    extraOptions = [ "--cap-drop=ALL" "--security-opt=no-new-privileges" "--memory=2g" ];
  };

  # the app runs as the container's root without capabilities (no DAC override), so its state must be root's own
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 root root -"
    "Z ${stateDir} - root root -"
  ];

  # consistent copy for the snapshot, the live file may be mid-write
  homelab.dbBackup.databases.paperless-ai.sqlite = "${stateDir}/documents.db";
}
