"""Build and deploy the app catalog: a github repo and a branch each, everything else derived.

Usage: app-builder.py <catalog.json> <state-dir> <manager> [app ...]

For every app whose branch moved since its last good deploy (all given apps, if any are named): fetch that
commit, build each service the stack builds, push it to the registry tagged with the commit, pin it by the
digest the registry answered, inline every env_file the stack reads from the repo, and hand the stack to the
swarm manager (`ssh root@<manager> <app>`, a forced command: modules/swarm.nix), which adds the homelab's
ports, secrets and policy, then rolls it out. A failed app is retried on the next run; the others go on.

Writes <state-dir>/<app>.sha after a good deploy, and <state-dir>/metrics.prom for node-exporter.
APP_DEPLOY_KEY names the ssh key the manager's forced command accepts.
"""
import json
import os
import urllib.request
import subprocess
import sys
import tempfile
import time

import yaml

REGISTRY = "registry.lsck0.dev"
# looked up at the repo root when the catalog names no stack file, in this order
STACK_CONVENTIONS = ("compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml", "stack.yaml")
GITHUB = "https://github.com"
GITHUB_API = "https://api.github.com"
DEPLOY_TIMEOUT_S = 30 * 60
BUILD_TIMEOUT_S = 2 * 60 * 60


def log(app, message):
    print(f"{app}: {message}", flush=True)


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def branch_head(repo, branch):
    out = run(["git", "ls-remote", f"{GITHUB}/{repo}", f"refs/heads/{branch}"], capture_output=True).stdout.split()
    if not out:
        raise RuntimeError(f"no branch {branch} in {repo}")
    return out[0]


def last_change(repo, branch, paths):
    """Newest commit on the branch touching any of the paths; asked only when the branch head moved."""
    newest = None
    for path in paths:
        url = f"{GITHUB_API}/repos/{repo}/commits?sha={branch}&path={path}&per_page=1"
        with urllib.request.urlopen(url, timeout=30) as r:
            commits = json.load(r)
        if commits and (newest is None or commits[0]["commit"]["committer"]["date"] > newest[1]):
            newest = (commits[0]["sha"], commits[0]["commit"]["committer"]["date"])
    if newest is None:
        raise RuntimeError(f"no commit touches {paths} on {branch}")
    return newest[0]


def inside(root, path):
    """The path, resolved, if it stays in the checkout; a repo must not point a build or an env file elsewhere."""
    full = os.path.realpath(os.path.join(root, path))
    if full != os.path.realpath(root) and not full.startswith(os.path.realpath(root) + os.sep):
        raise RuntimeError(f"{path} leaves the checkout")
    return full


def checkout(repo, sha, into):
    run(["git", "init", "-q", into])
    run(["git", "-C", into, "fetch", "-q", "--depth", "1", f"{GITHUB}/{repo}", sha])
    run(["git", "-C", into, "checkout", "-q", "FETCH_HEAD"])
    # vendored code and large assets are part of the build: nyangine has both
    if os.path.exists(os.path.join(into, ".gitmodules")):
        run(["git", "-C", into, "submodule", "update", "-q", "--init", "--recursive", "--depth", "1"])
    if os.path.exists(os.path.join(into, ".gitattributes")):
        with open(os.path.join(into, ".gitattributes")) as f:
            if "filter=lfs" in f.read():
                run(["git", "-C", into, "lfs", "install", "--local"], capture_output=True)
                run(["git", "-C", into, "lfs", "pull"])
    return run(["git", "-C", into, "log", "-1", "--format=%cI"], capture_output=True).stdout.strip()


def load_stack(spec, repo_dir):
    """The stack file and the directory its relative paths start from."""
    path = spec.get("stack")
    if path is None:
        path = next((p for p in STACK_CONVENTIONS if os.path.exists(os.path.join(repo_dir, p))), None)
    if path is None:
        # no compose file: the repo is one image, built from its root Dockerfile
        return {"services": {"web": {"build": "."}}}, repo_dir
    full = inside(repo_dir, path)
    with open(full) as f:
        return yaml.safe_load(f) or {}, os.path.dirname(full)


def build_spec(svc, override, stack_dir, repo_dir):
    """(context, dockerfile, args) relative to the repo checkout, or None for a service that only names an image."""
    if override:
        context = inside(repo_dir, override.get("context", "."))
        dockerfile = inside(repo_dir, override.get("dockerfile", os.path.join(override.get("context", "."), "Dockerfile")))
        return context, dockerfile, override.get("args", {})
    build = svc.get("build")
    if build is None:
        return None
    if isinstance(build, str):
        build = {"context": build}
    context = inside(repo_dir, os.path.join(os.path.relpath(stack_dir, repo_dir), build.get("context", ".")))
    dockerfile = inside(repo_dir, os.path.join(os.path.relpath(context, repo_dir), build.get("dockerfile", "Dockerfile")))
    args = build.get("args") or {}
    if isinstance(args, list):
        args = dict(a.split("=", 1) for a in args)
    return context, dockerfile, args


