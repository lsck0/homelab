"""Turn an app's stack, as the builder sent it, into the stack the swarm runs, or refuse it.

Usage: swarm-render.py <app> <catalog.json> <env-file> < stack.yaml > rendered.yaml

The builder (services/app-builder.nix) sends the app's own compose file with every built image pinned by
digest and every env_file already inlined. This adds the homelab and enforces its policy:

- services the catalog `exclude`s are dropped, with every depends_on pointing at them
- the catalog `override` is merged last, the catalog `env` (secrets resolved by sops) over every environment
- ports are the homelab's: the app's own are dropped, `paths`, `internal` and `metrics` are published
- every overlay network is encrypted (ipsec between nodes); stateful services are pinned to the state node
- logging stays on the daemon's journald driver, so every line reaches loki with its container name
- refused: privileged settings, host namespaces, devices, host paths, the docker socket, an image that is not
  this app's own digest-pinned build or a digest-pinned catalog `images` entry, and any CHANGE_ME left

A refusal names the service and the field and exits 2; nothing is deployed.
"""
import json
import sys

import yaml

REGISTRY = "registry.lsck0.dev"
STATE_CONSTRAINT = "node.labels.homelab.state == true"
# placeholders an app ships for the operator to replace; deploying one is deploying a known password
PLACEHOLDERS = ("CHANGE_ME",)
# keys that hand a container more than its own namespaces
FORBIDDEN_SERVICE_KEYS = (
    "privileged", "cap_add", "devices", "network_mode", "pid", "ipc", "userns_mode", "cgroup_parent",
    "security_opt", "sysctls", "extra_hosts", "volumes_from", "runtime", "isolation", "ulimits",
)
# top-level keys whose `file:` the manager's docker cli reads from its own disk
FORBIDDEN_STACK_KEYS = ("configs", "secrets")
# one task's share of a 2.5 GiB worker unless the catalog override grants more; pids bound a fork bomb
MEMORY_LIMIT_DEFAULT = "512M"
PIDS_LIMIT_DEFAULT = 512
# three workers; more copies of one service only crowd out the others
REPLICAS_MAX = 6
STACK_BYTES_MAX = 1024 * 1024


def refuse(where, why):
    print(f"swarm-render: refused: {where}: {why}", file=sys.stderr)
    sys.exit(2)


def deep_merge(base, over):
    """Dicts merge key by key, anything else is replaced, like a compose overlay."""
    if not isinstance(base, dict) or not isinstance(over, dict):
        return over
    out = dict(base)
    for k, v in over.items():
        out[k] = deep_merge(base.get(k), v)
    return out


