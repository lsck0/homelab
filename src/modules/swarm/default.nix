# the apps swarm: one manager in the internal zone, every running guest of the apps zone a worker
#
# The control plane stays inside: vm-140 (src/apps/swarm.nix `manager`) holds the raft, the stack specs and the
# secrets in them, and runs no app container (drained). The workers sit in the apps zone, a dmz of their own,
# and can neither change the cluster nor read what it stores. The cluster builds itself: the manager
# initialises it autolocked, keeps the unlock key on its own nas share and publishes the worker join token
# through its token dir (modules/tokens); workers join with it. Nodes leave by leaving the inventory, and a
# node is the inventory's only at the inventory's address.
#
# Deploys, all through one step, swarm-deploy: render the app's stack through lib/swarm-render.py (homelab
# ports, env, limits, encryption, policy), `docker stack deploy`, then check that no service rolled back, keep
# the stack the builder sent, and write the result for prometheus.
# - swarm-deploy@<app>: the builder on this manager hands a new commit's stack over (its inbox); a guest's own swarm
#   takes it over ssh, the forced command swarm-apply.
# - swarm-converge: on every switch whose catalog, policy or app secrets changed, and at boot, every kept stack is
#   rendered again and deployed; a stack whose app left the catalog or was disabled is removed. A catalog edit
#   therefore reaches the running app without a commit to it.
# Nothing here polls.
#
# A service whose published ports change is removed and created anew, never updated in place. Docker 28.5
# (libnetwork addLBBackend) keys a service's load balancer by its id and ports, so the new ports get a second balancer
# for the same vip; adding that vip to the ingress sandbox fails with EEXIST while the old balancer holds it, the
# new ports are never programmed, and the old ones go when the old tasks do: the app answers on no port at all.
# Delete the replacement once a docker release programs a changed port in place (the swarm test's catalog edit).
#
# Containers on a worker leave through the node's address. Without DOCKER-USER they would speak nfs to the nas as
# the node, read its tokens, or call any lab service; they get the internet and, when an app has telemetry, the
# collector (vm-105, every app's containers alike). The chain is replaced in one iptables-restore transaction and
# never removed, so a firewall restart or stop opens no window.
#
# A worker advertises what it holds for apps (modules/limits allocatableOf) as generic resources, which render
# reserves per task, and runs every container in apps.slice, capped at the same memory: the scheduler never places
# more than a worker holds, and no app can take what dockerd, gossip or the log shipper need.
#
#   swarm-apply <app> < stack.yaml        on vm-140: what the builder does, by hand
#   systemctl restart swarm-converge      on vm-140: apply the catalog to every app again
#
# Rejected: deploying from the builder alone. A deploy happened only on a new app commit, so a port, env or secret
# changed in the catalog never reached the stack, and a disabled app kept running unguarded.
{ config, lib, pkgs, inventory, site, nasMount, retry, catalog, lab, ... }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  swarmPorts = catalog.swarm.ports;
  telemetry = import ../telemetry.nix { inherit lib inventory; };
  limits = import ../limits { inherit lib; };
  privateRanges = import ../private-ranges.nix { inherit lib inventory site; };

  # docker's default overlay pool 10.0.0.0/8 holds every lab subnet; this one overlaps none (asserted below)
  overlayPool = "10.240.0.0/16";
  cidr = import ../cidr.nix { inherit lib; };
  overlayMask = 24;
  # an app's stack as the builder sends it; render refuses more (lib/swarm-render.py reads the bound from json)
  stackBytesMax = 1024 * 1024;
  # a stack deploy waits for every service to converge; a task that can never start must not hold the lock forever
  deployTimeoutS = 20 * 60;
  # more copies of one service than this per worker only crowd out the other apps
  replicasPerWorkerMax = 2;
  # a stack's services: each is a task at least, a container and a scrape series set on some worker
  servicesMax = 32;
  # per-worker allocatable the swarm schedules against (memory in MiB, cpu in millicores), reserved per task
  genericResources = { memory = "HOMELAB_MEMORY_MIB"; cpu = "HOMELAB_CPU_MILLIS"; };
  # every app container lives here, capped below the node; the node's own services outweigh it on cpu
  appsSlice = "apps";
  appsSliceCpuWeight = 50;
  appsSliceTasksMax = 8192;
  # dockerd answering after boot; a booting worker reconnecting to its manager (pending) before anything is decided
  dockerWait = { attempts = 30; intervalS = 1; };
  settleWait = { attempts = 60; intervalS = 2; };
  # the manager publishes the join token shortly after it initialised the swarm
  tokenWait = { attempts = 60; intervalS = 5; };
  # images of past deploys; volumes are never pruned
  imageKeep = "72h";
  restartDelayS = { cluster = 15; reconcile = 10; };

  tokens = config.homelab.tokens.dir;
  docker = "${config.virtualisation.docker.package}/bin/docker";
  textfileDir = "/var/lib/node-exporter-textfile";
  # the unlock key on a nas share only the manager mounts: off the disk whose raft it opens
  managerShare = "/var/lib/swarm-manager-nas";
  unlockKey = "${managerShare}/unlock-key";
  # what the builder last sent per app, which converge renders again
  stackDir = "/var/lib/swarm-apply";
  # the pull credential's docker config: root's alone, sent to the workers with each deploy (--with-registry-auth)
  dockerConfigDir = "${stackDir}/docker";
  loginTimeoutS = 60;
  lockFile = "/run/swarm-apply.lock";
  controllerState = "/run/controller-api";
  # a request reads a few headers; a client that dribbles them holds a process no longer than this
  controllerRequestMaxS = 10;
  # the boards apps ship, which vm-105 provisions (instances/140-internal-swarm/lib/dashboards-import.py writes <app>/ under the dir)
  appDashboardsMount = "/var/lib/app-dashboards";
  # a woken app's task starts within a deploy's image pull; the dump waits that long, then fails and alerts
  dumpWakeWait = { attempts = 60; intervalS = 5; };
  # db-backup's own dump directory (modules/db-backup), where the volume archives land
  dbBackupDir = "/var/backup/db";
  # an idle-stopped app's marker: deploys keep it at 0 replicas, the controller answers its state from here
  stoppedDir = "/var/lib/swarm-idle";
  # the controller's door (lib/controller-api.py): redeploys from ci, wake and sleep from the ingresses
  inherit (catalog.swarm) controllerPort;
  controllerUser = "controller";
  # one redeploy per app per minute: a ci retry loop costs one build
  redeployIntervalS = 60;
  units = { redeploy = "app-builder@%s.service"; wake = "swarm-idle-wake@%s.service"; sleep = "swarm-idle-sleep@%s.service"; };

  idleApps = lib.filterAttrs (_: a: a.idle.stopAfter != null) apps;
  idleCheck = ''
    app=$1
    case " ${lib.concatStringsSep " " (lib.attrNames idleApps)} " in *" $app "*) ;; *) echo "$app never idles" >&2; exit 2 ;; esac
  '';
  idleReport = state: ''
    printf '# TYPE homelab_app_idle_stopped gauge\nhomelab_app_idle_stopped{app="%s"} ${toString state}\n' "$app" > ${textfileDir}/swarm_idle_$app.prom.tmp
    mv ${textfileDir}/swarm_idle_$app.prom.tmp ${textfileDir}/swarm_idle_$app.prom
  '';
  idleSleep = pkgs.writeShellScript "swarm-idle-sleep" ''
    set -euo pipefail
    export PATH=${dockerPath}
    ${idleCheck}
    touch ${stoppedDir}/"$app"
    for service in $(docker stack services -q "$app"); do docker service scale --detach "$service=0" >/dev/null; done
    ${idleReport 1}
  '';
  idleWake = pkgs.writeShellScript "swarm-idle-wake" ''
    set -euo pipefail
    export PATH=${dockerPath}
    ${idleCheck}
    # the gauge follows the marker /state reads; a failed rollout is swarm-deploy's own gauge
    rm -f ${stoppedDir}/"$app"
    ${idleReport 0}
    ${swarmDeploy} "$app" ${stackDir}/"$app".yaml
  '';
  controllerConfig = pkgs.writeText "controller-api.json" (builtins.toJSON {
    apps = lib.mapAttrs (name: a: {
      tokenFile = if isController then config.sops.secrets."app-${name}-redeploy-token".path else null;
      idle = a.idle.stopAfter != null;
    }) (if isController then catalog.apps else apps);
    # the ingresses wake an idle app for a request, the state worker for a dump
    wakers = map (i: i.ip) (lib.attrValues catalog.ingress) ++ [ inventory.${stateId}.ip ];
    inherit redeployIntervalS units;
    stateDir = controllerState;
    inherit stoppedDir;
  });

  # a local builder's stack, as the forced command reads it from ssh: bounded, then the one deploy step
  deployUnit = "swarm-deploy@";
  deployFromInbox = pkgs.writeShellScript "swarm-deploy-inbox" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    app=$1
    [[ "$app" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "swarm-deploy: '$app' is no app name" >&2; exit 2; }
    work=$(umask 077; mktemp -d /run/swarm-apply.XXXXXX)
    trap 'rm -rf "$work"' EXIT
    head -c ${toString (stackBytesMax + 1)} < ${config.homelab.swarm.deployInbox}/"$app".yaml > "$work/stack.yaml"
    ${swarmDeploy} "$app" "$work/stack.yaml"
  '';

  # the builder's key (homelab.swarm.deployKey) is usable from the builder's vm only
  builderIp = catalog.builder.ip;
  # the dashboard's status dots (103-internal-homepage.nix) reach every app route
  homepageSource = "${inventory."103".ip}/32";
  edgeSource = "${catalog.ingress.external.ip}/32";

  # -----------------------------------------------------------------------------
  # INTERNAL
  # -----------------------------------------------------------------------------

  match = builtins.match "vm-([0-9]+)" config.networking.hostName;
  ownId = if match == null then null else builtins.head match;

  # the one user the registry's read route admits and its write route does not (118's instance.nix): the swarms'
  pullUsers = removeAttrs catalog.internal.registry-api.basicAuth (lib.attrNames catalog.internal.registry-push.basicAuth);
  pullUser = assert lib.length (lib.attrNames pullUsers) == 1; lib.head (lib.attrNames pullUsers);
  pullSecret = pullUsers.${pullUser};
  # the shared swarm and each guest-placed app's swarm of one; this host takes the role its cluster gives it
  clusters = {
    shared = {
      inherit (catalog.swarm) managerId stateId;
      workerIds = lib.sort (a: b: lib.toInt a < lib.toInt b)
        (lib.attrNames (lib.filterAttrs (_: v: v.type == "apps" && v.enabled != "false") inventory));
      apps = lib.filterAttrs (_: a: a.placement == null) catalog.apps;
    };
  } // lib.mapAttrs' (name: a: let id = toString a.placement.vmid; in lib.nameValuePair "app-${name}" {
    managerId = id;
    stateId = id;
    workerIds = [ id ];
    apps.${name} = a;
  }) (lib.filterAttrs (_: a: a.placement != null) catalog.apps);
  own = lib.findFirst (c: ownId == c.managerId || lib.elem ownId c.workerIds) null (lib.attrValues clusters);
  inherit (own) apps managerId stateId workerIds;
  manager = inventory.${managerId};
  isManager = own != null && ownId == managerId;
  isWorker = own != null && lib.elem ownId workerIds;
  # a swarm of one: its manager runs the app, there is no worker to join, no node to reconcile
  single = workerIds == [ managerId ];
  # the deploy controller (the builder's host) takes redeploys for every app, whatever its cluster
  isController = ownId == toString config.homelab.appsCatalog.builder;
  allocatable = limits.allocatableOf lab.instances.${ownId}.config.vm;
  self = inventory.${ownId};
  nodeName = id: "vm-${id}";
  dockerPath = lib.makeBinPath [ config.virtualisation.docker.package pkgs.coreutils pkgs.gnugrep pkgs.util-linux ];

  # what swarm-render.py needs; secrets stay as {{name}} here, sops renders them into each app's env file
  catalogJson = pkgs.writeText "swarm-apps.json" (builtins.toJSON {
    inherit (catalog) registry;
    inherit stackBytesMax servicesMax genericResources;
    inherit (telemetry) tenantHeader;
    # one slot free across the workers, so a start-first update always finds room for its new task
    replicasMax = replicasPerWorkerMax * lib.length workerIds - 1;
    replicasPerNodeMax = replicasPerWorkerMax;
    taskDefaults = withCpuMillis config.homelab.appsCatalog.swarm.taskDefaults;
    apps = lib.mapAttrs (name: a: {
      inherit (a) exclude stateful override images;
      published = lib.unique (map (p: { inherit (p) service targetPort port; }) (lib.attrValues a.routes ++ lib.attrValues a.metrics));
      resources = lib.mapAttrs (_: withCpuMillis) a.resources;
      reservation = { inherit (a.reservation) memoryMiB; cpuMillis = limits.cpuMillisUp a.reservation.cpus; };
      tenant = if telemetry.sendsSignals a then telemetry.tenantOf name else null;
      volumes = lib.mapAttrs (_: v: { inherit (v) backup; }) a.volumes;
    }) apps;
  });
  withCpuMillis = task: task // { cpuMillis = limits.taskCpuMillis; };

  # "{{name}}" in a catalog env value is the sops secret <name>
  secretRefs = value: map lib.head (builtins.filter builtins.isList
    (builtins.split "\\{\\{([a-z0-9][a-z0-9-]*)}}" value));
  appSecrets = a: lib.unique (lib.concatMap secretRefs (lib.concatMap lib.attrValues (lib.attrValues a.env)));
  withPlaceholders = value: builtins.replaceStrings
    (map (n: "{{${n}}}") (secretRefs value))
    (map (n: config.sops.placeholder.${n}) (secretRefs value)) value;
  # one line per value, <service>.<KEY>=<value> (swarm-render.py env_file_parse); generated secrets hold no newline
  envFileOf = a: lib.concatStrings (lib.concatLists (lib.mapAttrsToList (service: env:
    lib.mapAttrsToList (key: value: "${service}.${key}=${withPlaceholders value}\n") env) a.env));
  # sops-nix renders templates here, as /run/secrets/rendered/swarm-app-<app>.env
  envDir = "/run/secrets/rendered";

  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  render = "${python}/bin/python3 ${./lib/swarm-render.py}";

  # swarm-deploy <app> <stack file>: render, deploy, check, keep; the one way a stack reaches the swarm
  swarmDeploy = pkgs.writeShellScript "swarm-deploy" ''
    set -euo pipefail
    export PATH=${dockerPath}:${lib.makeBinPath [ pkgs.jq ]}
    app=$1 input=$2
    # the name becomes a path and a stack name; render knows which apps exist
    [[ "$app" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "swarm-deploy: '$app' is no app name" >&2; exit 2; }
    metrics=${textfileDir}/swarm_app_$app.prom
    # to the caller (the builder's journal) and to this manager's own, tagged swarm-deploy
    say() { echo "swarm-deploy: $*"; logger -t swarm-deploy -- "$*"; }
    report() {
      printf '# TYPE homelab_swarm_deploy_ok gauge\nhomelab_swarm_deploy_ok{app="%s"} %s\n# TYPE homelab_swarm_deploy_timestamp_seconds gauge\nhomelab_swarm_deploy_timestamp_seconds{app="%s"} %s\n' \
        "$app" "$1" "$app" "$(date +%s)" > "$metrics.tmp"
      mv "$metrics.tmp" "$metrics"
    }
    work=$(umask 077; mktemp -d /run/swarm-deploy.XXXXXX)
    trap 'rm -rf "$work"' EXIT
    # converge passes the kept stack itself, which the last step replaces
    cp "$input" "$work/input.yaml"
    # a sleeping app is deployed asleep: new images and settings, no task until it is woken
    stopped=""
    [ ! -e ${stoppedDir}/"$app" ] || stopped=stopped
    if ! ${render} "$app" ${catalogJson} ${envDir}/swarm-app-"$app".env $stopped < "$work/input.yaml" > "$work/stack.yaml"; then
      # unknown app or policy refusal: render said why, nothing changed on the swarm
      report 0
      exit 2
    fi
    say "deploying $app"
    export DOCKER_CONFIG=${dockerConfigDir}
    if ! timeout ${toString loginTimeoutS} docker login ${catalog.registry} -u ${pullUser} --password-stdin \
        < ${config.sops.secrets.${pullSecret}.path} >/dev/null; then
      report 0
      say "the registry refused the pull credential" >&2
      exit 1
    fi
    # docker cannot move a running service's published ports (header): such a service is created anew
    for service in $(docker stack services --format '{{.Name}}' "$app"); do
      wanted=$(jq -r --arg app "$app" --arg service "''${service#"$app"_}" \
        '[.apps[$app].published[] | select(.service == $service) | "\(.port):\(.targetPort)"] | sort | join(" ")' ${catalogJson})
      running=$(docker service inspect --format '{{json .Endpoint.Spec.Ports}}' "$service" \
        | jq -r '[.[]? | "\(.PublishedPort):\(.TargetPort)"] | sort | join(" ")')
      if [ "$wanted" != "$running" ]; then
        say "replacing $service: its published ports change from '$running' to '$wanted'"
        docker service rm "$service" >/dev/null
      fi
    done
    started=$(date +%s)
    # the swarm rolls a service back when its new tasks fail their healthchecks (update_config failure_action)
    if ! timeout ${toString deployTimeoutS} docker stack deploy --detach=false --prune --resolve-image always \
        --with-registry-auth -c "$work/stack.yaml" "$app"; then
      report 0
      say "$app did not converge within ${toString deployTimeoutS}s" >&2
      exit 1
    fi
    # a rollback still ends the deploy with 0: an update this deploy started that ended in rollback is a failure
    rolled_back=""
    for service in $(docker stack services --format '{{.Name}}' "$app"); do
      status=$(docker service inspect --format '{{if .UpdateStatus}}{{.UpdateStatus.State}} {{.UpdateStatus.StartedAt.Unix}}{{end}}' "$service")
      state=''${status% *} since=''${status#* }
      case "$state" in
        rollback_started|rollback_paused|rollback_completed|paused)
          [ "$since" -ge "$started" ] && rolled_back="$rolled_back $service($state)" ;;
      esac
    done
    if [ -n "$rolled_back" ]; then
      report 0
      say "$app rolled back:$rolled_back; the previous version keeps running" >&2
      exit 1
    fi
    install -D -m 0600 "$work/input.yaml" ${stackDir}/"$app".yaml
    report 1
    say "$app deployed"
  '';

  # the builder's forced command: `ssh root@<manager> <app>`, the stack on stdin
  swarmApply = pkgs.writeShellScript "swarm-apply" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    app=''${SSH_ORIGINAL_COMMAND:-}
    work=$(umask 077; mktemp -d /run/swarm-apply.XXXXXX)
    trap 'rm -rf "$work"' EXIT
    # one byte over the bound, so render can refuse an oversized stack by name
    head -c ${toString (stackBytesMax + 1)} > "$work/stack.yaml"
    ${swarmDeploy} "$app" "$work/stack.yaml"
  '';

  # the catalog applied to every kept stack; the stacks of apps that left the catalog removed
  swarmConverge = pkgs.writeShellScript "swarm-converge" ''
    set -uo pipefail
    export PATH=${dockerPath}
    enabled=" ${lib.concatStringsSep " " (lib.attrNames apps)} "
    failed=0
    for stack in $(docker stack ls --format '{{.Name}}'); do
      case "$enabled" in
        *" $stack "*) ;;
        *)
          # volumes stay on the state worker: data is removed by hand, never by a catalog edit
          echo "swarm-converge: removing $stack, it is not an enabled app"
          docker stack rm "$stack" || failed=1
          rm -f ${stackDir}/"$stack".yaml ${textfileDir}/swarm_app_"$stack".prom ${textfileDir}/swarm_idle_"$stack".prom ${stoppedDir}/"$stack"
          rm -rf ${appDashboardsMount}/${telemetry.appDashboardsDir}/"$stack" ;;
      esac
    done
    for app in $enabled; do
      if [ -f ${stackDir}/"$app".yaml ]; then
        ${swarmDeploy} "$app" ${stackDir}/"$app".yaml || failed=1
      else
        echo "swarm-converge: $app has no stack yet; the builder deploys its first commit"
      fi
    done
    exit "$failed"
  '';

  addrs = ip: ''--advertise-addr ${ip} --listen-addr ${ip}:${toString swarmPorts.manager} --data-path-addr ${ip}'';
  waitForDocker = "${retry} ${toString dockerWait.attempts} ${toString dockerWait.intervalS} docker info";

  managerScript = pkgs.writeShellScript "swarm-manager" ''
    set -euo pipefail
    export PATH=${dockerPath}
    ${waitForDocker}
    state=$(docker info --format '{{.Swarm.LocalNodeState}}')
    case "$state" in
      active) ;;
      locked) docker swarm unlock < ${unlockKey} ;;
      inactive)
        echo "initialising the apps swarm"
        docker swarm init ${addrs manager.ip} --autolock \
          --default-addr-pool ${overlayPool} --default-addr-pool-mask-length ${toString overlayMask} >/dev/null ;;
      # pending or error on the node holding the raft: re-initialising would drop every stack
      *) echo "swarm-manager: the swarm is $state; inspect with docker info before anything else" >&2; exit 1 ;;
    esac
    umask 077
    docker swarm unlock-key -q > ${unlockKey}.tmp && mv ${unlockKey}.tmp ${unlockKey}
    ${if single then ''
      # the guest is its own state worker
      docker node update --label-add homelab.state=true ${nodeName managerId} >/dev/null
    '' else ''
      own=${config.homelab.tokens.ownDir}
      docker swarm join-token -q worker > "$own/swarm-worker-token.tmp" && mv "$own/swarm-worker-token.tmp" "$own/swarm-worker-token.token"
      # the manager schedules, it never runs an app
      docker node update --availability drain ${nodeName managerId} >/dev/null
    ''}
  '';

  # the cluster's shape follows the inventory: on start and on every node event, never on a timer
  reconcileScript = pkgs.writeShellScript "swarm-reconcile" ''
    set -uo pipefail
    export PATH=${dockerPath}
    # hostname -> its inventory address; a node is the inventory's only from there
    declare -A address=( ${lib.concatMapStringsSep " " (id: "[${nodeName id}]=${inventory.${id}.ip}") workerIds} )
    reconcile() {
      docker node ls --format '{{.ID}}|{{.Hostname}}|{{.Status}}|{{.ManagerStatus}}' | while IFS='|' read -r id host status role; do
        # a node still joining has no hostname yet: never mistake it for one that left
        [ -n "$host" ] && [ "$status" != Unknown ] || continue
        # the manager is this node: only a manager token, which never leaves it, joins as one
        [ -n "$role" ] && continue
        if [ -z "''${address[$host]:-}" ]; then
          echo "removing $host ($id), it left the inventory"; docker node rm --force "$id"; continue
        fi
        addr=$(docker node inspect "$id" --format '{{.Status.Addr}}')
        if [ "$addr" != "''${address[$host]}" ]; then
          # a worker calling itself another, from elsewhere: the token alone is no identity
          echo "removing $id, it claims $host from $addr, not ''${address[$host]}"; docker node rm --force "$id"; continue
        fi
        # a down entry with a ready twin is a node's previous membership
        if [ "$status" = Down ] && docker node ls --format '{{.Hostname}}|{{.Status}}' | grep -qx "$host|Ready"; then
          echo "removing $host's stale entry $id"; docker node rm --force "$id"; continue
        fi
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
    export PATH=${dockerPath}
    ${waitForDocker}
    # pending: its manager boots later; leaving would throw away a good membership, so the case below waits too
    if ! ${retry} ${toString settleWait.attempts} ${toString settleWait.intervalS} \
        ${pkgs.runtimeShell} -c '[ "$(docker info --format "{{.Swarm.LocalNodeState}}")" != pending ]'; then
      echo "swarm-worker: still pending after ${toString (settleWait.attempts * settleWait.intervalS)}s" >&2
    fi
    state=$(docker info --format '{{.Swarm.LocalNodeState}}')
    case "$state" in
      active) exit 0 ;;
      inactive) ;;
      # a membership that cannot recover: leave it cleanly, then join again
      error) docker swarm leave --force >/dev/null ;;
      pending) echo "swarm-worker: still pending, the manager is unreachable; trying again later" >&2; exit 1 ;;
      *) echo "swarm-worker: unexpected swarm state $state on a worker" >&2; exit 1 ;;
    esac
    ${retry} ${toString tokenWait.attempts} ${toString tokenWait.intervalS} test -s ${tokens}/swarm-worker-token.token
    docker swarm join --advertise-addr ${self.ip} --data-path-addr ${self.ip} \
      --token "$(cat ${tokens}/swarm-worker-token.token)" ${manager.ip}:${toString swarmPorts.manager}
  '';

  # DOCKER-USER (see the header): the internet and, with telemetry, the collector; replaced in one transaction
  telemetryOn = lib.any telemetry.sendsSignals (lib.attrValues apps);
  collector = inventory.${telemetry.collectorVmid};
  telemetryPorts = with telemetry.ports; [ otlpGrpc otlpHttp pyroscope ];
  dockerUserRules = pkgs.writeText "docker-user.rules" (lib.concatLines ([
    "*filter"
    ":DOCKER-USER - [0:0]"
    "-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN"
  ] ++ lib.optional telemetryOn
    "-A DOCKER-USER -i docker_gwbridge -d ${collector.ip}/32 -p tcp -m multiport --dports ${lib.concatMapStringsSep "," toString telemetryPorts} -j RETURN"
  ++ map (range: "-A DOCKER-USER -i docker_gwbridge -d ${range} -j DROP") privateRanges
  ++ [
    "-A DOCKER-USER -j RETURN"
    "COMMIT"
  ]));

  # an asleep app is woken for its dump and sleeps again after its idle window
  volumeDump = pkgs.writeShellScript "swarm-dump" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ config.virtualisation.docker.package pkgs.curl pkgs.coreutils ]}
    app=$1 idle=$3
    export task_service="$app"_"$2"
    shift 3
    task() { docker ps -q --filter label=com.docker.swarm.service.name="$task_service" | head -n1; }
    if [ -z "$(task)" ] && [ "$idle" = true ]; then
      curl -sf -m ${toString controllerRequestMaxS} -X POST http://${manager.ip}:${toString controllerPort}/wake/"$app" >/dev/null
      ${retry} ${toString dumpWakeWait.attempts} ${toString dumpWakeWait.intervalS} \
        ${pkgs.runtimeShell} -c '[ -n "$(docker ps -q --filter label=com.docker.swarm.service.name="$task_service")" ]'
    fi
    exec docker exec "$(task)" "$@"
  '';

  volumeRestore = pkgs.writeShellScriptBin "swarm-volume-restore" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ config.virtualisation.docker.package pkgs.gnutar pkgs.zstd pkgs.coreutils pkgs.findutils ]}
    app=''${1:?usage: swarm-volume-restore <app> <volume> [<archive>]}
    volume=''${2:?usage: swarm-volume-restore <app> <volume> [<archive>]}
    archive=''${3:-$(ls -1 ${dbBackupDir}/"$app"-volume-"$volume"/*.tar.zst | sort | tail -n1)}
    # a running task would see its files change under it: scale it to 0 on the manager first
    if [ -n "$(docker ps -q --filter volume="$app"_"$volume")" ]; then
      echo "swarm-volume-restore: $app's volume $volume is in use; on vm-${managerId}: docker service scale <its service>=0" >&2
      exit 1
    fi
    dir=$(docker volume inspect --format '{{.Mountpoint}}' "$app"_"$volume")
    find "$dir" -mindepth 1 -delete
    zstd -dc "$archive" | tar -C "$dir" -xf -
    echo "swarm-volume-restore: $app's volume $volume restored from $archive"
  '';

  # the state worker archives each volume an app marks for backup, its containers paused for a crash-consistent copy
  volumeArchive = pkgs.writeShellScript "swarm-volume-archive" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ config.virtualisation.docker.package pkgs.gnutar ]}
    volume=$1
    dir=$(docker volume inspect --format '{{.Mountpoint}}' "$volume")
    ids=$(docker ps -q --filter volume="$volume")
    trap '[ -z "$ids" ] || docker unpause $ids >/dev/null' EXIT
    [ -z "$ids" ] || docker pause $ids >/dev/null
    tar -C "$dir" -cf - .
  '';
in {
  imports = [ ../app-telemetry.nix ];

  options.homelab.swarm = {
    deployKey = lib.mkOption {
      type = lib.types.str;
      default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGI2KxZj2UXbIt/41+9I8NsSj5vh3eTLRVH+f/vZD1qY app-builder@vm-117";
      description = ''
        The app builder's public key, the only key the manager's forced command swarm-apply accepts; its private half
        is the sops secret app-deploy-key on the builder's host (src/apps/swarm.nix `builder`). The restriction (source
        address, command, no forwarding) is the module's, whatever key is set.
      '';
    };
    deployTimeoutS = lib.mkOption {
      type = lib.types.ints.positive;
      readOnly = true;
      default = deployTimeoutS;
      description = "How long one deploy may take on the manager; the builder waits for it a little longer.";
    };
    deployInbox = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        A directory of stacks (<app>.yaml) that `swarm-deploy@<app>` deploys on this manager: the builder's, on the
        host that builds (instances/140-internal-swarm/lib/app-builder.nix), which may start that unit and nothing else of it.
      '';
    };
    deployUnit = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = deployUnit;
      description = "The unit template a local builder starts to deploy one app's stack from its inbox.";
    };
    appDashboardsDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${appDashboardsMount}/${telemetry.appDashboardsDir}";
      description = "Where the controller writes the boards apps ship (instances/140-internal-swarm/lib/dashboards-import.py), vm-105 reads them.";
    };
  };

  config = lib.mkIf (isManager || isWorker) (lib.mkMerge [
    {
      assertions = [
        { assertion = single || manager.type == "internal"; message = "the swarm manager (src/apps/swarm.nix manager) must sit in the internal zone"; }
        { assertion = workerIds != [ ]; message = "the apps swarm has no worker: add an instance of type \"apps\""; }
        { assertion = lib.elem stateId workerIds; message = "src/apps/swarm.nix state (vm-${stateId}) is not a running apps worker"; }
        {
          assertion = !(lib.any (z: cidr.overlaps overlayPool z.subnet) (lib.attrValues (lib.importJSON ../../generated/zones.json)));
          message = "modules/swarm: the overlay pool ${overlayPool} overlaps a zone of zones.json";
        }
      ];

      virtualisation.docker = {
        enable = true;
        daemon.settings = {
          # a process in a container never gains privileges, whatever the image asks for
          no-new-privileges = true;
          userland-proxy = false;
        };
        autoPrune = { enable = true; dates = "daily"; flags = [ "--all" "--filter" "until=${imageKeep}" ]; };
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
          RestartSec = restartDelayS.cluster;
          ExecStart = if isManager then managerScript else workerScript;
        };
      };

      # published ports bypass INPUT through the routing mesh, on every node; the pre-dnat guard decides who reaches them
      homelab.ingressOnly = {
        trustContainers = false;
        ports = catalog.ports.external ++ catalog.ports.internal ++ catalog.ports.metrics;
        # external routes from the edge, every route from the dashboard's status dots, metrics from the default sources
        portSources = lib.genAttrs (map toString catalog.ports.internal) (_: [ homepageSource ])
          // lib.genAttrs (map toString catalog.ports.external) (_: [ edgeSource homepageSource ]);
      };
    }

    (lib.mkIf isManager {
      homelab.nasMounts = nasMount managerShare (if single then "swarm-manager-${ownId}" else "swarm-manager")
        // lib.optionalAttrs isController (nasMount appDashboardsMount telemetry.appDashboardsShare);

      systemd.services.swarm-reconcile = lib.mkIf (!single) {
        description = "Keep the apps swarm's nodes in line with the inventory";
        after = [ "swarm-cluster.service" ];
        requires = [ "swarm-cluster.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = { ExecStart = reconcileScript; Restart = "always"; RestartSec = restartDelayS.reconcile; };
      };

      systemd.services.swarm-converge = {
        description = "Apply the app catalog to every deployed app, remove the stacks of apps that left it";
        after = [ "swarm-cluster.service" ];
        requires = [ "swarm-cluster.service" ];
        wantedBy = [ "multi-user.target" ];
        # a switch that changes what render produces re-runs it; sops restarts it when an app secret changes
        restartTriggers = [ catalogJson ./lib/swarm-render.py swarmDeploy ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.util-linux}/bin/flock ${lockFile} ${swarmConverge}";
          TimeoutStartSec = deployTimeoutS * (lib.length (lib.attrNames apps) + 1);
        };
      };

      systemd.tmpfiles.rules = [
        "d ${stackDir} 0700 root root -"
        "d ${dockerConfigDir} 0700 root root -"
        "d ${stoppedDir} 0755 root root -"
        "d ${controllerState} 0700 ${controllerUser} ${controllerUser} -"
      ];

      # the local builder's deploys, one at a time like every other
      systemd.services."${deployUnit}" = lib.mkIf (config.homelab.swarm.deployInbox != null) {
        description = "Deploy the app %i from the builder's inbox";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.util-linux}/bin/flock ${lockFile} ${deployFromInbox} %i";
          TimeoutStartSec = deployTimeoutS;
        };
      };

      # idle apps: asleep at 0 replicas, woken by a deploy of the kept stack, both under the deploy lock
      systemd.services."swarm-idle-sleep@" = {
        description = "Stop the idle app %i";
        serviceConfig = { Type = "oneshot"; ExecStart = "${pkgs.util-linux}/bin/flock ${lockFile} ${idleSleep} %i"; };
      };
      systemd.services."swarm-idle-wake@" = {
        description = "Wake the idle app %i";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.util-linux}/bin/flock ${lockFile} ${idleWake} %i";
          TimeoutStartSec = deployTimeoutS;
        };
      };

      # the controller's door: one short unprivileged process per connection, idle costs nothing
      users.users.${controllerUser} = { isSystemUser = true; group = controllerUser; };
      users.groups.${controllerUser} = { };
      systemd.sockets.controller-api = {
        wantedBy = [ "sockets.target" ];
        socketConfig = { ListenStream = controllerPort; Accept = true; };
      };
      systemd.services."controller-api@" = {
        description = "Deploy controller request";
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${./lib/controller-api.py} ${controllerConfig}";
          StandardInput = "socket";
          StandardError = "journal";
          User = controllerUser;
          RuntimeMaxSec = controllerRequestMaxS;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ controllerState ];
          PrivateTmp = true;
        };
      };
      # it may start these unit templates and nothing else
      security.polkit.enable = true;
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" && subject.user == "${controllerUser}"
              && action.lookup("verb") == "start"
              && /^(app-builder|swarm-idle-wake|swarm-idle-sleep)@[a-z][a-z0-9-]*\.service$/.test(action.lookup("unit"))) {
            return polkit.Result.YES;
          }
        });
      '';
      networking.firewall.allowedTCPPorts = [ controllerPort ];
      homelab.ingressOnly.ports = [ controllerPort ];
      homelab.ingressOnly.portSources.${toString controllerPort} =
        map (i: "${i.ip}/32") (lib.attrValues catalog.ingress) ++ [ "${inventory.${stateId}.ip}/32" ];

      # workers reach the manager's control and gossip ports, and send their overlay traffic
      networking.firewall.extraCommands = lib.mkIf (!single) ''
        iptables -A nixos-fw -s ${catalog.appsZone} -p tcp -m multiport --dports ${toString swarmPorts.manager},${toString swarmPorts.gossip} -j nixos-fw-accept
        iptables -A nixos-fw -s ${catalog.appsZone} -p udp -m multiport --dports ${toString swarmPorts.gossip},${toString swarmPorts.vxlan} -j nixos-fw-accept
        iptables -A nixos-fw -s ${catalog.appsZone} -p esp -j nixos-fw-accept
      '';

      # the forced command is the builder key's only use: no shell, no forwarding, one deploy at a time
      users.users.root.openssh.authorizedKeys.keys =
        [ ''restrict,from="${builderIp}",command="${pkgs.util-linux}/bin/flock ${lockFile} ${swarmApply}" ${config.homelab.swarm.deployKey}'' ];
      # the same path by hand: `swarm-apply <app> < stack.yaml`
      environment.systemPackages = [ (pkgs.writeShellScriptBin "swarm-apply" ''
        SSH_ORIGINAL_COMMAND="''${1:?usage: swarm-apply <app> < stack.yaml}" exec ${pkgs.util-linux}/bin/flock ${lockFile} ${swarmApply}
      '') ];

      # app secrets and the pull credential: a rotation redeploys every app with the new value
      sops.secrets = lib.genAttrs (lib.unique (lib.concatMap appSecrets (lib.attrValues apps) ++ [ pullSecret ]))
        (_: { restartUnits = [ "swarm-converge.service" ]; })
        // lib.optionalAttrs isController
          (lib.mapAttrs' (name: _: lib.nameValuePair "app-${name}-redeploy-token" { owner = controllerUser; }) catalog.apps);
      sops.templates = lib.mapAttrs' (name: a: lib.nameValuePair "swarm-app-${name}.env" {
        content = envFileOf a;
        restartUnits = [ "swarm-converge.service" ];
      }) apps;
    })

    (lib.mkIf isWorker {
      homelab.tokens.reads = lib.mkIf (!single) [ "swarm-worker-token" ];

      # gossip and overlay traffic from the other workers and the manager; esp carries the encrypted overlays
      networking.firewall.extraCommands = lib.optionalString (!single) ''
        for src in ${catalog.appsZone} ${manager.ip}; do
          iptables -A nixos-fw -s "$src" -p tcp --dport ${toString swarmPorts.gossip} -j nixos-fw-accept
          iptables -A nixos-fw -s "$src" -p udp -m multiport --dports ${toString swarmPorts.gossip},${toString swarmPorts.vxlan} -j nixos-fw-accept
          iptables -A nixos-fw -s "$src" -p esp -j nixos-fw-accept
        done
      '' + ''
        iptables-restore --noflush < ${dockerUserRules}
      '';

      # container logs and metrics per app (modules/app-telemetry.nix)
      homelab.appTelemetry.enable = true;

      # what the worker holds for apps: the scheduler places reservations against it, the slice caps the containers
      virtualisation.docker.daemon.settings = {
        cgroup-parent = "${appsSlice}.slice";
        node-generic-resources = [
          "${genericResources.memory}=${toString allocatable.memoryMiB}"
          "${genericResources.cpu}=${toString allocatable.cpuMillis}"
        ];
      };
      # a task over its memory limit is killed inside its own cgroup; the node never panics for it
      boot.kernel.sysctl."vm.panic_on_oom" = 0;
      systemd.slices.${appsSlice}.sliceConfig = {
        MemoryMax = "${toString allocatable.memoryMiB}M";
        CPUWeight = appsSliceCpuWeight;
        TasksMax = appsSliceTasksMax;
      };

      # the state worker's nightly dumps (in the container that owns the database) and volume archives, to the nas
      homelab.dbBackup.databases = lib.mkIf (ownId == stateId) (lib.foldl' (acc: name: let a = apps.${name}; in
        acc // lib.mapAttrs' (dump: d: lib.nameValuePair "${name}-${dump}" {
          command = "${volumeDump} ${name} ${d.service} ${lib.boolToString (a.idle.stopAfter != null)} ${d.command}";
        }) a.dumps
        // lib.mapAttrs' (volume: _: lib.nameValuePair "${name}-volume-${volume}" {
          command = "${volumeArchive} ${name}_${volume}";
          suffix = "tar";
        }) (lib.filterAttrs (_: v: v.backup) a.volumes)
      ) { } (lib.attrNames apps));
      # the way back: an archive into its volume while nothing mounts it
      environment.systemPackages = lib.optional (ownId == stateId) volumeRestore;
    })
  ]);
}
