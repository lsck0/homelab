# the apps swarms: the shared one (manager vm-107 in the internal zone, workers in the apps zone) and each
# guest-placed app's swarm of one, every host taking the role its cluster (catalog.clusters) gives it
#
# security: the manager holds the raft and the stacks' secrets and runs no app; workers in the apps zone can neither
# change the cluster nor read what it stores. The swarm is autolocked, its unlock key on the manager's own nas share.
# A worker's containers get the internet only (DOCKER-USER, replaced in one iptables-restore and never removed).
# swarm-deploy is the one way a stack reaches the swarm: the builder's swarm-apply, and swarm-converge-<app> on every
# switch that changes the app's catalog entry. A sleeping app is deployed awake until it converged, so a wake is a
# scale that never pulls.
#
# workaround: a service whose published ports change is removed and created anew. Docker 28.5 (libnetwork
# addLBBackend) keys a service's load balancer by its id and ports, so new ports get a second balancer for the same
# vip, which fails with EEXIST in the ingress sandbox: the app answers on no port. Delete once a docker release
# programs a changed port in place (the swarm test's catalog edit).
#
# Rejected: deploying from the builder alone. A port, env or secret changed in the catalog never reached the stack,
# and a disabled app kept running unguarded.
{
  config,
  lib,
  pkgs,
  inventory,
  site,
  nasMount,
  retry,
  catalog,
  lab,
  upstream,
  ...
}:
let

  swarmPorts = catalog.swarm.ports;
  telemetry = import ../telemetry.nix { inherit lib inventory; };
  inherit (import ../net.nix { inherit lib inventory site; }) localRanges;
  cidr = import ../cidr.nix { inherit lib; };

  # docker's default overlay pool 10.0.0.0/8 holds every lab subnet; this one overlaps none (asserted below)
  overlayPool = "10.240.0.0/16";
  overlayMask = 24;
  # an app's stack as the builder sends it; render refuses more (lib/swarm-render.py reads the bound from json)
  stackBytesMax = 1024 * 1024;
  # a stack deploy waits for every service to converge; a task that can never start must not hold the slot forever
  deployTimeoutS = 20 * 60;
  # more copies of one service than this per worker only crowd out the other apps
  replicasPerWorkerMax = 2;
  # a stack's services: each is a task at least, a container and a scrape series set on some worker
  servicesMax = 32;
  # per-worker allocatable the swarm schedules against (memory in MiB, cpu in millicores), reserved per task
  genericResources = {
    memory = "HOMELAB_MEMORY_MIB";
    cpu = "HOMELAB_CPU_MILLIS";
  };
  # each service's own replicas, which an asleep app's wake scales it back to (render sets it)
  replicasLabel = "homelab.replicas";
  # every app container lives here, capped below the node; the node's own services outweigh it on cpu
  appsSlice = "apps";
  appsSliceCpuWeight = 50;
  appsSliceTasksMax = 8192;
  # dockerd answering after boot; a booting worker reconnecting to its manager (pending) before anything is decided
  dockerWait = {
    attempts = 30;
    intervalS = 1;
  };
  settleWait = {
    attempts = 60;
    intervalS = 2;
  };
  ingressWait = {
    attempts = 30;
    intervalS = 1;
  };
  # the manager publishes the join token shortly after it initialised the swarm
  tokenWait = {
    attempts = 60;
    intervalS = 5;
  };
  # images of past deploys, by build time; volumes are never pruned
  imageKeepH = 72;
  # the manager's list of the images its services name, for its workers' prune (modules/tokens)
  imagesToken = "swarm-images";
  restartDelayS = {
    cluster = 15;
    reconcile = 10;
  };
  # a converge that failed for anything but a policy refusal (an outage, workers still booting) marks its app here;
  # swarm-converge-retry runs it again this often
  convergePendingDir = "/run/swarm-converge-pending";
  convergeRetry = "15min";
  # swarm-deploy's answer to a stack its policy refuses or an app not in the catalog: nothing to retry until either changes
  deployRefused = 2;

  tokens = config.homelab.tokens.dir;
  inherit (config.homelab) textfileDir;
  # the unlock key on a nas share only the manager mounts: off the disk whose raft it opens
  managerShare = "/var/lib/swarm-manager-nas";
  unlockKey = "${managerShare}/unlock-key";
  # what the builder last sent per app, which converge renders again
  stackDir = "/var/lib/swarm-apply";
  # the pull credential's docker config: root's alone, sent to the workers with each deploy (--with-registry-auth)
  dockerConfigDir = "${stackDir}/docker";
  loginTimeoutS = 60;
  # the swarm's one rollout slot, and per app the lock over its marker and its kept stack
  deployLock = "/run/swarm-deploy.lock";
  appLockDir = "/run/swarm-app";
  # each enabled app's catalog entry for render, at a path that stays put when another app's entry changes
  appCatalogDir = "swarm-apps";
  controllerState = "/run/controller-api";
  # the builder's last outcome per app (<app>.json), which the controller's /deploy answers from
  deployStatusDir = "/var/lib/app-deploy-status";
  # a request reads a few headers; a client that dribbles them holds a process no longer than this
  controllerRequestMaxS = 10;
  # the boards apps ship, which vm-103 provisions (instances/core/107-internal-swarm/lib/dashboards-import.py)
  appDashboardsMount = "/var/lib/app-dashboards";
  # a woken app's task starts within a deploy's image pull; the dump waits that long, then fails and alerts
  dumpWakeWait = {
    attempts = 60;
    intervalS = 5;
  };
  # db-backup's own dump directory (modules/db-backup), where the volume archives land
  dbBackupDir = "/var/backup/db";
  # a volume's archive is written here while its containers are paused, then streamed to the nas unpaused
  archiveDir = "/var/lib/swarm-archive";
  # an idle-stopped app's marker: deploys keep it at 0 replicas, the controller answers its state from here
  stoppedDir = "/var/lib/swarm-idle";
  # beside the marker, its mtime the app's last wake: the controller's /uptime, which the reaper's idle check reads
  wokeSuffix = ".woke";
  inherit (catalog.swarm) controllerPort;
  controllerUser = "controller";
  # one redeploy per app per minute: a ci retry loop costs one build
  redeployIntervalS = 60;
  units = {
    redeploy = "app-builder@%s.service";
    wake = "swarm-idle-wake@%s.service";
    sleep = "swarm-idle-sleep@%s.service";
  };
  deployUnit = "swarm-deploy@";
  appNamePattern = "^[a-z][a-z0-9-]*$";

  ownId = config.homelab.vmid;
  own = lib.findFirst (c: ownId == c.managerId || lib.elem ownId c.workerIds) null (lib.attrValues catalog.clusters);
  inherit (own)
    apps
    managerId
    stateId
    workerIds
    wakers
    admission
    ;
  manager = inventory.${managerId};
  self = inventory.${ownId};
  isManager = own != null && ownId == managerId;
  isWorker = own != null && lib.elem ownId workerIds;
  # a swarm of one: its manager runs the app, there is no worker to join, no node to reconcile
  single = workerIds == [ managerId ];
  # the deploy controller builds every app and takes their redeploys; its own swarm gets stacks from its inbox
  builderId = lab.roles.app-builder;
  isController = ownId == builderId;
  nodeName = id: "vm-${id}";
  convergeUnitOf = app: "swarm-converge-${app}";
  docker = config.virtualisation.docker.package;

  # the one user the registry's read route admits and its write route does not (106's instance.nix)
  pullUsers = removeAttrs catalog.internal.registry-api.basicAuth (
    lib.attrNames catalog.internal.registry-push.basicAuth
  );
  pullUser =
    assert lib.length (lib.attrNames pullUsers) == 1;
    lib.head (lib.attrNames pullUsers);
  pullSecret = pullUsers.${pullUser};

  # what swarm-render.py needs of one app; secrets stay {{name}} here, sops renders them into the app's env file
  transportOf = {
    http = "tcp";
    tcp = "tcp";
    udp = "udp";
  };
  appSpecOf = name: a: {
    inherit (a)
      exclude
      stateful
      override
      images
      ;
    # the upstreams the workers pull the catalog's public images from (swarm-deploy outage_exit)
    upstreams = lib.unique (lib.filter (name: name != null) (map upstream.ofImage a.images));
    published = lib.unique (
      map (r: {
        inherit (r) service targetPort port;
        protocol = transportOf.${r.protocol};
      }) (lib.attrValues a.routes)
      ++ map (m: {
        inherit (m) service targetPort port;
        protocol = "tcp";
      }) (lib.attrValues a.metrics)
    );
    resources = lib.mapAttrs (service: _: admission.taskOf name service) a.resources;
    reservation = admission.reservationOf name;
    volumes = lib.mapAttrs (_: v: { inherit (v) backup; }) a.volumes;
    secretFiles = lib.mapAttrs (
      service: lib.mapAttrs (key: _: config.sops.templates.${secretFileTemplate name service key}.path)
    ) a.secretFiles;
    # a value naming a secret set by hand (secrets-sync adds it empty)
    envRequired = lib.concatLists (
      lib.mapAttrsToList (
        service: env:
        map (key: { inherit service key; }) (
          lib.attrNames (
            lib.filterAttrs (_: value: lib.any (s: lib.hasSuffix "manual" a.secrets.${s}) (catalog.secretRefs value)) env
          )
        )
      ) a.env
    );
  };
  appCatalogFile =
    name:
    pkgs.writeText "swarm-app-${name}.json" (
      builtins.toJSON {
        inherit (catalog) registry;
        inherit
          stackBytesMax
          servicesMax
          genericResources
          replicasLabel
          ;
        inherit (admission) taskDefaults;
        # one slot free across the workers, so a start-first update always finds room for its new task
        replicasMax = replicasPerWorkerMax * lib.length workerIds - 1;
        replicasPerNodeMax = replicasPerWorkerMax;
        apps.${name} = appSpecOf name apps.${name};
      }
    );

  appSecrets =
    a:
    lib.unique (
      lib.concatMap catalog.secretRefs (lib.concatMap lib.attrValues (lib.attrValues a.env)) ++ catalog.secretFileRefs a
    );
  secretFileTemplate =
    app: service: key:
    "swarm-app-${app}-${service}-${key}";
  withPlaceholders =
    value:
    builtins.replaceStrings (map (n: "{{${n}}}") (catalog.secretRefs value)) (map (n: config.sops.placeholder.${n}) (
      catalog.secretRefs value
    )) value;
  # one line per value, <service>.<KEY>=<value> (swarm-render.py env_file_parse); generated secrets hold no newline
  envFileOf =
    a:
    lib.concatStrings (
      lib.concatLists (
        lib.mapAttrsToList (
          service: env: lib.mapAttrsToList (key: value: "${service}.${key}=${withPlaceholders value}\n") env
        ) a.env
      )
    );
  envDir = "/run/secrets/rendered";

  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  render = "${python}/bin/python3 ${./lib/swarm-render.py}";

  appLock = ''
    exec 8>"${appLockDir}/$app.lock"
    flock 8
  '';
  # every service of the stack $app to `replicas`: 0, or a command printing $service's own
  servicesScale = replicas: ''
    for service in $(docker stack services -q "$app"); do
      docker service scale --detach "$service=${replicas}" >/dev/null
    done
  '';

  # the digests of every image a service of the swarm names: what a worker's image prune keeps (header)
  imagesList = "docker service ls -q | xargs -r docker service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' | sed -n 's/.*@//p' | sort -u";
  # the shared manager's list for its workers (a swarm of one reads its own), after every change of a stack; a nas
  # outage leaves the last one
  imagesPublish = ''
    images_publish() {
      own=${config.homelab.tokens.ownDir}
      if ! { ${imagesList} > "$own/${imagesToken}.tmp" && mv "$own/${imagesToken}.tmp" "$own/${imagesToken}.token"; }; then
        echo "the image list could not be published: the workers prune against the last one" >&2
      fi
    }
  '';

  # swarm-deploy <app> <stack file>: render, deploy, check, keep; the one way a stack reaches the swarm
  swarmDeploy = pkgs.writeShellApplication {
    name = "swarm-deploy";
    runtimeInputs = [
      docker
      pkgs.coreutils
      pkgs.jq
      pkgs.util-linux
      pkgs.gnugrep
      pkgs.findutils
      pkgs.gnused
    ];
    text = ''
      app=$1 input=$2
      refused=${toString deployRefused}
      # the name becomes a path and a stack name
      [[ "$app" =~ ${appNamePattern} ]] || { echo "swarm-deploy: '$app' is no app name" >&2; exit "$refused"; }
      catalog=/etc/${appCatalogDir}/"$app".json
      metrics=${textfileDir}/swarm_app_$app.prom
      # to the caller (the builder's journal) and to this manager's own, tagged swarm-deploy
      say() { echo "swarm-deploy: $*"; logger -t swarm-deploy -- "$*"; }
      report() {
        printf '# TYPE homelab_swarm_deploy_ok gauge\nhomelab_swarm_deploy_ok{app="%s"} %s\n# TYPE homelab_swarm_deploy_timestamp_seconds gauge\nhomelab_swarm_deploy_timestamp_seconds{app="%s"} %s\n' \
          "$app" "$1" "$app" "$(date +%s)" > "$metrics.tmp"
        mv "$metrics.tmp" "$metrics"
      }
      unavailable=${toString upstream.unavailable}
      outage_exit() {
        for upstream in $(jq -r --arg app "$app" '.apps[$app].upstreams[]' "$catalog"); do
          if ! ${upstream.run} "$upstream"; then
            say "$upstream unavailable: $app keeps its running version" >&2
            exit "$unavailable"
          fi
        done
      }
      asleep_keep() {
        [ -e ${stoppedDir}/"$app" ] || return 0
        ${servicesScale "0"}
      }
      ${lib.optionalString (!single) imagesPublish}
      [ -f "$catalog" ] || { say "$app is not an enabled app" >&2; exit "$refused"; }
      ${appLock}
      exec 9>${deployLock}
      flock 9
      work=$(umask 077; mktemp -d /run/swarm-deploy.XXXXXX)
      trap 'rm -rf "$work"' EXIT
      # converge passes the kept stack itself, which the last step replaces
      cp "$input" "$work/input.yaml"
      # a sleeping app is deployed awake (header) and goes back to sleep however the deploy ends
      trap 'asleep_keep; ${lib.optionalString (!single) "images_publish; "}rm -rf "$work"' EXIT
      if ! ${render} "$app" "$catalog" ${envDir}/swarm-app-"$app".env < "$work/input.yaml" > "$work/stack.yaml"; then
        # a policy refusal: render said why, nothing changed on the swarm
        report 0
        exit "$refused"
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
          '[.apps[$app].published[] | select(.service == $service) | "\(.port):\(.targetPort)/\(.protocol)"] | sort | join(" ")' "$catalog")
        running=$(docker service inspect --format '{{json .Endpoint.Spec.Ports}}' "$service" \
          | jq -r '[.[]? | "\(.PublishedPort):\(.TargetPort)/\(.Protocol)"] | sort | join(" ")')
        if [ "$wanted" != "$running" ]; then
          say "replacing $service: its published ports change from '$running' to '$wanted'"
          docker service rm "$service" >/dev/null
        fi
      done
      # only while a node takes tasks: a task forced while none does is just as stuck (the converge retries later)
      if docker node ls --format '{{.Status}} {{.Availability}}' | grep -qx 'Ready Active'; then
        for service in $(docker stack services --format '{{.Name}}' "$app"); do
          if docker service ps --filter desired-state=running --format '{{.CurrentState}}' "$service" | grep -q '^Pending'; then
            say "rescheduling $service: a task of it is stuck pending"
            docker service update --detach --force "$service" >/dev/null
          fi
        done
      fi
      started=$(date +%s)
      # the swarm rolls a service back when its new tasks fail their healthchecks (update_config failure_action)
      if ! timeout ${toString deployTimeoutS} docker stack deploy --detach=false --prune --resolve-image always \
          --with-registry-auth -c "$work/stack.yaml" "$app"; then
        outage_exit
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
        outage_exit
        report 0
        say "$app rolled back:$rolled_back; the previous version keeps running" >&2
        exit 1
      fi
      # a secret a service still mounts refuses removal: the rest are the values this deploy replaced
      docker secret ls -q --filter label=com.docker.stack.namespace="$app" | xargs -r -n1 docker secret rm >/dev/null 2>&1 || true
      install -D -m 0600 "$work/input.yaml" ${stackDir}/"$app".yaml
      report 1
      say "$app deployed"
    '';
  };

  # the builder's stack on stdin: from its inbox, over the forced command (`ssh root@<manager> <app>`), or by hand
  swarmApply = pkgs.writeShellApplication {
    name = "swarm-apply";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      app=''${1:-''${SSH_ORIGINAL_COMMAND:-}}
      [ -n "$app" ] || { echo "usage: swarm-apply <app> < stack.yaml" >&2; exit 2; }
      work=$(umask 077; mktemp -d /run/swarm-apply.XXXXXX)
      trap 'rm -rf "$work"' EXIT
      # one byte over the bound, so render can refuse an oversized stack by name
      head -c ${toString (stackBytesMax + 1)} > "$work/stack.yaml"
      ${lib.getExe swarmDeploy} "$app" "$work/stack.yaml"
    '';
  };

  swarmConverge = pkgs.writeShellApplication {
    name = "swarm-converge";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      app=$1
      if [ -f ${stackDir}/"$app".yaml ]; then
        status=0
        ${lib.getExe swarmDeploy} "$app" ${stackDir}/"$app".yaml || status=$?
        case "$status" in
          0|${toString deployRefused}) rm -f ${convergePendingDir}/"$app" ;;
          *) touch ${convergePendingDir}/"$app" ;;
        esac
        exit "$status"
      fi
      echo "swarm-converge: $app has no stack yet; the builder deploys its first commit"
    '';
  };

  swarmPrune = pkgs.writeShellApplication {
    name = "swarm-prune";
    runtimeInputs = [
      docker
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnused
    ];
    text = ''
      ${lib.optionalString (!single) imagesPublish}
      enabled=" ${lib.concatStringsSep " " (lib.attrNames apps)} "
      for stack in $(docker stack ls --format '{{.Name}}'); do
        case "$enabled" in *" $stack "*) continue ;; esac
        # volumes stay on the state worker: data is removed by hand, never by a catalog edit
        echo "swarm-prune: removing $stack, it is not an enabled app"
        docker stack rm "$stack"
        rm -f ${stackDir}/"$stack".yaml ${textfileDir}/swarm_app_"$stack".prom ${textfileDir}/swarm_idle_"$stack".prom ${stoppedDir}/"$stack" ${stoppedDir}/"$stack"${wokeSuffix}
        rm -rf "${appDashboardsMount}/${telemetry.appDashboardsDir}/$stack"
      done
      ${lib.optionalString (!single) "images_publish"}
    '';
  };

  # the images no container uses and no service of the swarm names, built over imageKeepH ago; without the list
  # (the manager's token unreadable) it prunes nothing
  imagePrune = pkgs.writeShellApplication {
    name = "swarm-image-prune";
    runtimeInputs = [
      docker
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnused
      pkgs.gnugrep
    ];
    text = ''
      keep=$(mktemp)
      trap 'rm -f "$keep"' EXIT
      ${if isManager then "${imagesList} > \"$keep\"" else "cp ${tokens}/${imagesToken}.token \"$keep\""}
      cutoff=$(date -d "-${toString imageKeepH} hours" +%s)
      used=" $(docker ps -aq | xargs -r docker inspect --format '{{.Image}}' | tr '\n' ' ') "
      for image in $(docker image ls -q --no-trunc | sort -u); do
        case "$used" in *" $image "*) continue ;; esac
        digests=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" | sed -n 's/.*@//p')
        if [ -n "$digests" ] && grep -qxFf "$keep" <<< "$digests"; then continue; fi
        [ "$(date -d "$(docker image inspect --format '{{.Created}}' "$image")" +%s)" -lt "$cutoff" ] || continue
        # every name of the image goes with it; a container's image was skipped above
        docker image rm --force "$image" >/dev/null
      done
    '';
  };

  idleApps = lib.attrNames (lib.filterAttrs (_: a: a.idle.stopAfter != null) apps);
  # swarm-idle-sleep / swarm-idle-wake <app>: the marker /state reads, each service's scale, the gauge
  idleScript =
    name: state: scale:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        docker
        pkgs.coreutils
        pkgs.util-linux
      ];
      text = ''
        app=$1
        idle=" ${lib.concatStringsSep " " idleApps} "
        case "$idle" in *" $app "*) ;; *) echo "$app never idles" >&2; exit 2 ;; esac
        ${appLock}
        ${
          if state == 1 then
            ''touch ${stoppedDir}/"$app"''
          else
            ''rm -f ${stoppedDir}/"$app"; touch ${stoppedDir}/"$app"${wokeSuffix}''
        }
        ${servicesScale scale}
        printf '# TYPE homelab_app_idle_stopped gauge\nhomelab_app_idle_stopped{app="%s"} ${toString state}\n' "$app" > ${textfileDir}/swarm_idle_"$app".prom.tmp
        mv ${textfileDir}/swarm_idle_"$app".prom.tmp ${textfileDir}/swarm_idle_"$app".prom
      '';
    };
  idleSleep = idleScript "swarm-idle-sleep" 1 "0";
  idleWake =
    idleScript "swarm-idle-wake" 0
      ''$(docker service inspect --format '{{index .Spec.Labels "${replicasLabel}"}}' "$service")'';

  controllerConfig = pkgs.writeText "controller-api.json" (
    builtins.toJSON {
      apps = lib.mapAttrs (name: a: {
        tokenFile = if isController then config.sops.secrets."app-${name}-redeploy-token".path else null;
        idle = a.idle.stopAfter != null;
      }) (if isController then catalog.apps else apps);
      wakers = map (id: inventory.${id}.ip) wakers;
      inherit
        redeployIntervalS
        units
        stoppedDir
        wokeSuffix
        deployStatusDir
        ;
      stateDir = controllerState;
    }
  );

  addrs = ip: "--advertise-addr ${ip} --listen-addr ${ip}:${toString swarmPorts.manager} --data-path-addr ${ip}";
  waitForDocker = "${retry} ${toString dockerWait.attempts} ${toString dockerWait.intervalS} docker info";

  managerScript = pkgs.writeShellApplication {
    name = "swarm-manager";
    runtimeInputs = [
      docker
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
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
      # the routing mesh carries every app's published ports between nodes: encrypted like the apps' own overlays.
      # docker creates it plain and replaces it only while no service publishes a port; a deploy (swarm-deploy's
      # lock) waits, or its services would publish onto no ingress at all
      exec 9>${deployLock}
      flock 9
      if [ "$(docker network inspect ingress --format '{{index .Options "encrypted"}}' 2>/dev/null)" != true ]; then
        if ! docker network inspect ingress >/dev/null 2>&1 || printf 'y\n' | docker network rm ingress >/dev/null; then
          # the removal finishes in the background
          ${retry} ${toString ingressWait.attempts} ${toString ingressWait.intervalS} \
            docker network create --driver overlay --ingress --opt encrypted=true ingress >/dev/null
          echo "the routing mesh's ingress network is encrypted now"
        else
          echo "swarm-manager: the ingress network is plain and in use: remove the stacks once, then restart swarm-cluster" >&2
        fi
      fi
      flock -u 9
      umask 077
      docker swarm unlock-key -q > ${unlockKey}.tmp && mv ${unlockKey}.tmp ${unlockKey}
      ${
        if single then
          ''
            # the guest is its own state worker
            docker node update --label-add homelab.state=true ${nodeName managerId} >/dev/null
          ''
        else
          ''
            own=${config.homelab.tokens.ownDir}
            docker swarm join-token -q worker > "$own/swarm-worker-token.tmp" && mv "$own/swarm-worker-token.tmp" "$own/swarm-worker-token.token"
            # the manager schedules, it never runs an app
            docker node update --availability drain ${nodeName managerId} >/dev/null
          ''
      }
    '';
  };

  # the cluster's shape follows the inventory: on start and on every node event, never on a timer
  reconcileScript = pkgs.writeShellApplication {
    name = "swarm-reconcile";
    runtimeInputs = [
      docker
      pkgs.coreutils
      pkgs.gnugrep
    ];
    # one node's failed removal must not stop the watch; each step logs its own failure
    bashOptions = [
      "nounset"
      "pipefail"
    ];
    text = ''
      # hostname -> its inventory address; a node is the inventory's only from there
      declare -A address
      ${lib.concatMapStrings (id: "address[${nodeName id}]=${inventory.${id}.ip}\n") workerIds}
      reconcile() {
        docker node ls --format '{{.ID}}|{{.Hostname}}|{{.Status}}|{{.ManagerStatus}}' | while IFS='|' read -r id host status role; do
          # a node still joining has no hostname yet: never mistake it for one that left
          if [ -z "$host" ] || [ "$status" = Unknown ]; then continue; fi
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
      docker events --filter type=node --format '{{.Action}} {{.Actor.Attributes.name}}' | while read -r action name; do
        # the manager's own description moves with its balloon, an update every 20 s that changes no membership
        [ "$name" = ${nodeName managerId} ] && continue
        echo "node event: $action $name"
        reconcile
      done
    '';
  };

  workerScript = pkgs.writeShellApplication {
    name = "swarm-worker";
    runtimeInputs = [
      docker
      pkgs.coreutils
    ];
    text = ''
      ${waitForDocker}
      # pending: its manager boots later; leaving would throw away a good membership, so pending fails below
      for _ in $(seq ${toString settleWait.attempts}); do
        state=$(docker info --format '{{.Swarm.LocalNodeState}}')
        [ "$state" = pending ] || break
        sleep ${toString settleWait.intervalS}
      done
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
  };

  # DOCKER-USER: the internet only, replaced in one transaction
  dockerUserRules = pkgs.writeText "docker-user.rules" (
    lib.concatLines (
      [
        "*filter"
        ":DOCKER-USER - [0:0]"
        "-A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN"
      ]
      ++ map (range: "-A DOCKER-USER -i docker_gwbridge -d ${range} -j DROP") localRanges
      ++ [
        "-A DOCKER-USER -j RETURN"
        "COMMIT"
      ]
    )
  );

  # swarm-dump <app> <service> <idle> <command...>: in the service's container; an asleep app is woken for it, and the
  # wake's stamp keeps the reaper off it for its idle window
  volumeDump = pkgs.writeShellApplication {
    name = "swarm-dump";
    runtimeInputs = [
      docker
      pkgs.curl
      pkgs.coreutils
    ];
    text = ''
      app=$1 service="$1_$2" idle=$3
      shift 3
      task() { docker ps -q --filter label=com.docker.swarm.service.name="$service" | head -n1; }
      if [ -z "$(task)" ] && [ "$idle" = true ]; then
        curl -sf -m ${toString controllerRequestMaxS} -X POST http://${manager.ip}:${toString controllerPort}/wake/"$app" >/dev/null
        for _ in $(seq ${toString dumpWakeWait.attempts}); do
          [ -z "$(task)" ] || break
          sleep ${toString dumpWakeWait.intervalS}
        done
      fi
      [ -n "$(task)" ] || { echo "swarm-dump: $service runs no task" >&2; exit 1; }
      exec docker exec "$(task)" "$@"
    '';
  };

  # the state worker archives each volume an app marks for backup, its containers paused for a crash-consistent copy
  volumeArchive = pkgs.writeShellApplication {
    name = "swarm-volume-archive";
    runtimeInputs = [
      docker
      pkgs.gnutar
      pkgs.coreutils
    ];
    text = ''
      volume=$1
      dir=$(docker volume inspect --format '{{.Mountpoint}}' "$volume")
      archive=$(mktemp -p ${archiveDir} "$volume.XXXXXX")
      paused=()
      cleanup() {
        if [ ''${#paused[@]} -gt 0 ]; then docker unpause "''${paused[@]}" >/dev/null; fi
        rm -f "$archive"
      }
      trap cleanup EXIT
      mapfile -t paused < <(docker ps -q --filter volume="$volume")
      if [ ''${#paused[@]} -gt 0 ]; then docker pause "''${paused[@]}" >/dev/null; fi
      # paused for the local copy only; the slow write to the nas runs after they run again
      tar -C "$dir" -cf "$archive" .
      if [ ''${#paused[@]} -gt 0 ]; then docker unpause "''${paused[@]}" >/dev/null; fi
      paused=()
      cat "$archive"
    '';
  };

  # the way back: the newest (or the named) archive into its volume while nothing mounts it; a bad archive leaves
  # the volume as it was
  volumeRestore = pkgs.writeShellApplication {
    name = "swarm-volume-restore";
    runtimeInputs = [
      docker
      pkgs.gnutar
      pkgs.zstd
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      usage="usage: swarm-volume-restore <app> <volume> [<archive>]"
      app=''${1:?$usage} volume=''${2:?$usage}
      archive=''${3:-$(find ${dbBackupDir}/"$app"-volume-"$volume" -maxdepth 1 -name '*.tar*' | sort | tail -n1)}
      [ -f "$archive" ] || { echo "swarm-volume-restore: no archive of $app's volume $volume" >&2; exit 1; }
      # a running task would see its files change under it: scale it to 0 on the manager first
      if [ -n "$(docker ps -q --filter volume="$app"_"$volume")" ]; then
        echo "swarm-volume-restore: $app's volume $volume is in use; on vm-${managerId}: docker service scale <its service>=0" >&2
        exit 1
      fi
      dir=$(docker volume inspect --format '{{.Mountpoint}}' "$app"_"$volume")
      staged=$(mktemp -d "$(dirname "$dir")/restore.XXXXXX")
      trap 'rm -rf "$staged"' EXIT
      case "$archive" in
        *.zst)
          zstd -tq "$archive"
          zstd -dc "$archive" | tar -C "$staged" -xf - ;;
        *) tar -C "$staged" -xf "$archive" ;;
      esac
      # the old data goes only once the new is in place
      mv "$dir" "$staged.previous"
      mv "$staged" "$dir"
      rm -rf "$staged.previous"
      echo "swarm-volume-restore: $app's volume $volume restored from $archive"
    '';
  };

  dumpEntries = lib.concatLists (
    lib.mapAttrsToList (
      name: a:
      lib.mapAttrsToList (dump: d: {
        key = "${name}/${dump}";
        service = "${name}_${d.service}";
        inherit (d) restore;
      }) a.dumps
    ) apps
  );
  # the way back for a dump: the newest (or the named) one piped into its service's running task by the dump's
  # restore command; the app's other services are the operator's to stop first, on the manager
  dumpRestore = pkgs.writeShellApplication {
    name = "swarm-dump-restore";
    runtimeInputs = [
      docker
      pkgs.zstd
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      usage="usage: swarm-dump-restore <app> <dump> [<file>]"
      app=''${1:?$usage} dump=''${2:?$usage}
      declare -A services restores
      ${lib.concatMapStrings (
        d: "services[${d.key}]=${d.service} restores[${d.key}]=${lib.escapeShellArg d.restore}\n"
      ) dumpEntries}
      key="$app/$dump"
      [ -n "''${services[$key]:-}" ] || { echo "swarm-dump-restore: $app declares no dump $dump" >&2; exit 1; }
      service=''${services[$key]} restore=''${restores[$key]}
      file=''${3:-$(find ${dbBackupDir}/"$app-$dump" -maxdepth 1 -name "$app-$dump-*" | sort | tail -n1)}
      [ -f "$file" ] || { echo "swarm-dump-restore: no dump $dump of $app" >&2; exit 1; }
      task=$(docker ps -q --filter label=com.docker.swarm.service.name="$service" | head -n1)
      [ -n "$task" ] || { echo "swarm-dump-restore: $service runs no task here; wake or deploy $app first" >&2; exit 1; }
      case "$file" in
        *.zst) zstd -dc "$file" ;;
        *) cat "$file" ;;
      esac | docker exec -i "$task" sh -c "$restore"
      echo "swarm-dump-restore: $app's dump $dump restored from $file"
    '';
  };
in
{
  imports = [ ../app-telemetry.nix ];

  options.homelab.swarm = {
    deployKey = lib.mkOption {
      type = lib.types.str;
      default = lib.fileContents (lab.instances.${builderId}.dir + "/app-deploy-key.pub");
      defaultText = lib.literalExpression "the builder's instance folder, app-deploy-key.pub";
      description = ''
        The app builder's public key, which a guest swarm's manager accepts for its forced command swarm-apply; its
        private half is the builder's sops secret app-deploy-key. The restriction (source address, command, no
        forwarding) is the module's, whatever key is set.
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
        host that builds (instances/core/107-internal-swarm/lib/app-builder.nix), which may start that unit and nothing else of it.
      '';
    };
    deployUnit = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = deployUnit;
      description = "The unit template a local builder starts to deploy one app's stack from its inbox.";
    };
    deployStatusDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = deployStatusDir;
      description = "Where the builder records each app's last outcome (<app>.json), which the controller's /deploy answers from.";
    };
    appDashboardsDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${appDashboardsMount}/${telemetry.appDashboardsDir}";
      description = "Where the controller writes the boards apps ship (instances/core/107-internal-swarm/lib/dashboards-import.py), vm-103 reads them.";
    };
  };

  config = lib.mkIf (isManager || isWorker) (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = single || manager.type == "internal";
            message = "the shared swarm's manager must sit in the internal zone";
          }
          {
            assertion = workerIds != [ ];
            message = "the apps swarm has no worker: add an instance of type \"apps\"";
          }
          {
            assertion = lib.elem stateId workerIds;
            message = "src/instances/core/swarm.nix state (vm-${stateId}) is not a running apps worker";
          }
          {
            assertion =
              !(lib.any (z: cidr.overlaps overlayPool z.subnet) (lib.attrValues (lib.importJSON ../../generated/zones.json)));
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
          # a node running app tasks drops only dangling images here: swarm-image-prune keeps the ones a sleeping app wakes on
          autoPrune = {
            enable = true;
            dates = "daily";
            flags = lib.optionals (!isWorker) [
              "--all"
              "--filter"
              "until=${toString imageKeepH}h"
            ];
          };
        };

        systemd.services.swarm-cluster = {
          description = "Join, initialise or unlock the apps swarm";
          after = [
            "docker.service"
            "network-online.target"
          ];
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
            ExecStart = lib.getExe (if isManager then managerScript else workerScript);
          };
        };

        # published ports bypass INPUT through the routing mesh, on every node; the pre-dnat guard admits the grants
        # (modules/flows.nix guards) onto the guarded routes' and the exporters' ports
        homelab.ingressOnly = {
          trustContainers = false;
          ports = catalog.ports.guarded;
        };
      }

      (lib.mkIf isManager {
        # one per app, removed with its stack
        homelab.textfiles = [
          "swarm_app_*"
          "swarm_idle_*"
        ];
        homelab.nasMounts =
          nasMount managerShare (if single then "swarm-manager-${ownId}" else "swarm-manager")
          // lib.optionalAttrs isController (nasMount appDashboardsMount telemetry.appDashboardsShare);

        systemd.services = {
          swarm-reconcile = lib.mkIf (!single) {
            description = "Keep the apps swarm's nodes in line with the inventory";
            after = [ "swarm-cluster.service" ];
            requires = [ "swarm-cluster.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = lib.getExe reconcileScript;
              Restart = "always";
              RestartSec = restartDelayS.reconcile;
            };
          };

          swarm-prune = {
            description = "Remove the stacks of apps that left the catalog";
            after = [ "swarm-cluster.service" ];
            requires = [ "swarm-cluster.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.getExe swarmPrune;
            };
          };

          swarm-converge-retry = {
            description = "Apply the catalog again to the apps whose converge failed";
            serviceConfig.Type = "oneshot";
            script = ''
              for marker in ${convergePendingDir}/*; do
                [ -e "$marker" ] || continue
                app=$(basename "$marker")
                systemctl restart --no-block "${convergeUnitOf ""}$app.service"
              done
            '';
          };

          # the local builder's deploys, from its inbox
          "${deployUnit}" = lib.mkIf (config.homelab.swarm.deployInbox != null) {
            description = "Deploy the app %i from the builder's inbox";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${lib.getExe swarmApply} %i";
              StandardInput = "file:${config.homelab.swarm.deployInbox}/%i.yaml";
              TimeoutStartSec = deployTimeoutS;
              # the builder reads it from ExecMainStatus and retries on its next look
              SuccessExitStatus = [ upstream.unavailable ];
            };
          };

          # wake and sleep wait at most for a deploy of the same app
          "swarm-idle-sleep@" = {
            description = "Stop the idle app %i";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${lib.getExe idleSleep} %i";
              TimeoutStartSec = deployTimeoutS;
            };
          };
          "swarm-idle-wake@" = {
            description = "Wake the idle app %i";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${lib.getExe idleWake} %i";
              TimeoutStartSec = deployTimeoutS;
            };
          };

          # the controller's door: one short unprivileged process per connection, idle costs nothing
          "controller-api@" = {
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
        }
        // lib.mapAttrs' (
          name: _:
          lib.nameValuePair (convergeUnitOf name) {
            description = "Apply the catalog to the app ${name}";
            after = [ "swarm-cluster.service" ];
            requires = [ "swarm-cluster.service" ];
            wantedBy = [ "multi-user.target" ];
            # sops restarts it when one of the app's secrets changes
            restartTriggers = [ (appCatalogFile name) ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${lib.getExe swarmConverge} ${name}";
              # an upstream outage: swarm-converge-retry runs it again
              SuccessExitStatus = [ upstream.unavailable ];
              # every app's deploy may hold the rollout slot before this one's
              TimeoutStartSec = deployTimeoutS * (lib.length (lib.attrNames apps) + 1);
            };
          }
        ) apps;

        environment.etc = lib.mapAttrs' (
          name: _: lib.nameValuePair "${appCatalogDir}/${name}.json" { source = appCatalogFile name; }
        ) apps;

        systemd.tmpfiles.rules = [
          "d ${stackDir} 0700 root root -"
          "d ${dockerConfigDir} 0700 root root -"
          "d ${appLockDir} 0700 root root -"
          "d ${convergePendingDir} 0700 root root -"
          "d ${stoppedDir} 0755 root root -"
          "d ${controllerState} 0700 ${controllerUser} ${controllerUser} -"
        ];

        systemd.timers.swarm-converge-retry = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = convergeRetry;
            OnUnitInactiveSec = convergeRetry;
          };
        };

        users.users.${controllerUser} = {
          isSystemUser = true;
          group = controllerUser;
        };
        users.groups.${controllerUser} = { };
        systemd.sockets.controller-api = {
          wantedBy = [ "sockets.target" ];
          socketConfig = {
            ListenStream = controllerPort;
            Accept = true;
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
        homelab.openings.swarmManager = "the swarm controller, and a shared swarm's control, gossip and overlay ports";
        # the wakers' grant onto it is the cluster's (modules/flows.nix guards)
        networking.firewall.allowedTCPPorts = [ controllerPort ];
        homelab.ingressOnly.ports = [ controllerPort ];

        # workers reach the manager's control and gossip ports, and send their overlay traffic
        networking.firewall.extraCommands = lib.mkIf (!single) ''
          iptables -A nixos-fw -s ${catalog.appsZone} -p tcp -m multiport --dports ${toString swarmPorts.manager},${toString swarmPorts.gossip} -j nixos-fw-accept
          iptables -A nixos-fw -s ${catalog.appsZone} -p udp -m multiport --dports ${toString swarmPorts.gossip},${toString swarmPorts.vxlan} -j nixos-fw-accept
          iptables -A nixos-fw -s ${catalog.appsZone} -p esp -j nixos-fw-accept
        '';

        # a guest swarm takes the builder's stacks over its forced command: no shell, no forwarding
        users.users.root.openssh.authorizedKeys.keys = lib.mkIf (!isController) [
          ''restrict,from="${catalog.builder.ip}",command="${lib.getExe swarmApply}" ${config.homelab.swarm.deployKey}''
        ];
        environment.systemPackages = [ swarmApply ];

        # app secrets and the pull credential: a rotation redeploys the apps that read it
        sops.secrets =
          lib.genAttrs (lib.unique (lib.concatMap appSecrets (lib.attrValues apps))) (secret: {
            restartUnits = map (name: "${convergeUnitOf name}.service") (
              lib.filter (name: lib.elem secret (appSecrets apps.${name})) (lib.attrNames apps)
            );
          })
          // {
            ${pullSecret}.restartUnits = map (name: "${convergeUnitOf name}.service") (lib.attrNames apps);
          }
          // lib.optionalAttrs isController (
            lib.mapAttrs' (name: _: lib.nameValuePair "app-${name}-redeploy-token" { owner = controllerUser; }) catalog.apps
          );
        sops.templates =
          lib.mapAttrs' (
            name: a:
            lib.nameValuePair "swarm-app-${name}.env" {
              content = envFileOf a;
              restartUnits = [ "${convergeUnitOf name}.service" ];
            }
          ) apps
          // lib.concatMapAttrs (
            name: a:
            lib.concatMapAttrs (
              service:
              lib.mapAttrs' (
                key: secret:
                lib.nameValuePair (secretFileTemplate name service key) {
                  content = config.sops.placeholder.${secret};
                  restartUnits = [ "${convergeUnitOf name}.service" ];
                }
              )
            ) a.secretFiles
          ) apps;
      })

      (lib.mkIf isWorker {
        homelab.openings = lib.mkIf (!single) { swarmWorker = "a swarm worker's gossip and overlay ports"; };
        # gossip and overlay traffic from the other workers and the manager; esp carries the encrypted overlays
        networking.firewall.extraCommands =
          lib.optionalString (!single) ''
            for src in ${catalog.appsZone} ${manager.ip}; do
              iptables -A nixos-fw -s "$src" -p tcp --dport ${toString swarmPorts.gossip} -j nixos-fw-accept
              iptables -A nixos-fw -s "$src" -p udp -m multiport --dports ${toString swarmPorts.gossip},${toString swarmPorts.vxlan} -j nixos-fw-accept
              iptables -A nixos-fw -s "$src" -p esp -j nixos-fw-accept
            done
          ''
          + ''
            iptables-restore --noflush < ${dockerUserRules}
          '';

        homelab.appTelemetry.enable = true;

        # what the worker holds for apps: the scheduler places reservations against it, the slice caps the containers
        virtualisation.docker.daemon.settings = {
          cgroup-parent = "${appsSlice}.slice";
          node-generic-resources = [
            "${genericResources.memory}=${toString admission.workers.${ownId}.memoryMiB}"
            "${genericResources.cpu}=${toString admission.workers.${ownId}.cpuMillis}"
          ];
        };
        # a task over its memory limit is killed inside its own cgroup; the node never panics for it
        boot.kernel.sysctl."vm.panic_on_oom" = 0;
        systemd.slices.${appsSlice}.sliceConfig = {
          MemoryMax = "${toString admission.workers.${ownId}.memoryMiB}M";
          CPUWeight = appsSliceCpuWeight;
          TasksMax = appsSliceTasksMax;
        };

        # the state worker's nightly dumps (in the container that owns the database) and volume archives, to the nas
        homelab.dbBackup.databases = lib.mkIf (ownId == stateId) (
          lib.foldl' (
            acc: name:
            let
              a = apps.${name};
            in
            acc
            // lib.mapAttrs' (
              dump: d:
              lib.nameValuePair "${name}-${dump}" {
                command = "${lib.getExe volumeDump} ${name} ${d.service} ${lib.boolToString (a.idle.stopAfter != null)} ${d.command}";
              }
            ) a.dumps
            // lib.mapAttrs' (
              volume: _:
              lib.nameValuePair "${name}-volume-${volume}" {
                command = "${lib.getExe volumeArchive} ${name}_${volume}";
                suffix = "tar";
              }
            ) (lib.filterAttrs (_: v: v.backup) a.volumes)
          ) { } (lib.attrNames apps)
        );
        systemd.tmpfiles.rules = lib.optional (ownId == stateId) "d ${archiveDir} 0700 root root -";
        environment.systemPackages =
          lib.optional (ownId == stateId) volumeRestore ++ lib.optional (ownId == stateId && dumpEntries != [ ]) dumpRestore;

        systemd.services.swarm-image-prune = {
          description = "Remove the images no app of the swarm runs or wakes on";
          after = [ "docker.service" ];
          requires = [ "docker.service" ];
          unitConfig.RequiresMountsFor = config.homelab.tokens.mountPoints;
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe imagePrune;
          };
        };
        systemd.timers.swarm-image-prune = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "daily";
            Persistent = true;
          };
        };
      })
    ]
  );
}
