# the apps swarm: one manager in the internal zone, every running guest of the apps zone a worker
#
# The control plane stays inside: vm-140 (apps.nix `swarm.manager`) holds the raft, the stack specs and the
# secrets in them, and runs no app container (drained). The workers sit in the apps zone, a dmz of their own,
# and can neither change the cluster nor read what it stores. The cluster builds itself: the manager
# initialises it autolocked, keeps the unlock key on its own nas share and publishes the worker join token
# through its token dir (modules/tokens.nix); workers join with it. Nodes leave by leaving the inventory.
# Apps arrive from the builder on vm-117 over ssh as one forced command, swarm-apply, which renders them
# through scripts/swarm-render.py (homelab ports, env, encryption, policy) and deploys. Nothing here polls.
{ config, lib, pkgs, inventory, nasMount, retry, ... }:
let
  catalog = import ./apps.nix;
  apps = lib.filterAttrs (_: a: a.enable or false) catalog.apps;

  match = builtins.match "vm-([0-9]+)" config.networking.hostName;
  ownId = if match == null then null else builtins.head match;

  managerId = toString catalog.swarm.manager;
  manager = inventory.${managerId};
  workerIds = lib.sort (a: b: lib.toInt a < lib.toInt b)
    (lib.attrNames (lib.filterAttrs (_: v: v.type == "apps" && v.enabled != "false") inventory));
  isManager = ownId == managerId;
  isWorker = lib.elem ownId workerIds;
  self = inventory.${ownId};
  nodeName = id: "vm-${id}";
  # volumes live on one worker, which is also where they are dumped from; pinned, so adding a worker moves nothing
  stateId = toString catalog.swarm.state;

  # the apps zone, from its first worker's address
  workerSubnet = let w = inventory.${lib.head workerIds}; in
    "${lib.concatStringsSep "." (lib.take 3 (lib.splitString "." w.ip))}.0/${toString w.prefix}";
  # docker's default overlay pool is 10.0.0.0/8, which holds every lab subnet
  overlayPool = "10.250.0.0/16";
  overlayMask = 24;

  managerPort = 2377;
  gossipPort = 7946;
  vxlanPort = 4789;

  tokens = config.homelab.tokens.dir;
  # where an app's containers send otlp traces and pyroscope profiles (105-internal-grafana.nix)
  telemetryHost = "10.100.0.105";
  telemetryPorts = "4317,4040";
  docker = "${config.virtualisation.docker.package}/bin/docker";
  # the unlock key on a nas share only the manager mounts: off the disk whose raft it opens
  managerShare = "/var/lib/swarm-manager-nas";
  unlockKey = "${managerShare}/unlock-key";

  # the builder's key, usable from the builder's vm only; private half: sops app-deploy-key on vm-117
  builderIp = inventory."117".ip;
  builderKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGI2KxZj2UXbIt/41+9I8NsSj5vh3eTLRVH+f/vZD1qY app-builder@vm-117";

  # what swarm-render.py needs of each enabled app; secrets stay as {{name}}, sops renders the env file
  catalogJson = pkgs.writeText "swarm-apps.json" (builtins.toJSON (lib.mapAttrs (_: a: {
    exclude = a.exclude or [ ];
    stateful = a.stateful or [ ];
    override = a.override or { };
    images = a.images or [ ];
    paths = a.paths or { };
    internal = a.internal or { };
    metrics = a.metrics or { };
  }) apps));

  # "{{name}}" in a catalog env value is the sops secret <name>
  secretRefs = value: map lib.head (builtins.filter builtins.isList
    (builtins.split "\\{\\{([a-z0-9-]+)}}" value));
  appSecrets = a: lib.unique (lib.concatMap secretRefs (lib.attrValues (a.env or { })));
  withPlaceholders = value: builtins.replaceStrings
    (map (n: "{{${n}}}") (secretRefs value))
    (map (n: config.sops.placeholder.${n}) (secretRefs value)) value;

  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  render = "${python}/bin/python3 ${../scripts/swarm-render.py}";

  # the builder's forced command: `ssh root@<manager> <app>`, the stack on stdin
  swarmApply = pkgs.writeShellScript "swarm-apply" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils config.virtualisation.docker.package ]}
    app=''${SSH_ORIGINAL_COMMAND:-}
    case "$app" in
      ${lib.concatStringsSep "|" (lib.attrNames apps)}) ;;
      *) echo "swarm-apply: unknown app '$app'" >&2; exit 2 ;;
    esac
    work=$(umask 077; mktemp -d /run/swarm-apply.XXXXXX)
    trap 'rm -rf "$work"' EXIT
    ${render} "$app" ${catalogJson} "/run/secrets/rendered/swarm-app-$app.env" > "$work/stack.yaml"
    echo "swarm-apply: deploying $app"
    # the swarm rolls a service back when its new tasks fail their healthchecks (update_config failure_action)
    docker stack deploy --detach=false --prune --resolve-image always -c "$work/stack.yaml" "$app"
  '';

  addrs = ip: ''--advertise-addr ${ip} --listen-addr ${ip}:${toString managerPort} --data-path-addr ${ip}'';

  managerScript = pkgs.writeShellScript "swarm-manager" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ config.virtualisation.docker.package pkgs.coreutils ]}
    ${retry} 30 1 docker info
    state=$(docker info --format '{{.Swarm.LocalNodeState}}')
    if [ "$state" = locked ]; then
      docker swarm unlock < ${unlockKey}
    elif [ "$state" != active ]; then
      echo "initialising the apps swarm"
      docker swarm init ${addrs manager.ip} --autolock \
        --default-addr-pool ${overlayPool} --default-addr-pool-mask-length ${toString overlayMask} >/dev/null
    fi
    umask 077
    docker swarm unlock-key -q > ${unlockKey}.tmp && mv ${unlockKey}.tmp ${unlockKey}
    own=${config.homelab.tokens.ownDir}
    docker swarm join-token -q worker > "$own/swarm-worker-token.tmp" && mv "$own/swarm-worker-token.tmp" "$own/swarm-worker-token.token"
    # the manager schedules, it never runs an app
    docker node update --availability drain ${nodeName managerId} >/dev/null
  '';

  # the cluster's shape follows the inventory: on start and on every node event, never on a timer
  reconcileScript = pkgs.writeShellScript "swarm-reconcile" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath [ config.virtualisation.docker.package pkgs.coreutils ]}
    # by node id: a worker that rejoined leaves its old entry behind under the same hostname
    reconcile() {
      docker node ls --format '{{.ID}}|{{.Hostname}}|{{.Status}}' | while IFS='|' read -r id host status; do
        # a node still joining has no hostname yet: never mistake it for one that left
        [ -n "$host" ] && [ "$status" != Unknown ] || continue
        case " ${lib.concatMapStringsSep " " nodeName ([ managerId ] ++ workerIds)} " in
          *" $host "*)
            # a down entry with a ready twin is a node's previous membership
            if [ "$status" = Down ] && docker node ls --format '{{.Hostname}}|{{.Status}}' | grep -qx "$host|Ready"; then
              echo "removing $host's stale entry $id"
              docker node rm --force "$id"
              continue
            fi ;;
          *) echo "removing $host ($id), it left the inventory"; docker node rm --force "$id"; continue ;;
        esac
        # the state label on the state worker alone; only on change, since an update is itself a node event
        label=$(docker node inspect "$id" --format '{{index .Spec.Labels "homelab.state"}}')
        if [ "$host" = ${nodeName stateId} ] && [ "$status" = Ready ] && [ -z "$label" ]; then
          docker node update --label-add homelab.state=true "$id" >/dev/null
        elif [ "$host" != ${nodeName stateId} ] && [ -n "$label" ]; then
          docker node update --label-rm homelab.state "$id" >/dev/null
        fi
      done
    }
    reconcile
    docker events --filter type=node --format '{{.Action}} {{.Actor.Attributes.name}}' | while read -r event; do
      echo "node event: $event"
      reconcile
    done
  '';

  workerScript = pkgs.writeShellScript "swarm-worker" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ config.virtualisation.docker.package pkgs.coreutils ]}
    ${retry} 30 1 docker info
    [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = active ] && exit 0
    # a node that ran a swarm and lost it leaves cleanly before joining again
    docker swarm leave --force >/dev/null 2>&1 || true
    ${retry} 60 5 test -s ${tokens}/swarm-worker-token.token
    docker swarm join --advertise-addr ${self.ip} --data-path-addr ${self.ip} \
      --token "$(cat ${tokens}/swarm-worker-token.token)" ${manager.ip}:${toString managerPort}
  '';

  # published ports bypass INPUT through the routing mesh, on every node; the pre-dnat guard decides who reaches them
  published = group: lib.concatMap (a: map (p: p.port) (lib.attrValues (a.${group} or { }))) (lib.attrValues apps);
