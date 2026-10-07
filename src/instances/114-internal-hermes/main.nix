# hermes: the owner's telegram agent, root on every guest and the proxmox host, with the lab's tools and skills
{ config, lib, pkgs, inputs, inventory, nasPath, site, catalog, lab, retry, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  ntfy = import ../../modules/ntfy.nix;
  stateDir = config.services.hermes-agent.stateDir;
  tokensDir = config.homelab.tokens.dir;
  # the sops template adds the trailing newline openssh needs
  sshKey = config.sops.templates."hermes-ssh-key".path;
  ntfyHost = net.fqdn catalog.external.ntfy.host;
  githubApp = lib.importJSON ./lib/github-app.json;
  githubRepo = site.repo;
  githubOwner = lib.head (lib.splitString "/" githubRepo);

  modelDefault = "claude-sonnet-5";
  modelHard = "claude-opus-5";
  # a guest boots within a minute, the first deploy of a fresh guest takes a few
  bootWaitAttempts = 60;
  bootWaitIntervalS = 5;

  # root on every guest (the router's lan side included), on the router's zone legs and on the proxmox host
  guests = lib.filter (v: v.type != "router") (lib.attrValues inventory);
  router = lib.findSingle (v: v.type == "router") null null (lib.attrValues inventory);
  routerLegs = lib.unique (map (v: v.gateway) guests);
  rootHosts = lib.unique (map (v: v.ip) (lib.attrValues inventory) ++ routerLegs ++ [ site.lan.proxmox ]);
  # every host key of the lab, the proxmox host's included, checked strictly: no trust on first use
  knownHosts = ../../generated/known_hosts;

  # pve <get|create|set|delete> <api path> [--<param> <value>...]: the proxmox api as json through pvesh over root
  # ssh, so this vm holds no api token and pins no tls
  pve = pkgs.writeShellScriptBin "pve" ''
    set -euo pipefail
    m="''${1:?method: get, create, set or delete}"; p="''${2:?api path, e.g. /nodes/${site.node}/qemu}"; shift 2
    case "$m" in get|create|set|delete) ;; *) echo "pve: method $m is none of get, create, set, delete" >&2; exit 2 ;; esac
    # ssh hands the remote shell one string: quote every word
    exec ${pkgs.openssh}/bin/ssh ${site.lan.proxmox} "pvesh $(printf '%q ' "$m" "$p" "$@")--output-format json"
  '';

  vm = pkgs.writeShellScriptBin "vm" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pve pkgs.jq pkgs.openssh pkgs.coreutils ]}:$PATH"
    inventory=${pkgs.writeText "inventory.json" (builtins.toJSON inventory)}
    node=/nodes/${site.node}
    field() { jq -er --arg id "$1" --arg f "$2" '.[$id][$f]' "$inventory"; }
    at() { if [ "$(field "$1" kind)" = lxc ]; then echo "$node/lxc/$1"; else echo "$node/qemu/$1"; fi; }
    action=''${1:-list}
    case "$action" in status|start|stop|reboot) N=$(at "''${2:?id}") ;; esac
    case "$action" in
      list)   { pve get "$node/qemu"; pve get "$node/lxc"; } \
                | jq -rs 'add | sort_by(.vmid)[] | "\(.vmid)\t\(.status)\t\(.name)"' ;;
      status) pve get "$N/status/current" | jq -r .status ;;
      start)  [ "$(pve get "$N/status/current" | jq -r .status)" = running ] || pve create "$N/status/start" >/dev/null
              ${retry} ${toString bootWaitAttempts} ${toString bootWaitIntervalS} \
                ssh -o ConnectTimeout=3 -o BatchMode=yes "$(field "$2" ip)" true \
                || { echo "vm-$2 did not answer ssh within ${toString (bootWaitAttempts * bootWaitIntervalS)} s"; exit 1; }
              echo "vm-$2 up" ;;
      stop)   pve create "$N/status/shutdown" >/dev/null; echo "vm-$2 shutting down" ;;
      reboot) pve create "$N/status/reboot" >/dev/null; echo "vm-$2 rebooting" ;;
      *)      echo "usage: vm list | status <id> | start <id> | stop <id> | reboot <id>"; exit 1 ;;
    esac
  '';

  # the api keys the skills call (`lab-token <name>`): a lab token an app minted, or a sops secret the lab chose
  apiSecrets = [ "jellyfin-admin-pass" "lidarr-key" "prowlarr-key" "radarr-key" "sonarr-key" ];
  labToken = pkgs.writeShellScriptBin "lab-token" ''
    if [ -z "''${1:-}" ]; then
      for token in ${tokensDir}/*.token; do [ ! -e "$token" ] || basename "$token" .token; done | cat - <(printf '%s\n' ${toString apiSecrets}) | sort
      exit 0
    fi
    for secret in ${toString (map (name: config.sops.secrets.${name}.path) apiSecrets)}; do
      [ "''${secret##*/}" != "$1" ] || exec cat "$secret"
    done
    exec cat "${tokensDir}/$1.token"
  '' // { names = config.homelab.tokens.reads ++ apiSecrets; };

  # mc <command...>: rcon through vm-208
  mc = pkgs.writeShellScriptBin "mc" ''
    exec ${pkgs.openssh}/bin/ssh ${net.ipOf (toString lab.routes.minecraft.vmid)} mc-rcon "$@"
  '';

  # lab-notify [-t <title>] [-p <priority>] [-g <tags>] [-c <click url>] <message...>: a push to the owner as ntfy user
  # hermes, the password from a netrc, never argv
  labNotify = pkgs.writeShellScriptBin "lab-notify" ''
    set -euo pipefail
    usage() { echo "usage: lab-notify [-t title] [-p min|low|default|high|urgent] [-g tags] [-c click-url] <message...>" >&2; exit 2; }
    headers=()
    while getopts t:p:g:c: o; do
      case "$o" in
        t) headers+=(-H "Title: $OPTARG") ;;
        p) case "$OPTARG" in min|low|default|high|urgent) headers+=(-H "Priority: $OPTARG") ;; *) usage ;; esac ;;
        g) headers+=(-H "Tags: $OPTARG") ;;
        c) headers+=(-H "Click: $OPTARG") ;;
        *) usage ;;
      esac
    done
    shift $((OPTIND - 1))
    [ "$#" -gt 0 ] || usage
    exec ${pkgs.curl}/bin/curl -sSf --netrc-file ${config.sops.templates."hermes-ntfy.netrc".path} \
      "''${headers[@]}" --data-binary "$*" https://${ntfyHost}/${ntfy.topics.hermes} -o /dev/null
  '';

  # the github app may push branches and open prs
  githubAppToken = pkgs.writeShellApplication {
    name = "github-app-token";
    runtimeInputs = [ pkgs.openssl pkgs.curl pkgs.jq pkgs.coreutils ];
    text = builtins.readFile ./lib/github-app-token.sh;
  };
  labGithubToken = pkgs.writeShellScriptBin "lab-github-token" ''
    exec ${githubAppToken}/bin/github-app-token ${toString githubApp.id} ${config.sops.secrets.hermes-github-app-key.path} ${githubRepo}
  '';
  gitCredential = pkgs.writeShellScript "git-credential-lab-github" ''
    [ "''${1:-}" = get ] || exit 0
    printf 'username=x-access-token\npassword=%s\n' "$(${labGithubToken}/bin/lab-github-token)"
  '';

  # push the hermes/<topic> branch and open its pr
  labPr = pkgs.writeShellScriptBin "lab-pr" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.git pkgs.curl pkgs.jq pkgs.coreutils labGithubToken ]}:$PATH"
    api=https://api.github.com/repos/${githubRepo}
    branch=$(git symbolic-ref --short HEAD)
    [[ "$branch" =~ ^hermes/[a-z0-9._-]+$ ]] || { echo "lab-pr: branch must be hermes/<topic> (lowercase), not $branch" >&2; exit 1; }
    [ -z "$(git status --porcelain)" ] || { echo "lab-pr: commit or discard your changes first" >&2; exit 1; }
    git fetch -q origin master
    [ "$(git rev-list --count origin/master..HEAD)" -gt 0 ] || { echo "lab-pr: no commits on top of master" >&2; exit 1; }
    # drop github's pr hint noise
    git push -q --force-with-lease -u origin HEAD 2>&1 | { grep -v '^remote:' || true; } >&2

    token=$(lab-github-token)
    gh() { curl -sf -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" "$@"; }
    url=$(gh "$api/pulls?state=open&head=${githubOwner}:$branch" | jq -r '.[0].html_url // empty')
    if [ -z "$url" ]; then
      # shellcheck disable=SC2016 # markdown backticks, not a command
      body=$(printf '%s\n\n---\nOpened by Hermes (vm-114). Deploy after merging with `./sync.sh`.\n' \
        "$(git log --reverse --format='%B%n---' origin/master..HEAD | sed '$d')")
      url=$(gh -X POST "$api/pulls" -d "$(jq -cn --arg head "$branch" --arg body "$body" \
        --arg title "$(git log --reverse --format=%s origin/master..HEAD | head -1)" \
        '{base: "master", head: $head, title: $title, body: $body}')" | jq -r .html_url)
    fi
    echo "pull request: $url"
  '';

  urlOf = id: lib.concatStringsSep ", " (lib.concatLists (lib.mapAttrsToList (_: side:
    lib.mapAttrsToList (_: r: "https://${net.fqdn r.host}") (lib.filterAttrs (_: r: r.vmid != null && toString r.vmid == id) side)
  ) { inherit (catalog) internal external; }));
  powerOf = v: if !v.powered then "off" else if v.idle != null then "idle after ${v.idle}" else "on";
  inventoryTable = lib.concatStringsSep "\n" (lib.mapAttrsToList (id: v:
    "| ${id} | ${v.name} | ${v.ip} | ${powerOf v} | ${urlOf id} |"
  ) inventory);

  agentsMd = ''
    # Homelab

    You are Hermes, the operator of this homelab. The owner talks to you on
    Telegram. You run on vm-114 (${net.ipOf config.homelab.vmid}), use only Anthropic's API, and have root
    SSH on every VM and on the Proxmox host (${site.lan.proxmox}). Start with the
    `homelab-ops` skill; there is one skill per subsystem:
    ${lib.concatMapStringsSep ", " (n: "`${n}`") skillNames}.

    The owner's own skills are in the category `luca`:
    ${lib.concatMapStringsSep ", " (n: "`${n}`") lucaSkillNames}.

    ## Which model to use

    You run on `${modelDefault}`, which is the right choice for almost
    everything: answering questions, reading state, routine edits, a single
    service that misbehaves. Switch up with `/model ${modelHard}` before work
    that is actually hard: a change spanning several VMs, a failure whose
    cause is not obvious after one look, anything touching the router, egress
    or secrets, or a change you cannot trivially roll back. Switch back with
    `/model ${modelDefault}` once it is done. Escalating costs the owner money,
    so do it on difficulty, not on importance.

    ## Network

    - Zones: ${net.zones.internal.subnet} internal, ${net.zones.external.subnet} external DMZ,
      ${net.zones.apps.subnet} apps (swarm workers); VM id = last octet. Router
      ${net.zones.internal.routerIp} / ${net.zones.external.routerIp} / ${net.zones.apps.routerIp} / ${site.lan.router}.
    - Public names *.${site.domain} go through Traefik (vm-100 internal, vm-200
      external) with Authelia SSO; from here, call VMs by IP instead.
    - NAS vm-109: all persistent service data under /srv/nas/data/<service>,
      media under /srv/nas/bulk/media. Backups: Kopia on vm-109 itself.

    ## VMs

    power: on = always on; idle after <time> = boots on the first request to
    one of its urls (or `vm start <id>` before using its API) and powers off
    after that long without one; off = stopped, not deployed. This table is
    generated from the inventory and wins over anything a skill says about a
    VM's state or address.

    | id | name | ip | power | urls |
    |---|---|---|---|---|
    ${inventoryTable}
  '';

  # general skills in lib/skills/<name>/SKILL.md; an instance's skill.md is named after its service, so a new one
  # needs no edit here
  generalSkillsDir = ./lib/skills;
  serviceOf = i: lib.removePrefix "${i.zone}-" (lib.removePrefix "${i.id}-" i.name);
  skillEntries = map (name: { inherit name; file = generalSkillsDir + "/${name}/SKILL.md"; })
      (lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir generalSkillsDir)))
    ++ map (i: { name = serviceOf i; file = i.dir + "/skill.md"; })
      (lib.filter (i: i.dir != null && builtins.pathExists (i.dir + "/skill.md")) (lib.attrValues lab.instances));
  skillNamesTwice = lib.attrNames (lib.filterAttrs (_: es: lib.length es > 1) (lib.groupBy (e: e.name) skillEntries));
  skills = assert lib.assertMsg (skillNamesTwice == [ ]) "hermes skills named twice: ${toString skillNamesTwice}";
    lib.listToAttrs (map (e: lib.nameValuePair e.name e.file) skillEntries);
  skillNames = lib.attrNames skills;

  lucaSkillsDir = "${inputs.dotfiles}/skills";
  lucaSkillNames = lib.attrNames (lib.filterAttrs
    (n: t: t == "directory" && builtins.pathExists "${lucaSkillsDir}/${n}/SKILL.md")
    (builtins.readDir lucaSkillsDir));

  # every declared skill as one read-only tree (skills.external_dirs): a skill dropped here is gone on the next
  # deploy, and the skills hermes writes itself stay in its own skills dir
  skillsTree = pkgs.linkFarm "hermes-skills" (
    lib.mapAttrsToList (name: file: { name = "homelab/${name}/SKILL.md"; path = file; }) skills
    ++ map (name: { name = "luca/${name}/SKILL.md"; path = "${lucaSkillsDir}/${name}/SKILL.md"; }) lucaSkillNames);
  # the copies earlier deploys installed would shadow skillsTree; they are root's, what hermes writes is its own
  skillsCopiesRemove = pkgs.writeShellScript "hermes-skills-copies-remove" ''
    ${pkgs.findutils}/bin/find ${stateDir}/.hermes/skills -mindepth 1 -maxdepth 1 -user root -exec ${pkgs.coreutils}/bin/rm -rf {} +
  '';
