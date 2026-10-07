"""Build and deploy the app catalog: a github repo and a branch each, everything else derived.

Usage: app-builder.py <catalog.json> <state-dir> [app]

Without an app: for every app whose branch moved, whose build settings in the catalog changed, or whose last good
deploy is older than `baseRefreshS`, fetch the newest commit that matters (the branch head, or the newest touching
`watch`), build each service the stack builds (in parallel, `buildParallelism` at a time) unless the registry
already holds an image of the same content, push it tagged with its content key, pin it by the digest the registry
answered, inline every env_file the stack reads from the repo, and hand the stack to the app's swarm manager (this
host's through swarm-deploy@<app>, a guest's own over its forced command: modules/swarm), which adds the homelab's
ports, secrets, limits and policy, rolls it out and fails the deploy when the swarm rolled it back. A deployed
build is also tagged `latest`, which the registry's prune keeps. A failed app is retried with backoff (the same
commit and catalog entry no sooner than `backoff`); the others go on. With an app: the same look at that app alone,
now (its ci's /redeploy). Each app's turn holds that app's lock: a run finding an app busy in another leaves it to
that one, a run for one app waits for it.

State per app in <state-dir>/<app>.json, written after every attempt:
    {"head", "sha", "build_hash", "deployed_at", "committed_at", "built", "reused",
     "failure": null | {"head", "sha", "build_hash", "count", "retry_at"}}
<state-dir>/metrics.prom (node-exporter textfile) is derived from those after every run. The catalog json
(lib/app-builder.nix) carries the registry, the manager, the timeouts and the backoff; nothing is defined
twice. Forget an app's state (`app-builder-redeploy <app>` does) to deploy it again.

Content key: the git tree of the build context, the dockerfile's blob, the target, the build args and the digest of
every image a stage starts from, so a commit that leaves a service's sources alone reuses its image (same digest:
the swarm leaves the service running), a fresh or pruned builder reuses what the registry holds, and a base image's
security fix rebuilds the service at the next look, at the latest after `baseRefreshS`. GIT_COMMIT and LAST_UPDATED are passed as build args and
count in the key only where the dockerfile declares them; the commit and its date also go on every image as
labels, which touch no layer. Layers of a rebuilt service come from the local cache, else from the last live image
(inline cache, `--cache-from`).

Rejected: BuildKit's registry cache in mode=max (every stage's layers). It needs the docker-container driver, a
BuildKit image of its own in the builder; the content key already skips every unchanged service whole.

Rejected: three state files (.head, .sha, .done) with the head checked first. Removing .sha to force a redeploy
did nothing while the head stood still, a failed commit was rebuilt every minute, and a catalog-only change never
rebuilt anything.
"""
import base64
import concurrent.futures
import datetime
import fcntl
import hashlib
import json
import re
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

import yaml

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------

# looked up at the repo root when the catalog names no stack file, in this order
STACK_CONVENTIONS = ("compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml", "stack.yaml")
# a repo without a compose file is one image built from its root
STACK_DEFAULT = {"services": {"web": {"build": "."}}}
BUILD_KEYS = {"context", "dockerfile", "args", "target"}
# git's own abbreviation is 7; 12 hex digits never collide in repos this size
SHA_SHORT_LENGTH = 12
# the tag of what the swarm runs: the registry's nightly prune keeps it (118-internal-registry.nix), so the digest
# a service is pinned to stays pullable for a node that joins or reschedules later
LIVE_TAG = "latest"
# an image of one content: <registry>/<app>/<service>:<KEY_TAG_PREFIX><key>
KEY_TAG_PREFIX = "content-"
KEY_LENGTH = 32
# passed to every build, part of the key only where a dockerfile declares them (the template's server embeds them)
METADATA_ARGS = ("GIT_COMMIT", "LAST_UPDATED")
LABEL_REVISION = "org.opencontainers.image.revision"
LABEL_CREATED = "org.opencontainers.image.created"
LABEL_SOURCE = "org.opencontainers.image.source"
# the manifest kinds a docker push leaves, so the registry answers the digest docker recorded
MANIFEST_ACCEPT = ", ".join(("application/vnd.oci.image.index.v1+json", "application/vnd.oci.image.manifest.v1+json",
                             "application/vnd.docker.distribution.manifest.list.v2+json",
                             "application/vnd.docker.distribution.manifest.v2+json"))