def env_from_file(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            key, sep, value = line.partition("=")
            if not sep:
                refuse(path, "a line without '='")
            env[key] = value
    return env


def env_as_dict(env, where):
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
    refuse(where, "environment is neither a map nor a list")


def check_volumes(name, svc):
    for vol in svc.get("volumes") or []:
        if isinstance(vol, dict):
            if vol.get("type", "volume") != "volume":
                refuse(f"{name}.volumes", f"type {vol.get('type')}: only named volumes")
            source = str(vol.get("source", ""))
        else:
            source = str(vol).split(":", 1)[0]
        if source.startswith(("/", ".", "~")) or "docker.sock" in source:
            refuse(f"{name}.volumes", f"host path {source}: only named volumes")


def check_image(name, image, app, allowed):
    if image in allowed:
        return
    if image.startswith(f"{REGISTRY}/{app}/") and "@sha256:" in image:
        return
    refuse(f"{name}.image", f"{image} is neither this app's digest-pinned build nor a pinned catalog image")


def escape_interpolation(value):
    """`docker stack deploy` substitutes $VAR in the rendered file; a secret or app value holding a $ must stay literal."""
    return value.replace("$", "$$")


def render(app, spec, env, stack):
    for key in FORBIDDEN_STACK_KEYS:
        if stack.get(key):
            refuse(key, "top-level configs and secrets name files on the manager; use the catalog env")
    services = stack.get("services") or {}
    excluded = set(spec.get("exclude", []))
    for name in excluded:
        services.pop(name, None)
    for svc in services.values():
        deps = svc.get("depends_on")
        if isinstance(deps, list):
            svc["depends_on"] = [d for d in deps if d not in excluded]
        elif isinstance(deps, dict):
            svc["depends_on"] = {d: v for d, v in deps.items() if d not in excluded}

    stack = deep_merge(stack, spec.get("override", {}))
    services = stack.get("services") or {}
    stack.pop("version", None)

    published = {}
    for group in ("paths", "internal", "metrics"):
        for entry in spec.get(group, {}).values():
            published.setdefault(entry["service"], set()).add((entry["targetPort"], entry["port"]))
    missing = set(published) - set(services)
    if missing:
        refuse("catalog", f"publishes services the stack lacks: {sorted(missing)}")

    stateful = set(spec.get("stateful", []))
    allowed = set(spec.get("images", []))
    for name, svc in services.items():
        if "build" in svc:
            refuse(f"{name}.build", "the builder pins every build; an unbuilt service cannot run")
        for key in FORBIDDEN_SERVICE_KEYS:
            if key in svc:
                refuse(f"{name}.{key}", "not allowed on the apps swarm")
        for key in ("configs", "secrets"):
            if svc.get(key):
                refuse(f"{name}.{key}", "swarm configs and secrets come from host files; use the catalog env")
        check_image(name, str(svc.get("image", "")), app, allowed)
        check_volumes(name, svc)

        merged_env = env_as_dict(svc.get("environment"), f"{name}.environment")
        merged_env.update(env)
        svc["environment"] = {k: escape_interpolation(v) for k, v in merged_env.items()}
        svc.pop("env_file", None)
        svc.pop("logging", None)
        svc.pop("container_name", None)

        svc["ports"] = [
            {"target": target, "published": port, "protocol": "tcp", "mode": "ingress"}
            for target, port in sorted(published.get(name, ()))
        ]

        deploy = svc.setdefault("deploy", {})
        if deploy.get("mode", "replicated") != "replicated":
            refuse(f"{name}.deploy.mode", "only replicated services: a global one runs on every worker")
        if int(deploy.get("replicas", 1)) > REPLICAS_MAX:
            refuse(f"{name}.deploy.replicas", f"more than {REPLICAS_MAX}")
        # placement is the homelab's: a constraint naming its labels could reach another app's state volumes
        for constraint in (deploy.get("placement") or {}).get("constraints", []):
            if "homelab." in constraint:
                refuse(f"{name}.deploy.placement", f"{constraint}: homelab labels place only stateful services")
        limits = deploy.setdefault("resources", {}).setdefault("limits", {})
        limits.setdefault("memory", MEMORY_LIMIT_DEFAULT)
        limits.setdefault("pids", PIDS_LIMIT_DEFAULT)
        restart = deploy.setdefault("restart_policy", {})
        restart["condition"] = "any"
        # a capped restart count gives up for good; swarm's backoff is enough
        restart.pop("max_attempts", None)
        update = deploy.setdefault("update_config", {})
        update.setdefault("failure_action", "rollback")
        if name in stateful:
            constraints = deploy.setdefault("placement", {}).setdefault("constraints", [])
            if STATE_CONSTRAINT not in constraints:
                constraints.append(STATE_CONSTRAINT)
            # two copies on one volume corrupt it: the old task stops before the new one starts
            update["order"] = "stop-first"
            deploy["mode"] = "replicated"
            deploy["replicas"] = 1
        else:
            update.setdefault("order", "start-first")

    networks = stack.get("networks") or {}
    networks.setdefault("default", {})
    for name, net in networks.items():
        net = net or {}
        if net.get("external"):
            refuse(f"networks.{name}", "external networks reach outside the stack")
        if "name" in net:
            refuse(f"networks.{name}.name", "a literal name leaves the stack's namespace")
        net["driver"] = "overlay"
        net.setdefault("driver_opts", {})["encrypted"] = "true"
        net["attachable"] = False
        networks[name] = net
    stack["networks"] = networks

    for name, vol in (stack.get("volumes") or {}).items():
        if vol and (vol.get("external") or vol.get("driver_opts") or vol.get("driver")):
            refuse(f"volumes.{name}", "external volumes, drivers and driver options reach host paths")
        if vol and "name" in vol:
            refuse(f"volumes.{name}.name", "a literal name could be another app's volume")

    rendered = yaml.safe_dump(stack, sort_keys=True)
    for placeholder in PLACEHOLDERS:
        if placeholder in rendered:
            refuse("stack", f"{placeholder} left in the rendered stack: set it in the catalog env")
    return rendered


def main():
    if len(sys.argv) != 4:
        print("usage: swarm-render.py <app> <catalog.json> <env-file> < stack.yaml", file=sys.stderr)
        return 2
    app, catalog_path, env_path = sys.argv[1:]
    with open(catalog_path) as f:
        catalog = json.load(f)
    if app not in catalog:
        refuse("app", f"{app} is not an enabled app")
    raw = sys.stdin.buffer.read(STACK_BYTES_MAX + 1)
    if len(raw) > STACK_BYTES_MAX:
        refuse("stack", f"larger than {STACK_BYTES_MAX} bytes")
    stack = yaml.safe_load(raw) or {}
    if not isinstance(stack, dict):
        refuse("stack", "not a mapping")
    sys.stdout.write(render(app, catalog[app], env_from_file(env_path), stack))
    return 0


if __name__ == "__main__":
    sys.exit(main())
