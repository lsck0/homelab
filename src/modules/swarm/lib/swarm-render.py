"""Turn an app's stack, as the builder sent it, into the stack the swarm runs, or refuse it.

Usage: swarm-render.py <app> <catalog.json> <env-file> [stopped] < stack.yaml > rendered.yaml
       stopped: the app is idle-stopped (modules/swarm swarm-idle); every service is rendered at 0 replicas,
                admitted at its own, so a deploy updates a sleeping app without waking it

The builder (instances/140-internal-swarm/lib/app-builder.nix) sends the app's own compose file with every built image pinned by digest
and every env_file already inlined. This adds the homelab and enforces its policy (modules/swarm runs it):

- services the catalog `exclude`s are dropped, with every depends_on pointing at them; the catalog `override`
  is merged next, then each service's catalog `env` (secrets resolved by sops) over that service's environment
- ports are the homelab's: the app's own are dropped, the catalog's `published` (routes and exporters) are published
  with their transport (tcp, or udp for a udp route)
- limits are the homelab's: the catalog `resources` of a service, else the catalog's task defaults; memory is
  reserved at its limit, cpu at `cpusReserved`, both also as the generic resources each worker advertises for apps
  (modules/swarm), so swarm never places more on a worker than it holds beside its own services
- the app's tasks (each service's task times its replicas) fit the app's catalog `reservation`; replicas of a
  stateless service spread over the workers, at most `replicasPerNodeMax` on one; each service carries its
  replicas as the label `replicasLabel`, which an idle app's wake scales it back to
- every overlay network is encrypted (ipsec between nodes); stateful services are pinned to the state node, one
  task, stopped before replaced and before rolled back; a failed update rolls back
- every named volume belongs to a stateful service and is declared in the catalog `volumes` (backed up or not)
- logging stays on the daemon's driver (modules/app-telemetry.nix), so every line reaches loki with its task name
- every capability is dropped; a service gets back only what it names in cap_add from CAPS_ALLOWED
- allowed: the keys listed below, nothing else. Refused: privileged settings, host namespaces, devices, host
  paths, the docker socket, an image that is not this app's own digest-pinned build or a digest-pinned catalog
  `images` entry, compose interpolation, and any CHANGE_ME left

Dollars: the stack is compose source, where `$$` is a literal `$` and `${VAR}` an interpolation the homelab does
not offer (env_file values the builder inlined arrive escaped). Render unescapes, refuses interpolation, and
escapes every string of its output, so `docker stack deploy` on the manager interpolates nothing.

A refusal names the service and the field and exits 2; nothing is deployed.

Rejected: a deny-list of service keys. Every key a newer compose schema adds passed by default (oom_score_adj),
and app-set limits overrode the defaults; the allow-lists below make a new key a deliberate change here.
"""
import json
import sys

import yaml

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------

STATE_CONSTRAINT = "node.labels.homelab.state == true"
# the homelab's own placement labels: an app constraint naming them could reach another app's state volumes
HOMELAB_LABEL_PREFIX = "homelab."
# placeholders an app ships for the operator to replace; deploying one is deploying a known password
PLACEHOLDERS = ("CHANGE_ME",)
ENV_FILE_SEPARATOR = "="
# <service>.<KEY>: an env key never holds a dot, a service name may
ENV_FILE_SERVICE_SEPARATOR = "."

STACK_KEYS = {"version", "services", "networks", "volumes"}
# compose extension fields (x-common: &anchor), resolved by the yaml loader already
STACK_EXTENSION_PREFIX = "x-"
SERVICE_KEYS = {
    "image", "command", "entrypoint", "environment", "working_dir", "user", "healthcheck", "deploy", "depends_on",
    "volumes", "networks", "stop_grace_period", "stop_signal", "labels", "hostname", "tty", "stdin_open",
    "read_only", "init", "cap_drop", "cap_add",
    # dropped: the homelab sets ports and logging, the builder inlined env_file, swarm ignores the rest
    "ports", "logging", "env_file", "container_name", "restart", "expose",
}
SERVICE_KEYS_DROPPED = {"ports", "logging", "env_file", "container_name", "restart", "expose"}
DEPLOY_KEYS = {"mode", "replicas", "placement", "resources", "restart_policy", "update_config", "rollback_config",
               "labels", "endpoint_mode"}