in {
  config = lib.mkIf (isManager || isWorker) (lib.mkMerge [
    {
      assertions = [
        { assertion = manager.type == "internal"; message = "the swarm manager (apps.nix swarm.manager) must sit in the internal zone"; }
        { assertion = workerIds != [ ]; message = "the apps swarm has no worker: add an instance of type \"apps\""; }
        { assertion = lib.elem stateId workerIds; message = "apps.nix swarm.state (vm-${stateId}) is not a running apps worker"; }
      ];

      virtualisation.docker = {
        enable = true;
        daemon.settings = {
          # a process in a container never gains privileges, whatever the image asks for
          no-new-privileges = true;
          userland-proxy = false;
          # journald, so every line ships to loki tagged with its container
          log-driver = "journald";
        };
        # images of past deploys; volumes are never pruned
        autoPrune = { enable = true; dates = "daily"; flags = [ "--all" "--filter" "until=72h" ]; };
      };

      systemd.services.swarm-cluster = {
        description = "Join, initialise or unlock the apps swarm";
        after = [ "docker.service" "network-online.target" ];
        requires = [ "docker.service" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        unitConfig.RequiresMountsFor = config.homelab.tokens.mountPoints ++ lib.optional isManager managerShare;
        startLimitIntervalSec = 0;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 15;
          ExecStart = if isManager then managerScript else workerScript;
        };
      };

      homelab.ingressOnly = {
        trustContainers = false;
        ports = published "paths" ++ published "internal" ++ published "metrics";
        # the edge for public paths; internal and metrics ports only from the default sources (ingress, prober)
        portSources = lib.genAttrs (map toString (published "paths")) (_: [ "10.200.0.200/32" ]);
      };
    }

    (lib.mkIf isManager {
      fileSystems = nasMount managerShare "swarm-manager";

      systemd.services.swarm-reconcile = {
        description = "Keep the apps swarm's nodes in line with the inventory";
        after = [ "swarm-cluster.service" ];
        requires = [ "swarm-cluster.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = { ExecStart = reconcileScript; Restart = "always"; RestartSec = 10; };
      };

      # workers reach the manager's control and gossip ports, and send their overlay traffic
      networking.firewall.extraCommands = ''
        iptables -A nixos-fw -s ${workerSubnet} -p tcp -m multiport --dports ${toString managerPort},${toString gossipPort} -j nixos-fw-accept
        iptables -A nixos-fw -s ${workerSubnet} -p udp -m multiport --dports ${toString gossipPort},${toString vxlanPort} -j nixos-fw-accept
        iptables -A nixos-fw -s ${workerSubnet} -p esp -j nixos-fw-accept
      '';

      # the forced command is the builder key's only use: no shell, no forwarding, one deploy at a time
      users.users.root.openssh.authorizedKeys.keys =
        [ ''restrict,from="${builderIp}",command="${pkgs.util-linux}/bin/flock /run/swarm-apply.lock ${swarmApply}" ${builderKey}'' ];
      # the same path by hand: `swarm-apply <app> < stack.yaml`
      environment.systemPackages = [ (pkgs.writeShellScriptBin "swarm-apply" ''
        SSH_ORIGINAL_COMMAND="''${1:?usage: swarm-apply <app> < stack.yaml}" exec ${pkgs.util-linux}/bin/flock /run/swarm-apply.lock ${swarmApply}
      '') ];

      sops.secrets = lib.genAttrs (lib.unique (lib.concatMap appSecrets (lib.attrValues apps))) (_: { });
      sops.templates = lib.mapAttrs' (name: a: lib.nameValuePair "swarm-app-${name}.env" {
        content = lib.concatStrings (lib.mapAttrsToList (k: v: "${k}=${withPlaceholders v}\n") (a.env or { }));
      }) apps;
    })

    (lib.mkIf isWorker {
      homelab.tokens.reads = [ "swarm-worker-token" ];

      # gossip and overlay traffic from the other workers and the manager; esp carries the encrypted overlays.
      # containers leave through the node's address: without DOCKER-USER they would speak nfs to the nas as the
      # node, read its tokens, or call any lab service; they get the internet and their app's telemetry only
      networking.firewall.extraCommands = ''
        for src in ${workerSubnet} ${manager.ip}; do
          iptables -A nixos-fw -s "$src" -p tcp --dport ${toString gossipPort} -j nixos-fw-accept
          iptables -A nixos-fw -s "$src" -p udp -m multiport --dports ${toString gossipPort},${toString vxlanPort} -j nixos-fw-accept
          iptables -A nixos-fw -s "$src" -p esp -j nixos-fw-accept
        done
        iptables -N DOCKER-USER 2>/dev/null || iptables -F DOCKER-USER
        iptables -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
        ${lib.optionalString (lib.any (a: a.telemetry or false) (lib.attrValues apps)) ''
          iptables -A DOCKER-USER -i docker_gwbridge -d ${telemetryHost} -p tcp -m multiport --dports ${telemetryPorts} -j RETURN
        ''}
        for dst in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
          iptables -A DOCKER-USER -i docker_gwbridge -d "$dst" -j DROP
        done
        iptables -A DOCKER-USER -j RETURN
      '';

      # per-container cpu, memory and network for vm-105; the prober and the ingress reach it, nobody else
      services.cadvisor = {
        enable = true;
        listenAddress = "0.0.0.0";
        port = catalog.cadvisorPort;
      };
      networking.firewall.allowedTCPPorts = [ catalog.cadvisorPort ];
      homelab.ingressOnly.ports = [ catalog.cadvisorPort ];

      # the state worker dumps every app database nightly to the nas, inside the container that owns it
      homelab.dbBackup.databases = lib.mkIf (ownId == stateId) (lib.foldl' (acc: name:
        acc // lib.mapAttrs' (dump: d: lib.nameValuePair "${name}-${dump}" {
          command = "${docker} exec $(${docker} ps -q --filter label=com.docker.swarm.service.name=${name}_${d.service} | head -n1) ${d.command}";
        }) (apps.${name}.dumps or { })
      ) { } (lib.attrNames apps));
    })
  ]);
}