def read_env_file(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if value[:1] == value[-1:] and value[:1] in ("'", '"'):
                value = value[1:-1]
            env[key.removeprefix("export ").strip()] = value
    return env


def inline_env(svc, stack_dir, repo_dir):
    """The manager has no checkout: env_file values become environment, environment still wins."""
    files = svc.pop("env_file", None) or []
    if isinstance(files, str):
        files = [files]
    merged = {}
    for f in files:
        path = f["path"] if isinstance(f, dict) else f
        merged.update(read_env_file(inside(repo_dir, os.path.join(os.path.relpath(stack_dir, repo_dir), path))))
    env = svc.get("environment") or {}
    if isinstance(env, list):
        env = dict(e.split("=", 1) if "=" in e else (e, "") for e in env)
    merged.update({k: "" if v is None else str(v) for k, v in env.items()})
    if merged:
        svc["environment"] = merged


def build_and_push(app, name, spec, sha, created):
    context, dockerfile, args = spec
    tag = f"{REGISTRY}/{app}/{name}:{sha}"
    cmd = ["docker", "build", "--pull", "-f", dockerfile, "-t", tag,
           "--build-arg", f"GIT_COMMIT={sha}", "--build-arg", f"LAST_UPDATED={created}"]
    for key, value in args.items():
        cmd += ["--build-arg", f"{key}={value}"]
    run(cmd + [context], timeout=BUILD_TIMEOUT_S)
    run(["docker", "push", "-q", tag], capture_output=True)
    digests = run(["docker", "image", "inspect", "--format", "{{json .RepoDigests}}", tag], capture_output=True).stdout
    digest = next(d for d in json.loads(digests) if d.startswith(f"{REGISTRY}/{app}/{name}@"))
    return digest


def deploy(app, stack, manager, key, known_hosts):
    run(["ssh", "-i", key, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
         "-o", "StrictHostKeyChecking=accept-new", "-o", f"UserKnownHostsFile={known_hosts}",
         f"root@{manager}", app], input=yaml.safe_dump(stack, sort_keys=True), timeout=DEPLOY_TIMEOUT_S)


def build_app(app, spec, sha, state_dir, manager):
    with tempfile.TemporaryDirectory(prefix=f"app-{app}-") as repo_dir:
        created = checkout(spec["repo"], sha, repo_dir)
        stack, stack_dir = load_stack(spec, repo_dir)
        services = stack.get("services") or {}
        for name in spec.get("exclude", []):
            services.pop(name, None)
        for name, svc in services.items():
            svc = svc if svc is not None else {}
            services[name] = svc
            bspec = build_spec(svc, spec.get("build", {}).get(name), stack_dir, repo_dir)
            if bspec is not None:
                log(app, f"building {name}")
                svc["image"] = build_and_push(app, name, bspec, sha, created)
                svc.pop("build", None)
            inline_env(svc, stack_dir, repo_dir)
        log(app, f"deploying {sha[:12]}")
        deploy(app, stack, manager, os.environ["APP_DEPLOY_KEY"], os.path.join(state_dir, "known_hosts"))


def write_metrics(state_dir, results):
    lines = [
        "# HELP homelab_app_deploy_ok 1 if the app's last build and deploy succeeded.",
        "# TYPE homelab_app_deploy_ok gauge",
    ]
    lines += [f'homelab_app_deploy_ok{{app="{app}"}} {1 if ok else 0}' for app, (ok, _) in sorted(results.items())]
    lines += [
        "# HELP homelab_app_deploy_last_success_timestamp_seconds Last good deploy of the app.",
        "# TYPE homelab_app_deploy_last_success_timestamp_seconds gauge",
    ]
    lines += [f'homelab_app_deploy_last_success_timestamp_seconds{{app="{app}"}} {ts}'
              for app, (_, ts) in sorted(results.items()) if ts]
    tmp = os.path.join(state_dir, "metrics.prom.tmp")
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, os.path.join(state_dir, "metrics.prom"))


def main():
    if len(sys.argv) < 4:
        print("usage: app-builder.py <catalog.json> <state-dir> <manager> [app ...]", file=sys.stderr)
        return 2
    catalog_path, state_dir, manager, *only = sys.argv[1:]
    with open(catalog_path) as f:
        catalog = json.load(f)
    unknown = set(only) - set(catalog)
    if unknown:
        print(f"unknown apps: {sorted(unknown)}", file=sys.stderr)
        return 2

    failed = 0
    results = {}
    for app, spec in sorted(catalog.items()):
        sha_file = os.path.join(state_dir, f"{app}.sha")
        head_file = os.path.join(state_dir, f"{app}.head")
        done_file = os.path.join(state_dir, f"{app}.done")
        last = open(sha_file).read().strip() if os.path.exists(sha_file) else None
        last_ts = int(os.path.getmtime(done_file)) if os.path.exists(done_file) else None
        try:
            head = branch_head(spec["repo"], spec["branch"])
            last_head = open(head_file).read().strip() if os.path.exists(head_file) else None
            if head == last_head and app not in only:
                results[app] = (True, last_ts)
                continue
            # an app inside a busy repo follows its own paths, not every commit of the branch
            sha = last_change(spec["repo"], spec["branch"], spec["watch"]) if spec.get("watch") else head
            if sha == last and app not in only:
                with open(head_file, "w") as f:
                    f.write(head + "\n")
                results[app] = (True, last_ts)
                continue
            build_app(app, spec, sha, state_dir, manager)
            with open(sha_file, "w") as f:
                f.write(sha + "\n")
            with open(head_file, "w") as f:
                f.write(head + "\n")
            open(done_file, "w").close()
            results[app] = (True, int(time.time()))
            log(app, "deployed")
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, RuntimeError, OSError, StopIteration,
                yaml.YAMLError, ValueError, KeyError) as e:
            log(app, f"failed: {e}")
            results[app] = (False, last_ts)
            failed += 1
    write_metrics(state_dir, results)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