PLACEMENT_KEYS = {"constraints", "preferences", "max_replicas_per_node"}
UPDATE_KEYS = {"parallelism", "delay", "failure_action", "monitor", "max_failure_ratio", "order"}
RESTART_KEYS = {"condition", "delay", "max_attempts", "window"}
SERVICE_NETWORK_KEYS = {"aliases"}
NETWORK_KEYS = {"driver", "driver_opts", "attachable", "internal", "labels"}
NETWORK_DRIVER_OPTS = {"encrypted"}
VOLUME_KEYS = {"labels"}
VOLUME_MOUNT_KEYS = {"type", "source", "target", "read_only", "volume", "tmpfs"}
VOLUME_MOUNT_TYPES = {"volume", "tmpfs"}
VOLUME_MODES = {"ro", "rw", "nocopy", "ro,nocopy", "rw,nocopy"}
# docker's default set without NET_RAW (forged packets on the overlay), MKNOD, AUDIT_WRITE, SETFCAP, SETPCAP and
# SYS_CHROOT: what an entrypoint that chowns its data and drops to its user (postgres, redis, nginx) needs
CAPS_ALLOWED = {"CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "SETGID", "SETUID", "NET_BIND_SERVICE"}
CAPS_DROPPED = ["ALL"]
STOPPED_ARGUMENT = "stopped"
MEBIBYTE_SUFFIX = "M"
MILLIS_PER_CPU = 1000


# -----------------------------------------------------------------------------
# INTERNAL
# -----------------------------------------------------------------------------

def refuse(where, why):
    print(f"swarm-render: refused: {where}: {why}", file=sys.stderr)
    sys.exit(2)


def tree_copy(node):
    """A copy sharing nothing: a yaml alias (`deploy: *dep`) loads as one object under several services."""
    if isinstance(node, dict):
        return {k: tree_copy(v) for k, v in node.items()}
    if isinstance(node, list):
        return [tree_copy(v) for v in node]
    return node


def tree_map_strings(node, fn, where):
    if isinstance(node, dict):
        return {k: tree_map_strings(v, fn, f"{where}.{k}") for k, v in node.items()}
    if isinstance(node, list):
        return [tree_map_strings(v, fn, f"{where}[{i}]") for i, v in enumerate(node)]
    if isinstance(node, str):
        return fn(node, where)
    return node


def dict_merge_deep(base, over):
    """Dicts merge key by key, anything else is replaced, like a compose overlay."""
    if not isinstance(base, dict) or not isinstance(over, dict):
        return tree_copy(over)
    out = dict(base)
    for k, v in over.items():
        out[k] = dict_merge_deep(base.get(k), v)
    return out


def compose_unescape(value, where):
    """Compose source to the literal value: `$$` is `$`; any other `$` would interpolate and is refused."""
    out = []
    i = 0
    while i < len(value):
        if value[i] != "$":
            out.append(value[i])
            i += 1
        elif value[i + 1:i + 2] == "$":
            out.append("$")
            i += 2
        else:
            refuse(where, "compose interpolation ($VAR, ${VAR}) is not offered: write $$ for a literal $, "
                          "put the value in the catalog env")
    return "".join(out)


def compose_escape(value, where):
    """A literal value as compose source, so `docker stack deploy` hands it to the container unchanged."""
    del where
    return value.replace("$", "$$")


def keys_check(where, mapping, allowed):
    if mapping is None:
        return {}
    if not isinstance(mapping, dict):
        refuse(where, "not a mapping")
    for key in mapping:
        if key not in allowed:
            refuse(f"{where}.{key}", "not allowed on the apps swarm")
    return mapping


def env_file_parse(path):
    """The sops-rendered catalog env: `<service>.<KEY>=<value>` per line -> {service: {KEY: value}}."""
    env = {}
    with open(path, encoding="utf-8") as f:
        for line in f.read().splitlines():
            if not line:
                continue
            target, sep, value = line.partition(ENV_FILE_SEPARATOR)
            service, dot, key = target.rpartition(ENV_FILE_SERVICE_SEPARATOR)
            if not sep or not dot or not service or not key:
                refuse(path, "a line that is not <service>.<KEY>=<value>")
            env.setdefault(service, {})[key] = value
    return env


def environment_to_dict(env, where):
    """A compose `environment` or `labels`, a map or a list of KEY=value, as a map of strings."""
    if env is None:
        return {}
    if isinstance(env, dict):
        return {str(k): "" if v is None else str(v) for k, v in env.items()}
    if isinstance(env, list):
        out = {}
        for item in env:
            key, _, value = str(item).partition("=")
            out[key] = value
        return out
    refuse(where, "neither a map nor a list")
    return {}


def image_check(name, image, app, allowed, registry):
    if image in allowed:
        return
    if image.startswith(f"{registry}/{app}/") and "@sha256:" in image:
        return
    refuse(f"{name}.image", f"{image} is neither this app's digest-pinned build nor a pinned catalog image")


def volume_source_of(name, vol):
    """The named volume a service mount uses, or None for a tmpfs; anything reaching the host is refused."""
    where = f"{name}.volumes"
    if isinstance(vol, dict):
        keys_check(where, vol, VOLUME_MOUNT_KEYS)
        kind = vol.get("type", "volume")
        if kind not in VOLUME_MOUNT_TYPES:
            refuse(where, f"type {kind}: only named volumes and tmpfs")
        if kind == "tmpfs":
            return None
        source = str(vol.get("source", ""))
    else:
        parts = str(vol).split(":")
        if len(parts) not in (2, 3) or (len(parts) == 3 and parts[2] not in VOLUME_MODES):
            refuse(where, f"{vol}: only <named volume>:<path>[:ro]")
        source = parts[0]
    if not source or source.startswith(("/", ".", "~")) or "docker.sock" in source:
        refuse(where, f"host path {source or '(anonymous)'}: only named volumes")
    return source


def service_networks_check(name, networks):
    if isinstance(networks, dict):
        for net, opts in networks.items():
            keys_check(f"{name}.networks.{net}", opts, SERVICE_NETWORK_KEYS)
    elif networks is not None and not isinstance(networks, list):
        refuse(f"{name}.networks", "neither a list nor a map")


def resources_render(task, generic):
    """Limits, and the same memory and the reserved cpu as reservations, natively and as the workers' generic resources."""
    memory = f"{task['memoryMiB']}{MEBIBYTE_SUFFIX}"
    return {
        "limits": {"memory": memory, "cpus": str(task["cpus"]), "pids": task["pids"]},
        "reservations": {
            "memory": memory,
            "cpus": str(task["cpuMillis"] / MILLIS_PER_CPU),
            "generic_resources": [
                {"discrete_resource_spec": {"kind": generic["memory"], "value": task["memoryMiB"]}},
                {"discrete_resource_spec": {"kind": generic["cpu"], "value": task["cpuMillis"]}},
            ],
        },
    }


def reservation_check(app, spec, services):
    """Every task of the stack, replicas counted, inside the app's reservation, or a refusal naming the numbers."""
    reservation = spec["reservation"]
    for key, unit, field in (("memoryMiB", "MiB", "memoryMiB"), ("cpuMillis", "millicores", "cpus")):
        needs = {n: s["deploy"]["replicas"] * spec["tasks"][n][key] for n, s in services.items()}
        if sum(needs.values()) > reservation[key]:
            parts = ", ".join(f"{n} {v}" for n, v in sorted(needs.items()))
            refuse("catalog", f"the stack's tasks need {sum(needs.values())} {unit} ({parts}), "
                              f"apps.{app}.reservation.{field} holds {reservation[key]} {unit}: raise it or lower "
                              f"apps.{app}.resources")


def deploy_render(name, svc, stateful, task, catalog):
    deploy = keys_check(f"{name}.deploy", svc.get("deploy"), DEPLOY_KEYS)
    if deploy.get("mode", "replicated") != "replicated":
        refuse(f"{name}.deploy.mode", "only replicated services: a global one runs on every worker")
    replicas = deploy.get("replicas", 1)
    if not isinstance(replicas, int) or isinstance(replicas, bool) or replicas < 0:
        refuse(f"{name}.deploy.replicas", f"{replicas!r} is no count")
    if replicas > catalog["replicasMax"]:
        refuse(f"{name}.deploy.replicas", f"more than {catalog['replicasMax']}, the catalog's bound for the workers")
    # explicit: the reservation check counts it
    deploy["replicas"] = replicas
    placement = keys_check(f"{name}.deploy.placement", deploy.get("placement"), PLACEMENT_KEYS)
    for constraint in placement.get("constraints") or []:
        # the state constraint the homelab adds itself is accepted again on the service it belongs to
        if HOMELAB_LABEL_PREFIX in str(constraint) and not (name in stateful and constraint == STATE_CONSTRAINT):
            refuse(f"{name}.deploy.placement", f"{constraint}: homelab labels place only stateful services")

    deploy["resources"] = resources_render(task, catalog["genericResources"])
    restart = keys_check(f"{name}.deploy.restart_policy", deploy.get("restart_policy"), RESTART_KEYS)
    restart["condition"] = "any"
    # a capped restart count gives up for good; swarm's backoff is enough
    restart.pop("max_attempts", None)
    deploy["restart_policy"] = restart
    update = keys_check(f"{name}.deploy.update_config", deploy.get("update_config"), UPDATE_KEYS)
    # a failed update is undone, and the builder hears of it (modules/swarm swarm-deploy)
    update["failure_action"] = "rollback"
    rollback = keys_check(f"{name}.deploy.rollback_config", deploy.get("rollback_config"), UPDATE_KEYS)
    if name in stateful:
        constraints = placement.setdefault("constraints", [])
        if STATE_CONSTRAINT not in constraints:
            constraints.append(STATE_CONSTRAINT)
        deploy["placement"] = placement
        # two copies on one volume corrupt it: the old task stops before the new one starts, either way
        update["order"] = "stop-first"
        rollback["order"] = "stop-first"
        deploy["mode"] = "replicated"
        deploy["replicas"] = 1
    else:
        update.setdefault("order", "start-first")
        # an app's own lower bound stands; the catalog's bound leaves a start-first update a free slot
        per_node = placement.get("max_replicas_per_node", catalog["replicasPerNodeMax"])
        if not isinstance(per_node, int) or isinstance(per_node, bool) or per_node < 1:
            refuse(f"{name}.deploy.placement.max_replicas_per_node", f"{per_node!r} is no count")
        placement["max_replicas_per_node"] = min(per_node, catalog["replicasPerNodeMax"])
        deploy["placement"] = placement
    deploy["update_config"] = update
    if rollback:
        deploy["rollback_config"] = rollback
    labels = environment_to_dict(deploy.get("labels"), f"{name}.deploy.labels")
    labels[catalog["replicasLabel"]] = str(deploy["replicas"])
    deploy["labels"] = labels
    return deploy


def service_render(app, name, svc, spec, catalog, env, published, declared_volumes):
    for key in svc:
        if key == "build":
            refuse(f"{name}.build", "the builder pins every build; an unbuilt service cannot run")
        if key not in SERVICE_KEYS:
            refuse(f"{name}.{key}", "not allowed on the apps swarm")
    image_check(name, str(svc.get("image", "")), app, set(spec["images"]), catalog["registry"])
    service_networks_check(name, svc.get("networks"))

    stateful = set(spec["stateful"])
    used = set()
    for vol in svc.get("volumes") or []:
        source = volume_source_of(name, vol)
        if source is None:
            continue
        if source not in declared_volumes:
            refuse(f"{name}.volumes", f"{source} is no top-level volume of the stack")
        if source not in spec["volumes"]:
            refuse(f"{name}.volumes", f"{source}: declare apps.{app}.volumes.{source}.backup in the catalog")
        if name not in stateful:
            refuse(f"{name}.volumes", f"{source} on a stateless service lives on whichever node runs it: list "
                                      f"{name} in apps.{app}.stateful")
        used.add(source)

    merged = environment_to_dict(svc.get("environment"), f"{name}.environment")
    merged.update(env.get(name, {}))
    if merged:
        svc["environment"] = merged
    for key in SERVICE_KEYS_DROPPED:
        svc.pop(key, None)
    caps = svc.get("cap_add") or []
    if not isinstance(caps, list) or not set(caps) <= CAPS_ALLOWED:
        refuse(f"{name}.cap_add", f"{caps!r}: only {sorted(CAPS_ALLOWED)}")
    svc["cap_drop"] = CAPS_DROPPED
    if caps:
        svc["cap_add"] = sorted(caps)
    svc["ports"] = [
        {"target": target, "published": port, "protocol": protocol, "mode": "ingress"}
        for target, port, protocol in sorted(published.get(name, ()))
    ]
    svc["deploy"] = deploy_render(name, svc, stateful, spec["tasks"][name], catalog)
    return used


def networks_render(networks):
    if not isinstance(networks, dict):
        refuse("networks", "not a mapping")
    networks.setdefault("default", {})
    for name, net in list(networks.items()):
        net = net or {}
        if net.get("external"):
            refuse(f"networks.{name}", "external networks reach outside the stack")
        if "name" in net:
            refuse(f"networks.{name}.name", "a literal name leaves the stack's namespace")
        if "ipam" in net:
            refuse(f"networks.{name}.ipam", "the subnet is the swarm's (its overlay pool), never a lab range")
        keys_check(f"networks.{name}", net, NETWORK_KEYS)
        keys_check(f"networks.{name}.driver_opts", net.get("driver_opts"), NETWORK_DRIVER_OPTS)
        net["driver"] = "overlay"
        net["driver_opts"] = {"encrypted": "true"}
        net["attachable"] = False
        networks[name] = net
    return networks


def volumes_render(volumes, used):
    """Only the volumes a kept service mounts, each a plain local volume in the stack's namespace."""
    out = {}
    for name, vol in (volumes or {}).items():
        vol = vol or {}
        if vol.get("external") or vol.get("driver_opts") or vol.get("driver"):
            refuse(f"volumes.{name}", "external volumes, drivers and driver options reach host paths")
        if "name" in vol:
            refuse(f"volumes.{name}.name", "a literal name could be another app's volume")
        keys_check(f"volumes.{name}", vol, VOLUME_KEYS)
        if name in used:
            out[name] = vol
    return out


# -----------------------------------------------------------------------------
# FUNCTIONS
# -----------------------------------------------------------------------------

def render(app, catalog, env, stack):
    """The stack the swarm runs, as yaml text; refuses (exit 2) with the field and the reason."""
    assert app in catalog["apps"], app
    spec = catalog["apps"][app]
    if not isinstance(stack, dict):
        refuse("stack", "not a mapping")
    stack = tree_copy(stack)
    for key in list(stack):
        if str(key).startswith(STACK_EXTENSION_PREFIX):
            del stack[key]
        elif key in ("configs", "secrets"):
            refuse(key, "top-level configs and secrets name files on the manager; use the catalog env")
        elif key not in STACK_KEYS:
            refuse(str(key), "not allowed on the apps swarm")
    stack = tree_map_strings(stack, compose_unescape, "stack")
    stack.pop("version", None)

    services = stack.get("services") or {}
    if not isinstance(services, dict):
        refuse("services", "not a mapping")
    excluded = set(spec["exclude"])
    for name in excluded:
        services.pop(name, None)
    for name in list(services):
        services[name] = services[name] or {}
        if not isinstance(services[name], dict):
            refuse(name, "a service is a mapping")
        deps = services[name].get("depends_on")
        if isinstance(deps, list):
            services[name]["depends_on"] = [d for d in deps if d not in excluded]
        elif isinstance(deps, dict):
            services[name]["depends_on"] = {d: v for d, v in deps.items() if d not in excluded}
    stack["services"] = services
    stack = dict_merge_deep(stack, spec["override"])
    services = stack.get("services") or {}
    if len(services) > catalog["servicesMax"]:
        refuse("services", f"{len(services)} services, more than the {catalog['servicesMax']} a stack may run")
    # each service's task: the catalog's resources of it, else the task defaults
    spec = dict(spec, tasks={n: spec["resources"].get(n, catalog["taskDefaults"]) for n in services})

    published = {}
    for entry in spec["published"]:
        published.setdefault(entry["service"], set()).add((entry["targetPort"], entry["port"], entry["protocol"]))
    for what, names in (("publishes", published), ("lists as stateful", spec["stateful"]),
                        ("sets env for", env), ("sets resources for", spec["resources"])):
        missing = set(names) - set(services)
        if missing:
            refuse("catalog", f"{what} services the stack lacks: {sorted(missing)}")

    declared_volumes = set((stack.get("volumes") or {}).keys())
    used = set()
    for name, svc in services.items():
        used |= service_render(app, name, svc, spec, catalog, env, published, declared_volumes)
    reservation_check(app, spec, services)

    stack["networks"] = networks_render(stack.get("networks") or {})
    volumes = volumes_render(stack.get("volumes"), used)
    if volumes:
        stack["volumes"] = volumes
    else:
        stack.pop("volumes", None)

    # every service the stack keeps is published exactly as the catalog says, and nothing else is
    assert {n for n, s in services.items() if s["ports"]} == set(published), (sorted(services), sorted(published))
    rendered = yaml.safe_dump(tree_map_strings(stack, compose_escape, "stack"), sort_keys=True)
    for placeholder in PLACEHOLDERS:
        if placeholder in rendered:
            refuse("stack", f"{placeholder} left in the rendered stack: set it in the catalog env")
    return rendered


def replicas_stop(rendered):
    """A rendered stack with every service at 0 replicas: deployed, it runs nothing until woken."""
    stack = yaml.safe_load(rendered)
    for svc in stack["services"].values():
        svc["deploy"]["replicas"] = 0
    return yaml.safe_dump(stack, sort_keys=True)


def main():
    if len(sys.argv) not in (4, 5) or sys.argv[4:] not in ([], [STOPPED_ARGUMENT]):
        print(f"usage: swarm-render.py <app> <catalog.json> <env-file> [{STOPPED_ARGUMENT}] < stack.yaml", file=sys.stderr)
        return 2
    app, catalog_path, env_path = sys.argv[1:4]
    with open(catalog_path, encoding="utf-8") as f:
        catalog = json.load(f)
    if app not in catalog["apps"]:
        refuse("app", f"{app} is not an enabled app")
    bytes_max = catalog["stackBytesMax"]
    raw = sys.stdin.buffer.read(bytes_max + 1)
    if len(raw) > bytes_max:
        refuse("stack", f"larger than {bytes_max} bytes")
    try:
        stack = yaml.safe_load(raw) or {}
    except yaml.YAMLError as e:
        refuse("stack", f"not yaml: {e}")
    rendered = render(app, catalog, env_file_parse(env_path), stack)
    sys.stdout.write(replicas_stop(rendered) if sys.argv[4:] == [STOPPED_ARGUMENT] else rendered)
    return 0


if __name__ == "__main__":
    sys.exit(main())