HTTP_NOT_FOUND = 404
LOCK_SUFFIX = ".lock"
METRICS_FILE = "metrics.prom"
STATE_SUFFIX = ".json"
STATE_EMPTY = {"head": None, "sha": None, "build_hash": None, "deployed_at": None, "committed_at": None,
               "built": None, "reused": None, "failure": None}
# a stage starting from nothing or from an earlier stage has no base image of its own
BASE_NONE = "scratch"
FROM_LINE = re.compile(r"^\s*FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?\s*$", re.IGNORECASE)
ARG_LINE = re.compile(r"^\s*ARG\s+([A-Za-z_][A-Za-z0-9_]*)(?:=(\S*))?", re.IGNORECASE)
VARIABLE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?")
DIGEST_SEPARATOR = "@"
DOTENV_COMMENT = "#"
DOTENV_EXPORT = "export "


class BuildError(Exception):
    """An operating error of one app's build or deploy: the app fails this run, the others go on."""


# -----------------------------------------------------------------------------
# BOUNDARY: the forge, git, docker, the manager, the clock. tests/app_builder_sim_test.py replaces these.
# -----------------------------------------------------------------------------

def process_run(args, timeout_s, **kwargs):
    try:
        return subprocess.run(args, check=True, text=True, timeout=timeout_s, **kwargs)
    except subprocess.CalledProcessError as e:
        raise BuildError(f"{args[0]} {args[1]} failed with {e.returncode}") from e
    except subprocess.TimeoutExpired as e:
        raise BuildError(f"{args[0]} {args[1]} took longer than {timeout_s}s") from e


def time_now():
    return int(time.time())


def branch_head(ctx, repo, branch):
    out = process_run(["git", "ls-remote", f"{ctx['github']}/{repo}", f"refs/heads/{branch}"],
                      ctx["timeouts"]["gitS"], capture_output=True).stdout.split()
    if not out:
        raise BuildError(f"no branch {branch} in {repo}")
    return out[0]


def branch_last_change(ctx, repo, branch, paths):
    """Newest commit on the branch touching any of the paths; asked only when the head or the catalog moved."""
    newest = None
    for path in paths:
        url = f"{ctx['githubApi']}/repos/{repo}/commits?sha={branch}&path={path}&per_page=1"
        try:
            with urllib.request.urlopen(url, timeout=ctx["timeouts"]["apiS"]) as r:
                commits = json.load(r)
            sha, date = (commits[0]["sha"], commits[0]["commit"]["committer"]["date"]) if commits else (None, None)
        except (urllib.error.URLError, OSError, ValueError, KeyError, IndexError, TypeError) as e:
            raise BuildError(f"the commits api failed for {path}: {e}") from e
        if sha is not None and (newest is None or date > newest[1]):
            newest = (sha, date)
    if newest is None:
        raise BuildError(f"no commit touches {paths} on {branch}")
    return newest[0]


def repo_checkout(ctx, repo, sha, into):
    """The commit at `into`; its committer date, which images carry as LAST_UPDATED."""
    git_s = ctx["timeouts"]["gitS"]
    process_run(["git", "init", "-q", into], git_s)
    process_run(["git", "-C", into, "fetch", "-q", "--depth", "1", f"{ctx['github']}/{repo}", sha], git_s)
    process_run(["git", "-C", into, "checkout", "-q", "FETCH_HEAD"], git_s)
    # vendored code and large assets are part of the build: nyangine has both
    if os.path.exists(os.path.join(into, ".gitmodules")):
        process_run(["git", "-C", into, "submodule", "update", "-q", "--init", "--recursive", "--depth", "1"], git_s)
    attributes = os.path.join(into, ".gitattributes")
    if os.path.exists(attributes):
        with open(attributes, encoding="utf-8", errors="replace") as f:
            if "filter=lfs" in f.read():
                process_run(["git", "-C", into, "lfs", "install", "--local"], git_s, capture_output=True)
                process_run(["git", "-C", into, "lfs", "pull"], git_s)
    return process_run(["git", "-C", into, "log", "-1", "--format=%cI"], git_s, capture_output=True).stdout.strip()


