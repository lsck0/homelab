{ config, lib, pkgs, inputs, inventory, nasMount, ... }:
let
  T = "/var/lib/homepage-tokens";
  routes = import ../modules/routes.nix;
  sshKey = config.sops.secrets.hermes-ssh-key.path;

  # ─────────────────────────────────────────────────────────────────────────────
  # CLI HELPERS ON THE AGENT'S PATH
  # ─────────────────────────────────────────────────────────────────────────────
  pve = pkgs.writeShellScriptBin "pve" ''
    # pve <METHOD> <api path> [curl args]   e.g. pve GET /nodes/luca-server/qemu
    m="''${1:?method}"; p="''${2:?path}"; shift 2
    exec ${pkgs.curl}/bin/curl -sk -X "$m" \
      -H "Authorization: PVEAPIToken=$(cat ${config.sops.secrets.proxmox-api-token.path})" \
      "https://192.168.178.200:8006/api2/json$p" "$@"
  '';

  vm = pkgs.writeShellScriptBin "vm" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pve pkgs.jq pkgs.openssh pkgs.coreutils ]}:$PATH"
    N=/nodes/luca-server/qemu
    ip() { if [ "$1" -ge 200 ] && [ "$1" -lt 300 ]; then echo 10.200.0.$1; else echo 10.100.0.$1; fi; }
    case "''${1:-list}" in
      list)   pve GET $N | jq -r '.data | sort_by(.vmid)[] | "\(.vmid)\t\(.status)\t\(.name)"' ;;
      status) pve GET $N/''${2:?id}/status/current | jq -r '.data.status' ;;
      start)  id=''${2:?id}
              [ "$(pve GET $N/$id/status/current | jq -r .data.status)" = running ] \
                || pve POST $N/$id/status/start >/dev/null
              for _ in $(seq 1 60); do
                ssh -o ConnectTimeout=3 -o BatchMode=yes "$(ip "$id")" true 2>/dev/null && { echo "vm-$id up"; exit 0; }
                sleep 5
              done
              echo "vm-$id did not answer SSH within 5 minutes"; exit 1 ;;
      stop)   pve POST $N/''${2:?id}/status/shutdown >/dev/null; echo "vm-$2 shutting down" ;;
      reboot) pve POST $N/''${2:?id}/status/reboot >/dev/null; echo "vm-$2 rebooting" ;;
      *)      echo "usage: vm list | status <id> | start <id> | stop <id> | reboot <id>"; exit 1 ;;
    esac
  '';

  labToken = pkgs.writeShellScriptBin "lab-token" ''
    # tokens written by DMZ VMs sit in external/, the only part they can reach
    if [ -z "''${1:-}" ]; then cd ${T} && ls *.token external/*.token | sed 's|^external/||; s/\.token$//'; exit 0; fi
    [ -f "${T}/$1.token" ] && exec cat "${T}/$1.token"
    exec cat "${T}/external/$1.token"
  '';

  # ─────────────────────────────────────────────────────────────────────────────
  # WORKSPACE CONTEXT
  # ─────────────────────────────────────────────────────────────────────────────
  # the inventory as the agent sees it
  urlOf = id: lib.concatStringsSep ", " (lib.concatLists (lib.mapAttrsToList (_: side:
    lib.mapAttrsToList (_: r: "https://${r.host}.lsck0.dev") (lib.filterAttrs (_: r: toString r.vmid == id) side)
  ) routes));
  inventoryTable = lib.concatStringsSep "\n" (lib.mapAttrsToList (id: v:
    "| ${id} | ${v.name} | ${v.ip} | ${v.enabled}${lib.optionalString (v.enabled == "onDemand") " (${v.cooldown})"} | ${urlOf id} |"
  ) inventory);

  agentsMd = ''
    # Homelab

    You are Hermes, the operator of this homelab. The owner talks to you on
    Telegram. You run on vm-113 (10.100.0.113) with an RTX 2060 and have root
    SSH on every VM and on the Proxmox host (192.168.178.200). Start with the
    `homelab-ops` skill; there is one skill per subsystem:
    ${lib.concatMapStringsSep ", " (n: "`${n}`") skillNames}.

    ## Network

    - 10.100.0.0/24 internal (VM id = last octet), 10.200.0.0/24 external DMZ,
      router 10.100.0.1 / 10.200.0.1 / 192.168.178.29.
    - Public names *.lsck0.dev go through Traefik (vm-100 internal, vm-200
      external) with Authelia SSO; from here, call VMs by IP instead.
    - NAS vm-108: all persistent service data under /srv/nas/data/<service>,
      media under /srv/nas/media. Backups: Kopia on vm-106.

    ## VMs

    enabled: true = always on, onDemand = boots on first request and powers off
    after the cooldown (start it with `vm start <id>` before using its API),
    false = stopped/not deployed.

    | id | name | ip | enabled | urls |
    |---|---|---|---|---|
    ${inventoryTable}
  '';

  skillsDir = ../modules/hermes/skills;
  skillNames = lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir skillsDir));
in {
  imports = [ inputs.hermes-agent.nixosModules.default ];

  networking.hostName = "vm-113";

  # ─────────────────────────────────────────────────────────────────────────────
  # GPU + LOCAL INFERENCE
  # ─────────────────────────────────────────────────────────────────────────────
  # NVIDIA RTX 2060 (Turing) passed through from the host (instances.tf hostpci).
  nixpkgs.config.allowUnfree = true;
  services.xserver.videoDrivers = [ "nvidia" ];
  boot.blacklistedKernelModules = [ "nouveau" ];
  hardware.graphics.enable = true;
  hardware.nvidia = {
    modesetting.enable = true;
    nvidiaSettings = false;
    open = false;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # Ollama: Hermes' fallback model when the cloud API is unreachable, and the
  # model paperless-ai uses. OpenAI-compatible at http://10.100.0.113:11434/v1.
  # weights on the local disk (memory-mapping them over NFS is too slow).
  services.ollama = {
    enable = true;
    host = "0.0.0.0";
    port = 11434;
    openFirewall = true;
    acceleration = "cuda";
    # qwen3:8b (~5 GB at Q4) fits the 6 GB card and handles tool calls.
    loadModels = [ "qwen3:8b" ];
    syncModels = true;
    environmentVariables = {
      OLLAMA_KEEP_ALIVE = "60m";
      OLLAMA_NUM_PARALLEL = "1";
      OLLAMA_MAX_LOADED_MODELS = "1";
    };
  };

  # ─────────────────────────────────────────────────────────────────────────────
  # SECRETS (FILL WITH SRC/SCRIPTS/HERMES-SECRETS.SH)
  # ─────────────────────────────────────────────────────────────────────────────
  sops.secrets = {
    hermes-ssh-key = { owner = "hermes"; mode = "0400"; };
    hermes-llm-api-key = {};
    telegram-bot-token = {};
    telegram-chat-id = {};
    proxmox-api-token = { owner = "hermes"; mode = "0400"; };
  };
  sops.templates."hermes.env" = {
    owner = "hermes";
    content = ''
      ANTHROPIC_API_KEY=${config.sops.placeholder.hermes-llm-api-key}
      TELEGRAM_BOT_TOKEN=${config.sops.placeholder.telegram-bot-token}
      TELEGRAM_ALLOWED_USERS=${config.sops.placeholder.telegram-chat-id}
      GATEWAY_ALLOW_ALL_USERS=false
      TELEGRAM_HOME_CHANNEL=${config.sops.placeholder.telegram-chat-id}
    '';
  };

  fileSystems = nasMount T "homepage-tokens";

  # root on every VM and the Proxmox host with the Hermes key.
  programs.ssh.extraConfig = ''
    Host 10.100.0.* 10.200.0.* 192.168.178.200 192.168.178.29
      User root
      IdentityFile ${sshKey}
      IdentitiesOnly yes
      StrictHostKeyChecking accept-new
  '';

  # ─────────────────────────────────────────────────────────────────────────────
  # AGENT
  # ─────────────────────────────────────────────────────────────────────────────
  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;
    environmentFiles = [ config.sops.templates."hermes.env".path ];

    settings = {
      model = {
        provider = "anthropic";
        default = "claude-sonnet-5";
      };
      # local model when the API is down or out of credit.
      fallback_model = {
        provider = "custom";
        model = "qwen3:8b";
        base_url = "http://127.0.0.1:11434/v1";
      };
      # full access: the owner granted root on the lab; no per-command prompts.
      approvals.mode = "off";
      # only the owner: TELEGRAM_ALLOWED_USERS holds the owner's numeric user id
      # (usernames can change hands). Everyone else is dropped silently, no
      # pairing codes, no allow-all.
      unauthorized_dm_behavior = "ignore";
      gateway.allow_all_users = false;
      terminal = {
        backend = "local";
        timeout = 900;
      };
    };

    extraPackages = with pkgs; [
      pve vm labToken
      openssh curl jq yq-go git gnugrep gnused coreutils findutils netcat-gnu
      poppler-utils python3
    ];

    workingDirectory = "/var/lib/hermes/workspace";
    documents."AGENTS.md" = agentsMd;
    # every directory in src/modules/hermes/skills becomes a skill.
    hermesHomeFiles = lib.genAttrs' skillNames
      (name: lib.nameValuePair "skills/homelab/${name}/SKILL.md" (skillsDir + "/${name}/SKILL.md"));
  };

  # the module's hardening makes the filesystem read-only; the token dir is
  # where Hermes reads API keys (and paperless/firefly tokens appear).
  systemd.services.hermes-agent.serviceConfig.ReadWritePaths = [ T ];
}