in {
  imports = [ inputs.hermes-agent.nixosModules.default ];

  sops.secrets = {
    hermes-ssh-key = { owner = "hermes"; mode = "0400"; };
    hermes-github-app-key = { owner = "hermes"; mode = "0400"; };
    hermes-claude-token = {};
    telegram-bot-token = {};
    telegram-chat-id = {};
    ntfy-hermes-password = {};
  } // lib.genAttrs apiSecrets (_: { owner = "hermes"; mode = "0400"; });
  sops.templates."hermes-ntfy.netrc" = {
    owner = "hermes";
    mode = "0400";
    content = ''
      machine ${ntfyHost} login hermes password ${config.sops.placeholder.ntfy-hermes-password}
    '';
  };
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
      # a claude subscription token (`claude setup-token`): hermes reads ANTHROPIC_TOKEN as an oauth credential and,
      # unlike CLAUDE_CODE_OAUTH_TOKEN, strips it from every command it runs (tools/environments/local_env_policy.py)
      ANTHROPIC_TOKEN=${config.sops.placeholder.hermes-claude-token}
      TELEGRAM_BOT_TOKEN=${config.sops.placeholder.telegram-bot-token}
      TELEGRAM_ALLOWED_USERS=${config.sops.placeholder.telegram-chat-id}
      TELEGRAM_HOME_CHANNEL=${config.sops.placeholder.telegram-chat-id}
    '';
  };

  # /srv/sync is the owner's ~/Sync
  homelab.nasMounts = nasPath "/srv/sync" "syncthing/sync"
    // nasPath "/srv/media" "bulk/media";

  programs.ssh.extraConfig = ''
    # one router, one host key, whichever zone leg answers
    Host ${lib.concatStringsSep " " routerLegs}
      HostKeyAlias ${router.ip}
    Host ${lib.concatStringsSep " " rootHosts}
      User root
      IdentityFile ${sshKey}
      IdentitiesOnly yes
      StrictHostKeyChecking yes
      UserKnownHostsFile ${knownHosts}
  '';

  programs.git = {
    enable = true;
    config = {
      user = { name = "Hermes"; email = "hermes@${site.domain}"; };
      credential."https://github.com".helper = "${gitCredential}";
    };
  };

  services.hermes-agent = {
    enable = true;
    addToSystemPackages = true;
    environmentFiles = [ config.sops.templates."hermes.env".path ];

    settings = {
      # anthropic only. No fallback provider: a root agent's sessions hold tokens and config files, and free tiers
      # may train on what they are sent; an anthropic outage waits instead of leaking
      model = {
        provider = "anthropic";
        default = modelDefault;
      };

      # the model sees the owner's telegram photos as pixels; the default may route them through text
      agent.image_input_mode = "native";
      # the owner granted root, so no prompts
      approvals.mode = "off";
      # the owner only, by TELEGRAM_ALLOWED_USERS
      unauthorized_dm_behavior = "ignore";
      gateway.allow_all_users = false;
      terminal = {
        backend = "local";
        timeout = 900;
      };
      skills.external_dirs = [ "${skillsTree}" ];
    };

    extraPackages = with pkgs; [
      pve vm mc labToken labNotify labPr labGithubToken config.nix.package
      openssh curl jq yq-go git gnugrep gnused coreutils findutils netcat-gnu
      poppler-utils python3 openssl
      # fetching into /srv/sync or /srv/media
      wget aria2 yt-dlp rsync unzip
    ];

    workingDirectory = "${stateDir}/workspace";
    documents."AGENTS.md" = agentsMd;
  };

  systemd.services.hermes-agent.serviceConfig = {
    # the parent, not the automounts: the hardened unit still starts without the nas
    ReadWritePaths = [ "/srv" ];
    # "-": a fresh home has no skills dir yet
    ExecStartPre = [ "-+${skillsCopiesRemove}" ];
  };

  # the agent never deploys and holds no admin key: removes the copies an earlier deploy path left
  systemd.tmpfiles.rules = [
    "r ${stateDir}/age.txt - - - - -"
    "r ${config.services.hermes-agent.workingDirectory}/homelab/secrets/age.txt - - - - -"
  ];

  # hermes keeps its memory and schedule on local disk, nothing else copies it
  homelab.dbBackup.databases = lib.mapAttrs (_: f: { sqlite = "${stateDir}/.hermes/${f}"; }) {
    hermes-state = "state.db";
    hermes-shared = "shared-state.db";
    hermes-kanban = "kanban.db";
    hermes-cron = "cron/executions.db";
  };
}