def registry_login(ctx):
    with open(ctx["registryPasswordFile"], encoding="utf-8") as f:
        process_run(["docker", "login", ctx["registry"], "-u", ctx["registryUser"], "--password-stdin"],
                    ctx["timeouts"]["loginS"], stdin=f, capture_output=True)


def git_object(ctx, repo_dir, path):
    """The object id of the tree or blob at `path` of the checked-out commit ("" is the root tree)."""
    return process_run(["git", "-C", repo_dir, "rev-parse", f"HEAD:{path}"], ctx["timeouts"]["gitS"],
                       capture_output=True).stdout.strip()


def registry_request(ctx, method, path, headers=None, data=None):
    """One call to the registry's api as the push user; the response's headers and body."""
    with open(ctx["registryPasswordFile"], encoding="utf-8") as f:
        credentials = f"{ctx['registryUser']}:{f.read().strip()}"
    request = urllib.request.Request(
        f"https://{ctx['registry']}/v2/{path}", method=method, data=data,
        headers=dict(headers or {}, Authorization="Basic " + base64.b64encode(credentials.encode()).decode()))
    with urllib.request.urlopen(request, timeout=ctx["timeouts"]["apiS"]) as r:
        return r.headers, r.read()


def registry_digest(ctx, app, name, tag):
    """The digest the registry holds under <app>/<name>:<tag>, or None when it holds none."""
    try:
        headers, _ = registry_request(ctx, "HEAD", f"{app}/{name}/manifests/{tag}", {"Accept": MANIFEST_ACCEPT})
    except urllib.error.HTTPError as e:
        if e.code == HTTP_NOT_FOUND:
            return None
        raise BuildError(f"the registry answered {e.code} for {app}/{name}:{tag}") from e
    except (urllib.error.URLError, OSError) as e:
        raise BuildError(f"the registry is unreachable: {e}") from e
    digest = headers.get("Docker-Content-Digest", "")
    if not digest.startswith("sha256:"):
        raise BuildError(f"the registry named no digest for {app}/{name}:{tag}")
    return digest


def image_base_digest(ctx, image):
    """The digest the image's registry serves now: a pull that moves only what changed, then its pinned name."""
    if DIGEST_SEPARATOR in image:
        return image.split(DIGEST_SEPARATOR, 1)[1]
    timeout_s = ctx["timeouts"]["pushS"]
    process_run(["docker", "pull", "-q", image], timeout_s, capture_output=True)
    digests = json.loads(process_run(["docker", "image", "inspect", "--format", "{{json .RepoDigests}}", image],
                                     timeout_s, capture_output=True).stdout)
    if not digests:
        raise BuildError(f"the registry of {image} named no digest")
    return digests[0].split(DIGEST_SEPARATOR, 1)[1]


def image_build_push(ctx, app, name, build, tag, labels, args):
    """Build one service's image, push it, and return its digest-pinned reference."""
    timeouts = ctx["timeouts"]
    ref = f"{ctx['registry']}/{app}/{name}"
    # the last live image's layers when the local cache is empty (a fresh or pruned builder)
    cmd = ["docker", "build", "--pull", "-f", build["dockerfile"], "-t", f"{ref}:{tag}",
           "--cache-from", f"{ref}:{LIVE_TAG}", "--build-arg", "BUILDKIT_INLINE_CACHE=1"]
    if build["target"] is not None:
        cmd += ["--target", build["target"]]
    for key, value in sorted(args.items()):
        cmd += ["--build-arg", f"{key}={value}"]
    for key, value in sorted(labels.items()):
        cmd += ["--label", f"{key}={value}"]
    process_run(cmd + [build["context"]], timeouts["buildS"])
    process_run(["docker", "push", "-q", f"{ref}:{tag}"], timeouts["pushS"], capture_output=True)
    digests = process_run(["docker", "image", "inspect", "--format", "{{json .RepoDigests}}", f"{ref}:{tag}"],
                          timeouts["pushS"], capture_output=True).stdout
    pinned = [d for d in json.loads(digests) if d.startswith(f"{ref}@")]
    if not pinned:
        raise BuildError(f"the registry answered no digest for {ref}:{tag}")
    return pinned[0]


