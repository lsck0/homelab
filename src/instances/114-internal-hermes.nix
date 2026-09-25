{ config, lib, pkgs, inputs, inventory, nasMount, nasPath, ... }:
let
  # the RTX 2060 passthrough; see the GPU section below.
  gpu = true;

  T = "/var/lib/homepage-tokens";
  routes = import ../modules/routes.nix;
  # via a template, not the raw secret: the stored value has no trailing newline and OpenSSH
  sshKey = config.sops.templates."hermes-ssh-key".path;

  # ─────────────────────────────────────────────────────────────────────────────
  # CLI HELPERS ON THE AGENT'S PATH
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

  # mc <command...> e.g. mc list, mc "whitelist add Steve" vm-208 already owns the rcon
  mc = pkgs.writeShellScriptBin "mc" ''
    exec ${pkgs.openssh}/bin/ssh 10.200.0.208 mc-rcon "$@"
  '';

  # lab-deploy [vm ...] apply the workspace clone to the lab, or to named VMs.
  labDeploy = pkgs.writeShellScriptBin "lab-deploy" ''
    set -euo pipefail
    repo=/var/lib/hermes/workspace/homelab
    [ -d "$repo/.git" ] || { echo "lab-deploy: no clone at $repo" >&2; exit 1; }
    cd "$repo"
    # sync.sh wants the key at secrets/age.txt, which is gitignored. It is not
    # kept in sops: it is the key that decrypts sops. sync.sh already places a
    # copy on every VM, and the tmpfiles rule below makes this one readable.
    install -m 600 /var/lib/hermes/age.txt secrets/age.txt
    exec ./sync.sh "$@"
  '';

  # GitHub App (src/scripts/hermes-secrets.sh): may push branches and open pull requests
  githubApp = lib.importJSON ../modules/hermes/github-app.json;
  githubAppToken = pkgs.writeShellApplication {
    name = "github-app-token";
    runtimeInputs = [ pkgs.openssl pkgs.curl pkgs.jq pkgs.coreutils ];
    text = builtins.readFile ../scripts/github-app-token.sh;
  };
  labGithubToken = pkgs.writeShellScriptBin "lab-github-token" ''
    exec ${githubAppToken}/bin/github-app-token ${toString githubApp.id} ${config.sops.secrets.hermes-github-app-key.path}
  '';
  # git credential helper for https://github.com: a fresh installation token
  gitCredential = pkgs.writeShellScript "git-credential-lab-github" ''
    [ "''${1:-}" = get ] || exit 0
    printf 'username=x-access-token\npassword=%s\n' "$(${labGithubToken}/bin/lab-github-token)"
  '';

  # push the current hermes/<topic> branch of the homelab clone and open (or find) its pull
  labPr = pkgs.writeShellScriptBin "lab-pr" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.git pkgs.curl pkgs.jq pkgs.coreutils labGithubToken ]}:$PATH"
    api=https://api.github.com/repos/lsck0/homelab
    branch=$(git symbolic-ref --short HEAD)
    [[ "$branch" =~ ^hermes/[a-z0-9._-]+$ ]] || { echo "lab-pr: branch must be hermes/<topic> (lowercase), not $branch" >&2; exit 1; }
    [ -z "$(git status --porcelain)" ] || { echo "lab-pr: commit or discard your changes first" >&2; exit 1; }
    git fetch -q origin master
    [ "$(git rev-list --count origin/master..HEAD)" -gt 0 ] || { echo "lab-pr: no commits on top of master" >&2; exit 1; }
    # GitHub's "create a pull request" hint on stderr is noise here
    git push -q --force-with-lease -u origin HEAD 2>&1 | { grep -v '^remote:' || true; } >&2

    token=$(lab-github-token)
    gh() { curl -sf -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" "$@"; }
    url=$(gh "$api/pulls?state=open&head=lsck0:$branch" | jq -r '.[0].html_url // empty')
    if [ -z "$url" ]; then
      body=$(printf '%s\n\n---\nOpened by Hermes (vm-114). Deploy after merging with `./sync.sh`.\n' \
        "$(git log --reverse --format='%B%n---' origin/master..HEAD | sed '$d')")
      url=$(gh -X POST "$api/pulls" -d "$(jq -cn --arg head "$branch" --arg body "$body" \
        --arg title "$(git log --reverse --format=%s origin/master..HEAD | head -1)" \
        '{base: "master", head: $head, title: $title, body: $body}')" | jq -r .html_url)
    fi
    echo "pull request: $url"
  '';

  # ─────────────────────────────────────────────────────────────────────────────
  # WORKSPACE CONTEXT the inventory as the agent sees
  urlOf = id: lib.concatStringsSep ", " (lib.concatLists (lib.mapAttrsToList (_: side:
    lib.mapAttrsToList (_: r: "https://${r.host}.lsck0.dev") (lib.filterAttrs (_: r: toString r.vmid == id) side)
  ) routes));
  inventoryTable = lib.concatStringsSep "\n" (lib.mapAttrsToList (id: v:
    "| ${id} | ${v.name} | ${v.ip} | ${v.enabled}${lib.optionalString (v.enabled == "onDemand") " (${v.cooldown})"} | ${urlOf id} |"
  ) inventory);

  agentsMd = ''
    # Homelab

    You are Hermes, the operator of this homelab. The owner talks to you on
    Telegram. You run on vm-114 (10.100.0.114) with an RTX 2060 and have root
    SSH on every VM and on the Proxmox host (192.168.178.200). Start with the
    `homelab-ops` skill; there is one skill per subsystem:
    ${lib.concatMapStringsSep ", " (n: "`${n}`") skillNames}.

    The owner's own skills are under `skills/luca`:
    ${lib.concatMapStringsSep ", " (n: "`${n}`") lucaSkillNames}.

    ## Which model to use

    You run on `claude-sonnet-5`, which is the right choice for almost
    everything: answering questions, reading state, routine edits, a single
    service that misbehaves. Switch up with `/model claude-opus-5` before work
    that is actually hard - a change spanning several VMs, a failure whose
    cause is not obvious after one look, anything touching the router, egress
    or secrets, or a deploy you cannot trivially roll back. Switch back with
    `/model claude-sonnet-5` once it is done. Escalating costs the owner money,
    so do it on difficulty, not on importance.

    ## Network

    - 10.100.0.0/24 internal (VM id = last octet), 10.200.0.0/24 external DMZ,
      router 10.100.0.1 / 10.200.0.1 / 192.168.178.29.
    - Public names *.lsck0.dev go through Traefik (vm-100 internal, vm-200
      external) with Authelia SSO; from here, call VMs by IP instead.
    - NAS vm-109: all persistent service data under /srv/nas/data/<service>,
      media under /srv/nas/media. Backups: Kopia on vm-107.

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

  # the owner's own skills, straight from the dotfiles repo (flake.nix input)
  lucaSkillsDir = "${inputs.dotfiles}/skills";
  lucaSkillNames = lib.attrNames (lib.filterAttrs
    (n: t: t == "directory" && builtins.pathExists "${lucaSkillsDir}/${n}/SKILL.md")
    (builtins.readDir lucaSkillsDir));
in {
  imports = [ inputs.hermes-agent.nixosModules.default ];

  networking.hostName = "vm-114";

  # ─────────────────────────────────────────────────────────────────────────────
  # GPU + LOCAL INFERENCE NVIDIA RTX 2060 (Turing) passed through from the host
  nixpkgs.config.allowUnfree = true;
  services.xserver.videoDrivers = lib.mkIf gpu [ "nvidia" ];
  boot.blacklistedKernelModules = lib.mkIf gpu [ "nouveau" ];
  hardware.graphics.enable = gpu;
  hardware.nvidia = lib.mkIf gpu {
    modesetting.enable = true;
    nvidiaSettings = false;
    open = false;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # Ollama: Hermes' fallback model when the cloud API is unreachable
  services.ollama = {
    enable = gpu;
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
  sops.secrets = {
    hermes-ssh-key = { owner = "hermes"; mode = "0400"; };
    hermes-github-app-key = { owner = "hermes"; mode = "0400"; };
    hermes-llm-api-key = {};
    hermes-gemini-api-key = {};
    hermes-glm-api-key = {};
    telegram-bot-token = {};
    telegram-chat-id = {};
    proxmox-api-token = { owner = "hermes"; mode = "0400"; };
  };
  # see the sshKey comment at the top: this only re-adds the trailing newline.
  sops.templates."hermes-ssh-key" = {
    owner = "hermes";
    mode = "0400";
    content = ''
      ${config.sops.placeholder.hermes-ssh-key}
    '';
  };

  sops.templates."hermes.env" = {
    owner = "hermes";
    content = ''
      ANTHROPIC_API_KEY=${config.sops.placeholder.hermes-llm-api-key}
      TELEGRAM_BOT_TOKEN=${config.sops.placeholder.telegram-bot-token}
      TELEGRAM_ALLOWED_USERS=${config.sops.placeholder.telegram-chat-id}
      GATEWAY_ALLOW_ALL_USERS=false
      TELEGRAM_HOME_CHANNEL=${config.sops.placeholder.telegram-chat-id}
      # free-tier keys for the fallback chain below. Empty is fine: a provider
      # without a credential is skipped ("provider not configured") and the chain
      # moves to the next one.
      GEMINI_API_KEY=${config.sops.placeholder.hermes-gemini-api-key}
      GLM_API_KEY=${config.sops.placeholder.hermes-glm-api-key}
    '';
  };

  fileSystems = nasMount T "homepage-tokens"
    # where downloads go: /srv/sync is the same tree as the owner's ~/Sync.
    // nasPath "/srv/sync" "syncthing/sync"
    // nasPath "/srv/media" "bulk/media";

  # root on every VM and the Proxmox host with the Hermes key.
  programs.ssh.extraConfig = ''
    Host 10.100.0.* 10.200.0.* 192.168.178.200 192.168.178.29
      User root
      IdentityFile ${sshKey}
      IdentitiesOnly yes
      StrictHostKeyChecking accept-new
  '';

  programs.git = {
    enable = true;
    config = {
      user = { name = "Hermes"; email = "hermes@lsck0.dev"; };
      credential."https://github.com".helper = "${gitCredential}";
    };
  };

  # ─────────────────────────────────────────────────────────────────────────────
  # AGENT
  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;
    environmentFiles = [ config.sops.templates."hermes.env".path ];

    settings = {
      # Anthropic first, free tiers next, the local card last.
      model = {
        provider = "anthropic";
        default = "claude-sonnet-5";
      };

      # tried in order when the primary is rate-limited, out of credit or unauthenticated.
      fallback_providers = [
        # Nous Portal free tier.
        { provider = "nous"; model = "nous/welcome"; }
        # Google AI Studio free tier (GEMINI_API_KEY).
        { provider = "gemini"; model = "gemini-2.5-flash"; }
        # z.ai GLM free tier (GLM_API_KEY).
        { provider = "zai"; model = "glm-4.6-flash"; }
        # local Ollama on the passed-through RTX 2060. Last resort, always there.
        {
          provider = "custom";
          model = "qwen3:8b";
          base_url = "http://127.0.0.1:11434/v1";
        }
      ];

      # fail over quickly instead of retrying a dead primary three times.
      agent.api_max_retries = 1;
      # full access: the owner granted root on the lab; no per-command prompts.
      approvals.mode = "off";
      # only the owner: TELEGRAM_ALLOWED_USERS holds the owner's numeric user id
      unauthorized_dm_behavior = "ignore";
      gateway.allow_all_users = false;
      terminal = {
        backend = "local";
        timeout = 900;
      };
    };

    extraPackages = with pkgs; [
      pve vm mc labDeploy labToken labPr labGithubToken config.nix.package
      openssh curl jq yq-go git gnugrep gnused coreutils findutils netcat-gnu
      poppler-utils python3
      # fetching things the owner asks for, into /srv/sync or /srv/media
      wget aria2 yt-dlp rsync unzip
      # lab-deploy runs sync.sh, which needs these
      terraform sops age openssl
    ];

    workingDirectory = "/var/lib/hermes/workspace";
    documents."AGENTS.md" = agentsMd;
    # every directory in src/modules/hermes/skills becomes a skill.
    hermesHomeFiles = lib.genAttrs' skillNames
      (name: lib.nameValuePair "skills/homelab/${name}/SKILL.md" (skillsDir + "/${name}/SKILL.md"))
      // lib.genAttrs' lucaSkillNames
      (name: lib.nameValuePair "skills/luca/${name}/SKILL.md" "${lucaSkillsDir}/${name}/SKILL.md");
  };

  # the module's hardening makes the filesystem read-only; the token dir is where Hermes reads
  systemd.services.hermes-agent.serviceConfig.ReadWritePaths = [ T "/srv/sync" "/srv/media" ];

  # lab-deploy runs sync.sh, which needs the age key. sync.sh already drops it on every VM
  systemd.tmpfiles.rules = [
    "C+ /var/lib/hermes/age.txt 0400 hermes hermes - /var/lib/sops-nix/key.txt"
  ];
}
