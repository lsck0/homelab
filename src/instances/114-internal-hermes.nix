{ config, lib, pkgs, inputs, inventory, nasMount, nasPath, site, ... }:
let
  T = "/var/lib/homepage-tokens";
  routes = import ../modules/routes.nix;
  # template adds the trailing newline openssh needs
  sshKey = config.sops.templates."hermes-ssh-key".path;

  # CLI HELPERS ON THE AGENT'S PATH
  pve = pkgs.writeShellScriptBin "pve" ''
    # pve <method> <api path> [curl args]
    m="''${1:?method}"; p="''${2:?path}"; shift 2
    exec ${pkgs.curl}/bin/curl -sk -X "$m" \
      -H "Authorization: PVEAPIToken=$(cat ${config.sops.secrets.proxmox-api-token.path})" \
      "https://${site.lan.proxmox}:8006/api2/json$p" "$@"
  '';

  vm = pkgs.writeShellScriptBin "vm" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pve pkgs.jq pkgs.openssh pkgs.coreutils ]}:$PATH"
    # guests are qemu vms or lxc containers
    at() { if pve GET "/nodes/${site.node}/lxc/$1/status/current" | jq -e .data >/dev/null; then
             echo "/nodes/${site.node}/lxc/$1"; else echo "/nodes/${site.node}/qemu/$1"; fi; }
    ip() { if [ "$1" -ge 200 ] && [ "$1" -lt 300 ]; then echo 10.200.0.$1; else echo 10.100.0.$1; fi; }
    case "''${1:-list}" in status|start|stop|reboot) N=$(at "''${2:?id}") ;; esac
    case "''${1:-list}" in
      list)   { pve GET /nodes/${site.node}/qemu; pve GET /nodes/${site.node}/lxc; } \
                | jq -rs 'map(.data) | add | sort_by(.vmid)[] | "\(.vmid)\t\(.status)\t\(.name)"' ;;
      status) pve GET $N/status/current | jq -r '.data.status' ;;
      start)  id=''${2:?id}
              [ "$(pve GET $N/status/current | jq -r .data.status)" = running ] \
                || pve POST $N/status/start >/dev/null
              for _ in $(seq 1 60); do
                ssh -o ConnectTimeout=3 -o BatchMode=yes "$(ip "$id")" true 2>/dev/null && { echo "vm-$id up"; exit 0; }
                sleep 5
              done
              echo "vm-$id did not answer SSH within 5 minutes"; exit 1 ;;
      stop)   pve POST $N/status/shutdown >/dev/null; echo "vm-$2 shutting down" ;;
      reboot) pve POST $N/status/reboot >/dev/null; echo "vm-$2 rebooting" ;;
      *)      echo "usage: vm list | status <id> | start <id> | stop <id> | reboot <id>"; exit 1 ;;
    esac
  '';

  labToken = pkgs.writeShellScriptBin "lab-token" ''
    # dmz vms write to external/
    if [ -z "''${1:-}" ]; then cd ${T} && ls *.token external/*.token | sed 's|^external/||; s/\.token$//'; exit 0; fi
    [ -f "${T}/$1.token" ] && exec cat "${T}/$1.token"
    exec cat "${T}/external/$1.token"
  '';

  # mc <command...>: rcon through vm-208
  mc = pkgs.writeShellScriptBin "mc" ''
    exec ${pkgs.openssh}/bin/ssh 10.200.0.208 mc-rcon "$@"
  '';

  # lab-deploy [vm ...]: sync the workspace clone
  labDeploy = pkgs.writeShellScriptBin "lab-deploy" ''
    set -euo pipefail
    repo=/var/lib/hermes/workspace/homelab
    [ -d "$repo/.git" ] || { echo "lab-deploy: no clone at $repo" >&2; exit 1; }
    cd "$repo"
    # age key is not in sops, it decrypts sops
    install -m 600 /var/lib/hermes/age.txt secrets/age.txt
    exec ./sync.sh "$@"
  '';

  # github app: may push branches and open prs
  githubApp = lib.importJSON ../modules/hermes/github-app.json;
  githubAppToken = pkgs.writeShellApplication {
    name = "github-app-token";
    runtimeInputs = [ pkgs.openssl pkgs.curl pkgs.jq pkgs.coreutils ];
    text = builtins.readFile ../scripts/github-app-token.sh;
  };
  labGithubToken = pkgs.writeShellScriptBin "lab-github-token" ''
    exec ${githubAppToken}/bin/github-app-token ${toString githubApp.id} ${config.sops.secrets.hermes-github-app-key.path}
  '';
  # git credential helper: fresh installation token
  gitCredential = pkgs.writeShellScript "git-credential-lab-github" ''
    [ "''${1:-}" = get ] || exit 0
    printf 'username=x-access-token\npassword=%s\n' "$(${labGithubToken}/bin/lab-github-token)"
  '';

  # push the hermes/<topic> branch and open its pr
  labPr = pkgs.writeShellScriptBin "lab-pr" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.git pkgs.curl pkgs.jq pkgs.coreutils labGithubToken ]}:$PATH"
    api=https://api.github.com/repos/lsck0/homelab
    branch=$(git symbolic-ref --short HEAD)
    [[ "$branch" =~ ^hermes/[a-z0-9._-]+$ ]] || { echo "lab-pr: branch must be hermes/<topic> (lowercase), not $branch" >&2; exit 1; }
    [ -z "$(git status --porcelain)" ] || { echo "lab-pr: commit or discard your changes first" >&2; exit 1; }
    git fetch -q origin master
    [ "$(git rev-list --count origin/master..HEAD)" -gt 0 ] || { echo "lab-pr: no commits on top of master" >&2; exit 1; }
    # drop github's pr hint noise
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

  # WORKSPACE CONTEXT (inventory as the agent sees it)
  urlOf = id: lib.concatStringsSep ", " (lib.concatLists (lib.mapAttrsToList (_: side:
    lib.mapAttrsToList (_: r: "https://${r.host}.lsck0.dev") (lib.filterAttrs (_: r: toString r.vmid == id) side)
  ) routes));
  inventoryTable = lib.concatStringsSep "\n" (lib.mapAttrsToList (id: v:
    "| ${id} | ${v.name} | ${v.ip} | ${v.enabled}${lib.optionalString (v.enabled == "onDemand") " (${v.cooldown})"} | ${urlOf id} |"
  ) inventory);

  agentsMd = ''
    # Homelab

    You are Hermes, the operator of this homelab. The owner talks to you on
    Telegram. You run on vm-114 (10.100.0.114), use only cloud model APIs, and have root
    SSH on every VM and on the Proxmox host (${site.lan.proxmox}). Start with the
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
      router 10.100.0.1 / 10.200.0.1 / ${site.lan.router}.
    - Public names *.lsck0.dev go through Traefik (vm-100 internal, vm-200
      external) with Authelia SSO; from here, call VMs by IP instead.
    - NAS vm-109: all persistent service data under /srv/nas/data/<service>,
      media under /srv/nas/bulk/media. Backups: Kopia on vm-109 itself.

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

  # owner's skills from the dotfiles flake input
  lucaSkillsDir = "${inputs.dotfiles}/skills";
  lucaSkillNames = lib.attrNames (lib.filterAttrs
    (n: t: t == "directory" && builtins.pathExists "${lucaSkillsDir}/${n}/SKILL.md")
    (builtins.readDir lucaSkillsDir));
in {
  imports = [ inputs.hermes-agent.nixosModules.default ];

  networking.hostName = "vm-114";
  # terraform is BSL
  nixpkgs.config.allowUnfreePredicate = p: lib.getName p == "terraform";

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
  # re-adds the trailing newline, see sshKey
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
      # empty keys are skipped by the fallback chain
      GEMINI_API_KEY=${config.sops.placeholder.hermes-gemini-api-key}
      GLM_API_KEY=${config.sops.placeholder.hermes-glm-api-key}
    '';
  };

  fileSystems = nasMount T "homepage-tokens"
    # /srv/sync is the owner's ~/Sync
    // nasPath "/srv/sync" "syncthing/sync"
    // nasPath "/srv/media" "bulk/media";

  # root on every vm and the proxmox host
  programs.ssh.extraConfig = ''
    Host 10.100.0.* 10.200.0.* ${site.lan.proxmox} ${site.lan.router}
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

  # AGENT
  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;
    environmentFiles = [ config.sops.templates."hermes.env".path ];

    settings = {
      # anthropic first, then free tiers
      model = {
        provider = "anthropic";
        default = "claude-sonnet-5";
      };

      # tried in order when the primary fails
      fallback_providers = [
        # nous portal free tier
        { provider = "nous"; model = "nous/welcome"; }
        # google ai studio free tier
        { provider = "gemini"; model = "gemini-2.5-flash"; }
        # z.ai glm free tier
        { provider = "zai"; model = "glm-4.6-flash"; }
      ];

      # fail over fast
      agent.api_max_retries = 1;
      # telegram photos: always hand the model native pixels, never a file path, so it
      # actually sees images the owner sends (default auto can route them through text)
      agent.image_input_mode = "native";
      # owner granted root, no prompts
      approvals.mode = "off";
      # owner only, via TELEGRAM_ALLOWED_USERS
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
      # fetching into /srv/sync or /srv/media
      wget aria2 yt-dlp rsync unzip
      # sync.sh dependencies
      terraform sops age openssl
    ];

    workingDirectory = "/var/lib/hermes/workspace";
    documents."AGENTS.md" = agentsMd;
    # each skills/ directory becomes a skill
    hermesHomeFiles = lib.genAttrs' skillNames
      (name: lib.nameValuePair "skills/homelab/${name}/SKILL.md" (skillsDir + "/${name}/SKILL.md"))
      // lib.genAttrs' lucaSkillNames
      (name: lib.nameValuePair "skills/luca/${name}/SKILL.md" "${lucaSkillsDir}/${name}/SKILL.md");
  };

  # hardening makes the fs read-only; the parent, not the automounts, so the agent starts without the nas
  systemd.services.hermes-agent.serviceConfig.ReadWritePaths = [ "/srv" ];

  # sync.sh needs the age key
  systemd.tmpfiles.rules = [
    "C+ /var/lib/hermes/age.txt 0400 hermes hermes - /var/lib/sops-nix/key.txt"
  ];

  # hermes keeps its memory and schedule on local disk, nothing else copies it
  homelab.dbBackup.databases = lib.mapAttrs (_: f: { sqlite = "/var/lib/hermes/.hermes/${f}"; }) {
    hermes-state = "state.db";
    hermes-shared = "shared-state.db";
    hermes-kanban = "kanban.db";
    hermes-cron = "cron/executions.db";
  };
}