def image_mark_live(ctx, app, name, digest):
    """Tag a deployed image LIVE_TAG in the registry, by its manifest, whether or not this builder holds it.

    The stack names the digest; the tag keeps it from the registry's prune and is the next build's cache.
    """
    try:
        headers, manifest = registry_request(ctx, "GET", f"{app}/{name}/manifests/{digest}", {"Accept": MANIFEST_ACCEPT})
        registry_request(ctx, "PUT", f"{app}/{name}/manifests/{LIVE_TAG}",
                         {"Content-Type": headers.get("Content-Type", "")}, manifest)
    except (urllib.error.URLError, OSError) as e:
        raise BuildError(f"the registry refused the live tag of {app}/{name}: {e}") from e


def dashboards_publish(ctx, app, repo_dir, patterns):
    """The app's own dashboards from this commit into its grafana folder; a refusal names the file and why."""
    process_run([ctx["dashboardsImport"], app, repo_dir, ctx["dashboardsDir"], *patterns], ctx["timeouts"]["gitS"])


def stack_deploy(ctx, app, manager, stack):
    """The manager renders, deploys and checks; a refusal or a rollback is a failed deploy.

    The swarm this host manages takes the stack from the inbox through its one deploy unit; a guest's own swarm
    through its forced command over ssh. Either way the same swarm-deploy on the manager does the work.
    """
    timeouts = ctx["timeouts"]
    text = yaml.safe_dump(stack, sort_keys=True)
    if manager is None:
        file_write_atomic(os.path.join(ctx["inbox"], f"{app}.yaml"), text)
        process_run(["systemctl", "start", ctx["deployUnit"] + app + ".service"], timeouts["deployS"])
        return
    process_run(["ssh", "-i", ctx["deployKeyFile"], "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                 "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={manager['knownHosts']}",
                 "-o", "GlobalKnownHostsFile=/dev/null",
                 "-o", f"ConnectTimeout={timeouts['sshConnectS']}",
                 "-o", f"ServerAliveInterval={timeouts['sshAliveIntervalS']}",
                 "-o", f"ServerAliveCountMax={timeouts['sshAliveCountMax']}",
                 f"root@{manager['address']}", app],
                timeouts["deployS"], input=text)


# -----------------------------------------------------------------------------
# STACK: which file, which builds, which environment
# -----------------------------------------------------------------------------

def path_resolve_inside(root, path):
    """The path, resolved, if it stays in the checkout; a repo must not point a build or an env file elsewhere."""
    real_root = os.path.realpath(root)
    full = os.path.realpath(os.path.join(root, path))
    if full != real_root and not full.startswith(real_root + os.sep):
        raise BuildError(f"{path} leaves the checkout")
    return full


def stack_load(spec, repo_dir):
    """The stack and the directory its relative paths start from."""
    path = spec["stack"]
    if path is None:
        path = next((p for p in STACK_CONVENTIONS if os.path.exists(os.path.join(repo_dir, p))), None)
    if path is None:
        return json.loads(json.dumps(STACK_DEFAULT)), repo_dir
    full = path_resolve_inside(repo_dir, path)
    try:
        with open(full, encoding="utf-8") as f:
            stack = yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError) as e:
        raise BuildError(f"{path}: {e}") from e
    if not isinstance(stack, dict) or not isinstance(stack.get("services") or {}, dict):
        raise BuildError(f"{path}: not a compose file")
    return stack, os.path.dirname(full)


def build_resolve(svc, hint, stack_dir, repo_dir):
    """{context, dockerfile, target, args} inside the checkout, or None for a service that only names an image.

    A catalog `build` hint is relative to the repo root; a compose `build` to the stack file's directory.
    """
    if hint is not None:
        return {
            "context": path_resolve_inside(repo_dir, hint["context"]),
            "dockerfile": path_resolve_inside(repo_dir, hint["dockerfile"]),
            "target": hint["target"],
            "args": dict(hint["args"]),
        }
    build = svc.get("build")
    if build is None:
        return None
    if isinstance(build, str):
        build = {"context": build}
    if not isinstance(build, dict):
        raise BuildError("build is neither a path nor a mapping")
    unknown = set(build) - BUILD_KEYS
    if unknown:
        raise BuildError(f"build.{sorted(unknown)[0]} is not supported: the builder knows {sorted(BUILD_KEYS)}")
    stack_rel = os.path.relpath(stack_dir, repo_dir)
    context = path_resolve_inside(repo_dir, os.path.join(stack_rel, str(build.get("context", "."))))
    dockerfile = path_resolve_inside(repo_dir, os.path.join(os.path.relpath(context, repo_dir),
                                                            str(build.get("dockerfile", "Dockerfile"))))
    args = build.get("args") or {}
    if isinstance(args, list):
        args = dict(a.split("=", 1) if "=" in a else (a, "") for a in map(str, args))
    return {"context": context, "dockerfile": dockerfile, "target": build.get("target"),
            "args": {str(k): "" if v is None else str(v) for k, v in args.items()}}


def dotenv_value_parse(raw):
    """One dotenv value as compose reads it: quotes strip, a double-quoted one unescapes, ` #` ends a bare one."""
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] == "'":
        return raw[1:-1]
    if len(raw) >= 2 and raw[0] == raw[-1] == '"':
        out, i, inner = [], 0, raw[1:-1]
        escapes = {"n": "\n", "t": "\t", "\\": "\\", '"': '"'}
        while i < len(inner):
            if inner[i] == "\\" and i + 1 < len(inner) and inner[i + 1] in escapes:
                out.append(escapes[inner[i + 1]])
                i += 2
            else:
                out.append(inner[i])
                i += 1
        return "".join(out)
    comment = raw.find(" " + DOTENV_COMMENT)
    return (raw if comment < 0 else raw[:comment]).rstrip()


def env_file_read(path):
    env = {}
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError as e:
        raise BuildError(f"env_file {path}: {e}") from e
    for line in lines:
        line = line.strip()
        if not line or line.startswith(DOTENV_COMMENT) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.removeprefix(DOTENV_EXPORT).strip()] = dotenv_value_parse(value)
    return env


def compose_escape(value):
    """An env_file value is literal; in `environment` it is compose source, where $ must be $$."""
    return value.replace("$", "$$")


def env_inline(svc, stack_dir, repo_dir):
    """The manager has no checkout: env_file values become environment, environment still wins."""
    files = svc.pop("env_file", None) or []
    if isinstance(files, (str, dict)):
        files = [files]
    merged = {}
    stack_rel = os.path.relpath(stack_dir, repo_dir)
    for entry in files:
        path, required = (entry.get("path"), entry.get("required", True)) if isinstance(entry, dict) else (entry, True)
        if not isinstance(path, str):
            raise BuildError(f"env_file entry {entry!r} names no path")
        full = path_resolve_inside(repo_dir, os.path.join(stack_rel, path))
        if not required and not os.path.exists(full):
            continue
        merged.update({k: compose_escape(v) for k, v in env_file_read(full).items()})
    env = svc.get("environment") or {}
    if isinstance(env, list):
        env = dict(e.split("=", 1) if "=" in e else (e, "") for e in map(str, env))
    if not isinstance(env, dict):
        raise BuildError("environment is neither a map nor a list")
    merged.update({str(k): "" if v is None else str(v) for k, v in env.items()})
    if merged:
        svc["environment"] = merged


def dockerfile_declares(path, arg):
    with open(path, encoding="utf-8", errors="replace") as f:
        return re.search(rf"^\s*ARG\s+{arg}\b", f.read(), re.MULTILINE | re.IGNORECASE) is not None


def dockerfile_bases(path, args):
    """The images the dockerfile's stages start from, build args applied: never scratch, never an earlier stage."""
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    values, stages, bases = {}, set(), []
    for line in lines:
        arg = ARG_LINE.match(line)
        # only an ARG before the first FROM reaches a FROM line
        if arg and not stages:
            values[arg.group(1)] = args.get(arg.group(1), arg.group(2) or "")
        stage = FROM_LINE.match(line)
        if not stage:
            continue
        image = VARIABLE.sub(lambda m: values.get(m.group(1), m.group(0)), stage.group(1))
        if "$" in image:
            raise BuildError(f"{os.path.basename(path)}: FROM {stage.group(1)} names an argument without a value")
        if image.lower() != BASE_NONE and image not in stages:
            bases.append(image)
        stages.add(stage.group(2) or image)
    return bases


def content_key(ctx, repo_dir, build, args):
    """What the image is made of: the context's git tree, the dockerfile, the target, the args it reads, its bases."""
    read = {k: v for k, v in args.items() if k not in METADATA_ARGS or dockerfile_declares(build["dockerfile"], k)}
    context = os.path.relpath(build["context"], repo_dir)
    bases = sorted((image, image_base_digest(ctx, image)) for image in set(dockerfile_bases(build["dockerfile"], args)))
    parts = [git_object(ctx, repo_dir, "" if context == os.curdir else context),
             git_object(ctx, repo_dir, os.path.relpath(build["dockerfile"], repo_dir)), build["target"], sorted(read.items()),
             bases]
    return hashlib.sha256(json.dumps(parts).encode()).hexdigest()[:KEY_LENGTH]


def service_image(ctx, app, name, build, repo_dir, metadata, labels):
    """The service's digest-pinned image, the registry's of the same content or a fresh build; and whether built."""
    args = dict(metadata, **build["args"])
    tag = KEY_TAG_PREFIX + content_key(ctx, repo_dir, build, args)
    digest = registry_digest(ctx, app, name, tag)
    if digest is not None:
        return f"{ctx['registry']}/{app}/{name}@{digest}", False
    log(app, f"building {name}")
    return image_build_push(ctx, app, name, build, tag, labels, args), True


def app_build_deploy(ctx, app, spec, sha):
    """Build what changed, deploy the stack, tag it live; the deploy's facts for the state."""
    with tempfile.TemporaryDirectory(prefix=f"app-{app}-") as repo_dir:
        created = repo_checkout(ctx, spec["repo"], sha, repo_dir)
        stack, stack_dir = stack_load(spec, repo_dir)
        services = stack.get("services") or {}
        for name in spec["exclude"]:
            services.pop(name, None)
        builds = {}
        for name in list(services):
            svc = services[name] if isinstance(services[name], dict) else {}
            services[name] = svc
            build = build_resolve(svc, spec["build"].get(name), stack_dir, repo_dir)
            if build is not None:
                builds[name] = build
                svc.pop("build", None)
            env_inline(svc, stack_dir, repo_dir)
        if builds and not ctx["loggedIn"]:
            registry_login(ctx)
            ctx["loggedIn"] = True
        metadata = {"GIT_COMMIT": sha, "LAST_UPDATED": created}
        labels = {LABEL_REVISION: sha, LABEL_CREATED: created, LABEL_SOURCE: f"https://github.com/{spec['repo']}"}
        with concurrent.futures.ThreadPoolExecutor(max_workers=ctx["buildParallelism"]) as pool:
            images = dict(zip(builds, pool.map(
                lambda item: service_image(ctx, app, item[0], item[1], repo_dir, metadata, labels), builds.items())))
        for name, (image, _) in images.items():
            services[name]["image"] = image
        stack["services"] = services
        # before the deploy: a dashboard that does not parse fails the deploy, as a broken image would
        dashboards_publish(ctx, app, repo_dir, spec["dashboards"])
        log(app, f"deploying {sha_short(sha)}")
        stack_deploy(ctx, app, spec["manager"], stack)
        for name, (image, _) in images.items():
            image_mark_live(ctx, app, name, image.split("@", 1)[1])
    built = sum(1 for _, was_built in images.values() if was_built)
    return {"committed_at": int(datetime.datetime.fromisoformat(created).timestamp()), "built": built,
            "reused": len(images) - built}


# -----------------------------------------------------------------------------
# STATE
# -----------------------------------------------------------------------------

def log(app, message):
    print(f"{app}: {message}", flush=True)


def sha_short(sha):
    """A commit for a log line; a failure before the commit was known has none."""
    return "(no commit yet)" if sha is None else sha[:SHA_SHORT_LENGTH]


def file_write_atomic(path, text):
    """Readers see the old file or the new one; two writers of one path never share a temp file."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=os.path.basename(path) + ".")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def state_load(state_dir, app):
    path = os.path.join(state_dir, app + STATE_SUFFIX)
    if not os.path.exists(path):
        return dict(STATE_EMPTY)
    with open(path, encoding="utf-8") as f:
        # a state written before the deploy facts existed has none yet
        state = dict(STATE_EMPTY, **json.load(f))
    assert set(state) == set(STATE_EMPTY), (app, sorted(state))
    return state


def state_save(state_dir, app, state):
    file_write_atomic(os.path.join(state_dir, app + STATE_SUFFIX), json.dumps(state, sort_keys=True) + "\n")


def backoff_s(ctx, count):
    """1, 2, 4, ... times the base for the count-th failure of one commit, at most the cap."""
    assert count >= 1, count
    backoff = ctx["backoff"]
    delay = backoff["baseS"]
    # at most log2(max / base) doublings, however large the count
    for _ in range(count - 1):
        if delay >= backoff["maxS"]:
            break
        delay *= 2
    return min(delay, backoff["maxS"])


def metrics_render(states, run_at):
    lines = [
        "# HELP homelab_app_builder_last_run_timestamp_seconds When the builder last looked at every app.",
        "# TYPE homelab_app_builder_last_run_timestamp_seconds gauge",
        f"homelab_app_builder_last_run_timestamp_seconds {run_at}",
        "# HELP homelab_app_deploy_ok 0 while the app's newest commit failed to build or deploy, else 1.",
        "# TYPE homelab_app_deploy_ok gauge",
    ]
    attempted = {app: s for app, s in sorted(states.items()) if s["sha"] is not None or s["failure"] is not None}
    lines += [f'homelab_app_deploy_ok{{app="{app}"}} {0 if s["failure"] else 1}' for app, s in attempted.items()]
    lines += [
        "# HELP homelab_app_deploy_failures Consecutive failed attempts at the app's newest commit.",
        "# TYPE homelab_app_deploy_failures gauge",
    ]
    lines += [f'homelab_app_deploy_failures{{app="{app}"}} {s["failure"]["count"] if s["failure"] else 0}'
              for app, s in attempted.items()]
    lines += [
        "# HELP homelab_app_deploy_last_success_timestamp_seconds Last good deploy of the app.",
        "# TYPE homelab_app_deploy_last_success_timestamp_seconds gauge",
    ]
    lines += [f'homelab_app_deploy_last_success_timestamp_seconds{{app="{app}"}} {s["deployed_at"]}'
              for app, s in attempted.items() if s["deployed_at"] is not None]
    deployed = {app: s for app, s in attempted.items() if s["committed_at"] is not None}
    lines += [
        "# HELP homelab_app_deploy_latency_seconds From the deployed commit's date to its deploy.",
        "# TYPE homelab_app_deploy_latency_seconds gauge",
    ]
    lines += [f'homelab_app_deploy_latency_seconds{{app="{app}"}} {s["deployed_at"] - s["committed_at"]}'
              for app, s in deployed.items()]
    lines += [
        "# HELP homelab_app_images Images of the app's last deploy, built or reused from the registry by content.",
        "# TYPE homelab_app_images gauge",
    ]
    lines += [f'homelab_app_images{{app="{app}",how="{how}"}} {s[how]}' for app, s in deployed.items()
              for how in ("built", "reused")]
    return "\n".join(lines) + "\n"


# -----------------------------------------------------------------------------
# FUNCTIONS
# -----------------------------------------------------------------------------

def app_run(ctx, app, spec, state):
    """One app's turn: the next state. Raises nothing for an operating error; that is a failure in the state."""
    now = time_now()
    build_hash = spec["hash"]
    failure = state["failure"]
    # a deploy this old is looked at again for its base images, even when nothing of the app moved
    fresh = state["deployed_at"] is not None and now - state["deployed_at"] < ctx["baseRefreshS"]
    head = None
    target = None
    try:
        head = branch_head(ctx, spec["repo"], spec["branch"])
        if head == state["head"] and build_hash == state["build_hash"] and failure is None and fresh:
            return state
        if (failure is not None and head == failure["head"] and build_hash == failure["build_hash"]
                and now < failure["retry_at"]):
            log(app, f"failed {failure['count']} times at {sha_short(failure['sha'])}, next try at {failure['retry_at']}")
            return state
        # an app inside a busy repo follows its own paths, not every commit of the branch
        target = branch_last_change(ctx, spec["repo"], spec["branch"], spec["watch"]) if spec["watch"] else head
        if target == state["sha"] and build_hash == state["build_hash"] and fresh:
            return dict(state, head=head, failure=None)
        facts = app_build_deploy(ctx, app, spec, target)
    except BuildError as e:
        log(app, f"failed: {e}")
        same = failure is not None and failure["sha"] == target and failure["build_hash"] == build_hash
        count = failure["count"] + 1 if same else 1
        return dict(state, failure={"head": head, "sha": target, "build_hash": build_hash, "count": count,
                                    "retry_at": now + backoff_s(ctx, count)})
    log(app, f"deployed {sha_short(target)}: {facts['built']} built, {facts['reused']} reused")
    return dict(facts, head=head, sha=target, build_hash=build_hash, deployed_at=time_now(), failure=None)


def app_lock(state_dir, app, wait):
    """The app's lock, held; None when another run holds it and this one does not wait."""
    lock = open(os.path.join(state_dir, app + LOCK_SUFFIX), "w", encoding="utf-8")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
    except BlockingIOError:
        lock.close()
        return None
    return lock


def builder_run(ctx, apps, state_dir, only):
    """Every app in name order, or only the named one; the run's exit code."""
    assert only is None or only in apps, only
    failed = 0
    for app in sorted(apps) if only is None else [only]:
        # the timer's run leaves an app to the run already at it; a run for one app waits for it
        lock = app_lock(state_dir, app, wait=only is not None)
        if lock is None:
            log(app, "busy in another run")
            continue
        with lock:
            state = app_run(ctx, app, apps[app], state_load(state_dir, app))
            state_save(state_dir, app, state)
        failed += state["failure"] is not None
    states = {app: state_load(state_dir, app) for app in apps}
    file_write_atomic(os.path.join(state_dir, METRICS_FILE), metrics_render(states, time_now()))
    return 1 if failed else 0


def main():
    if len(sys.argv) not in (3, 4):
        print("usage: app-builder.py <catalog.json> <state-dir> [app]", file=sys.stderr)
        return 2
    catalog_path, state_dir = sys.argv[1:3]
    only = sys.argv[3] if len(sys.argv) == 4 else None
    with open(catalog_path, encoding="utf-8") as f:
        catalog = json.load(f)
    if only is not None and only not in catalog["apps"]:
        print(f"app-builder: unknown app {only}; known: {sorted(catalog['apps'])}", file=sys.stderr)
        return 2
    return builder_run(dict(catalog, loggedIn=False), catalog["apps"], state_dir, only)


if __name__ == "__main__":
    sys.exit(main())
