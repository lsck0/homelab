"""Deterministic simulation of the app builder's state machine with fault injection (lib/app-builder.py).

Usage: app_builder_sim_test.py <path to app-builder.py> [seed ...]

The builder's boundary (the forge, git, the registry, the manager's forced command, the clock, its own state
writes) is replaced by a simulated world that one seed drives: which commits land and which paths they touch,
when the catalog's build settings change, which calls fail (forge 5xx, a lost checkout, a refused login, a
registry 5xx, an ssh timeout, a manager refusal, a deploy the manager took whose answer was lost) and where the
process crashes between two of its writes. Everything above the boundary is the real code. After every
simulated run the invariants are checked; a failing seed is a complete, replayable bug report:

    app_builder_sim_test.py src/instances/140-internal-swarm/lib/app-builder.py 4711

I1 an app's recorded sha is a commit whose stack, with exactly that commit's images, the manager accepted
I2 a run that finds the newest watched commit deployed, with the same catalog entry, builds and deploys nothing
I3 once faults stop, a run after the backoff cap brings every app to its newest commit (liveness)
I4 metrics.prom is a complete file that agrees with the states after every finished run
I5 a run for one named app (its ci's /redeploy) looks at that app as the timer would and leaves the others alone;
   an unknown name exits 2 and touches nothing
I6 an app none of whose calls failed in a run is deployed by it, whatever the others did
I7 a forgotten app (app-builder-redeploy) is deployed again, and its deployed commit builds nothing: the registry
   holds its content
I8 after baseRefreshS a changed base image rebuilds and deploys the app though its branch stood still; an unchanged
   base deploys the same images and builds nothing
"""
import contextlib
import io
import json
import os
import random
import sys
import tempfile

import yaml

sys.dont_write_bytecode = True
import importlib.util  # noqa: E402

spec = importlib.util.spec_from_file_location("app_builder", sys.argv[1])
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------

SEEDS_PER_RUN = 1000
# seeds that once failed; each stays here for good
REGRESSION_SEEDS = []
STEPS = 12
REGISTRY = "registry.test"
PATHS = ("web", "docs", "README.md")
# chance per call that a fault fires, while the seed's faulty phase lasts
FAULT_PROBABILITY = 0.25
CRASH_PROBABILITY = 0.1
BACKOFF = {"baseS": 300, "maxS": 3600}
# simulated seconds between two timer runs
RUN_INTERVAL_S = 60
# longer than a seed's whole run, so only I8 sees a refresh
BASE_REFRESH_S = 10 ** 6
BASE_IMAGE = "base:1"
FAULTS = ("forge", "api", "checkout", "login", "registry", "ssh-timeout", "refused", "answer-lost")


# the real functions the simulation wraps, taken once: every seed installs its world over these
ORIGINAL = {name: getattr(builder, name) for name in ("app_build_deploy", "file_write_atomic")}


class SimCrash(Exception):
    """The builder process died between two writes."""


# -----------------------------------------------------------------------------
# TYPES
# -----------------------------------------------------------------------------

# every fault kind and crash fired over the whole run: a run where none fire proves nothing
FIRED = {kind: 0 for kind in FAULTS + ("crash",)}


class World:
    def __init__(self, seed):
        self.rng = random.Random(seed)
        self.clock = 1_700_000_000
        self.faulty = True
        self.commits = {"hello": [], "plain": []}
        self.hashes = {"hello": "h0", "plain": "p0"}
        # every stack the manager took: (app, commit, image)
        self.accepted = []
        self.calls = {}
        self.writes_until_crash = None
        self.counter = 0
        # what the registry holds: content tag -> digest, filled by pushes, read by the content lookup
        self.registry = {}
        self.builds = 0
        self.base_digest = "sha256:" + "1" * 64

    def commit(self, app, touched=None):
        self.counter += 1
        self.clock += 1
        if touched is None:
            touched = self.rng.sample(PATHS, self.rng.randint(1, len(PATHS)))
        self.commits[app].append({"sha": f"{self.counter:040x}", "touched": touched, "date": self.clock})

    def head(self, app):
        return self.commits[app][-1]["sha"] if self.commits[app] else None

    def newest_touching(self, app, paths):
        for c in reversed(self.commits[app]):
            if set(c["touched"]) & set(paths):
                return c["sha"]
        return None

    def fault(self, app, kind):
        """True when the seed lets this call of this app fail; every fault is counted per app."""
        if not self.faulty or self.rng.random() >= FAULT_PROBABILITY:
            return False
        self.calls.setdefault(app, []).append(kind)
        FIRED[kind] += 1
        return True


def catalog_of(world):
    apps = {
        "hello": {"repo": "lsck0/hello", "branch": "master", "stack": None, "build": {}, "exclude": [],
                  "watch": ["web"], "hash": world.hashes["hello"], "dashboards": [], "manager": None},
        "plain": {"repo": "lsck0/plain", "branch": "master", "stack": None, "build": {}, "exclude": [],
                  "watch": [], "hash": world.hashes["plain"], "dashboards": [], "manager": None},
    }
    return {"registry": REGISTRY, "registryUser": "builder", "registryPasswordFile": "/dev/null",
            "deployKeyFile": "/dev/null", "github": "https://forge.test", "githubApi": "https://api.forge.test",
            "manager": {"address": "10.0.0.1", "knownHosts": "/dev/null"}, "timeouts": {}, "backoff": BACKOFF,
            "buildParallelism": 2, "baseRefreshS": BASE_REFRESH_S,
            "apps": apps, "loggedIn": False}


def app_of_repo(repo):
    return repo.split("/")[1]


# -----------------------------------------------------------------------------
# BOUNDARY: the simulated forge, registry and manager
# -----------------------------------------------------------------------------

def world_install(world):
    def branch_head(ctx, repo, branch):
        app = app_of_repo(repo)
        if world.fault(app, "forge") or world.head(app) is None:
            raise builder.BuildError("forge 5xx")
        return world.head(app)

    def branch_last_change(ctx, repo, branch, paths):
        app = app_of_repo(repo)
        if world.fault(app, "api"):
            raise builder.BuildError("api 5xx")
        sha = world.newest_touching(app, paths)
        if sha is None:
            raise builder.BuildError("no commit touches the paths")
        return sha

    def repo_checkout(ctx, repo, sha, into):
        app = app_of_repo(repo)
        if world.fault(app, "checkout"):
            raise builder.BuildError("fetch failed")
        with open(os.path.join(into, "compose.yaml"), "w", encoding="utf-8") as f:
            yaml.safe_dump({"services": {"web": {"build": ".", "environment": {"COMMIT": sha}}}}, f)
        with open(os.path.join(into, "Dockerfile"), "w", encoding="utf-8") as f:
            f.write(f"FROM {BASE_IMAGE}\nARG GIT_COMMIT\n")
        return "2026-01-01T00:00:00Z"

    def registry_login(ctx):
        # the login is shared by the run: its failure belongs to the app that needed it first
        if world.fault(ctx["building"], "login"):
            raise builder.BuildError("login refused")

    def git_object(ctx, repo_dir, path):
        # a commit's tree differs from every other commit's: the checkout's root is the only context here
        with open(os.path.join(repo_dir, "compose.yaml"), encoding="utf-8") as f:
            return f"{path}:{yaml.safe_load(f)['services']['web']['environment']['COMMIT']}"

    def image_base_digest(ctx, image):
        assert image == BASE_IMAGE, image
        if world.fault(ctx["building"], "registry"):
            raise builder.BuildError("the base image's registry 5xx")
        return world.base_digest

    def registry_digest(ctx, app, name, tag):
        if world.fault(app, "registry"):
            raise builder.BuildError("registry 5xx on the content lookup")
        return world.registry.get((app, name, tag))

    def image_build_push(ctx, app, name, build, tag, labels, args):
        if world.fault(app, "registry"):
            raise builder.BuildError("registry 5xx")
        sha = labels[builder.LABEL_REVISION]
        assert args["GIT_COMMIT"] == sha, (args, sha)
        world.builds += 1
        world.registry[(app, name, tag)] = f"sha256:{sha[-12:]:0>64}"
        return f"{REGISTRY}/{app}/{name}@sha256:{sha[-12:]:0>64}"

    def image_mark_live(ctx, app, name, digest):
        if world.fault(app, "registry"):
            raise builder.BuildError("registry 5xx on the live tag")

    def stack_deploy(ctx, app, manager, stack):
        web = stack["services"]["web"]
        if world.fault(app, "ssh-timeout"):
            raise builder.BuildError("ssh took longer than the bound")
        if world.fault(app, "refused"):
            raise builder.BuildError("manager refused")
        world.accepted.append((app, web["environment"]["COMMIT"], web["image"]))
        if world.fault(app, "answer-lost"):
            raise builder.BuildError("connection reset after the deploy")

    real_build_deploy = ORIGINAL["app_build_deploy"]

    def app_build_deploy(ctx, app, spec_, sha):
        ctx["building"] = app
        return real_build_deploy(ctx, app, spec_, sha)

    real_write = ORIGINAL["file_write_atomic"]

    def file_write_atomic(path, text):
        if world.writes_until_crash is not None:
            if world.writes_until_crash == 0:
                world.writes_until_crash = None
                FIRED["crash"] += 1
                raise SimCrash(path)
            world.writes_until_crash -= 1
        real_write(path, text)

    builder.branch_head = branch_head
    builder.branch_last_change = branch_last_change
    builder.repo_checkout = repo_checkout
    builder.registry_login = registry_login
    builder.git_object = git_object
    builder.dashboards_publish = lambda ctx, app, repo_dir, patterns: None
    builder.registry_digest = registry_digest
    builder.image_base_digest = image_base_digest
    builder.image_build_push = image_build_push
    builder.stack_deploy = stack_deploy
    builder.image_mark_live = image_mark_live
    builder.app_build_deploy = app_build_deploy
    builder.file_write_atomic = file_write_atomic
    builder.time_now = lambda: world.clock
    builder.log = lambda app, message: None


# -----------------------------------------------------------------------------
# INVARIANTS
# -----------------------------------------------------------------------------

def states_of(state_dir, apps):
    return {app: builder.state_load(state_dir, app) for app in apps}


def target_of(world, app, spec_):
    return world.newest_touching(app, spec_["watch"]) if spec_["watch"] else world.head(app)


def check_recorded(world, states, where):
    for app, state in states.items():
        if state["sha"] is not None:
            image = f"{REGISTRY}/{app}/web@sha256:{state['sha'][-12:]:0>64}"
            assert (app, state["sha"], image) in world.accepted, f"{where}: I1 {app} records {state['sha']} unaccepted"


def check_metrics(state_dir, states, world, where):
    with open(os.path.join(state_dir, builder.METRICS_FILE), encoding="utf-8") as f:
        text = f.read()
    assert text.endswith("\n") and f"homelab_app_builder_last_run_timestamp_seconds {world.clock}" in text, where
    for app, state in states.items():
        attempted = state["sha"] is not None or state["failure"] is not None
        line = f'homelab_app_deploy_ok{{app="{app}"}} {0 if state["failure"] else 1}'
        assert (line in text) == attempted, f"{where}: I4 metrics say {text!r} for {app} in state {state}"


def run_once(world, state_dir, only=None):
    """One builder run; the states before it, and whether it finished (no crash)."""
    world.calls = {}
    world.writes_until_crash = None
    if world.faulty and world.rng.random() < CRASH_PROBABILITY:
        world.writes_until_crash = world.rng.randint(0, 3)
    catalog = catalog_of(world)
    before = states_of(state_dir, catalog["apps"])
    deploys_before = len(world.accepted)
    try:
        builder.builder_run(catalog, catalog["apps"], state_dir, only)
        finished = True
    except SimCrash:
        finished = False
    return catalog, before, deploys_before, finished


def check_run(world, state_dir, catalog, before, deploys_before, finished, only, where):
    states = states_of(state_dir, catalog["apps"])
    check_recorded(world, states, where)
    if not finished:
        return
    check_metrics(state_dir, states, world, where)
    for app, spec_ in catalog["apps"].items():
        new = [a for a in world.accepted[deploys_before:] if a[0] == app]
        prior = before[app]
        target = target_of(world, app, spec_)
        if only is not None and only != app:
            assert states[app] == prior and not new, f"{where}: I5 a run for {only} changed {app}"
            continue
        if prior["sha"] == target and prior["build_hash"] == spec_["hash"]:
            assert not new, f"{where}: I2 {app} redeployed {target}, already live"
        failure = prior["failure"]
        backing_off = (failure is not None and failure["head"] == world.head(app)
                       and failure["build_hash"] == spec_["hash"] and world.clock < failure["retry_at"])
        if app not in world.calls and not backing_off and world.head(app) is not None:
            assert states[app]["failure"] is None and states[app]["sha"] == target, \
                f"{where}: I6 {app} met no fault but is {states[app]}, target {target}"


# -----------------------------------------------------------------------------
# FUNCTIONS
# -----------------------------------------------------------------------------

def unknown_app_untouched(world, state_dir):
    """I5: main refuses an unknown app before it takes the lock or writes anything."""
    before = sorted(os.listdir(state_dir))
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(catalog_of(world), f)
    argv = sys.argv
    sys.argv = ["app-builder.py", f.name, state_dir, "nope"]
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            code = builder.main()
    finally:
        sys.argv = argv
        os.unlink(f.name)
    assert code == 2 and sorted(os.listdir(state_dir)) == before, "I5: an unknown app changed the state dir"


def seed_run(seed):
    world = World(seed)
    world_install(world)
    with tempfile.TemporaryDirectory() as state_dir:
        # the first commit creates every path, as a repo's first commit does
        for app in world.commits:
            world.commit(app, touched=list(PATHS))
        for step in range(STEPS):
            where = f"seed {seed} step {step}"
            for app in world.commits:
                if world.rng.random() < 0.5:
                    world.commit(app)
                if world.rng.random() < 0.1:
                    world.hashes[app] = f"{app}-{step}"
            only = world.rng.choice([None, None, None, "hello", "plain"])
            catalog, before, deploys_before, finished = run_once(world, state_dir, only)
            check_run(world, state_dir, catalog, before, deploys_before, finished, only, where)
            world.clock += RUN_INTERVAL_S
        unknown_app_untouched(world, state_dir)
        # faults stop; after the backoff cap two timer runs bring every app to its newest commit
        world.faulty = False
        world.clock += BACKOFF["maxS"]
        for attempt in range(2):
            catalog, before, deploys_before, finished = run_once(world, state_dir)
            check_run(world, state_dir, catalog, before, deploys_before, finished, None, f"seed {seed} calm {attempt}")
            world.clock += RUN_INTERVAL_S
        for app, spec_ in catalog["apps"].items():
            state = builder.state_load(state_dir, app)
            target = target_of(world, app, spec_)
            image = f"{REGISTRY}/{app}/web@sha256:{target[-12:]:0>64}"
            assert state["sha"] == target and state["failure"] is None, f"seed {seed}: I3 {app} stuck at {state}"
            assert (app, target, image) in world.accepted, f"seed {seed}: I3 the manager never took {app} {target}"
        builds = world.builds
        os.remove(os.path.join(state_dir, "hello" + builder.STATE_SUFFIX))
        catalog, before, deploys_before, finished = run_once(world, state_dir, "hello")
        assert finished and world.builds == builds and len(world.accepted) == deploys_before + 1, \
            f"seed {seed}: I7 a redeploy of hello's live commit built {world.builds - builds} images"
        for changed in (False, True):
            world.clock += BASE_REFRESH_S
            if changed:
                world.base_digest = "sha256:" + "2" * 64
            builds = world.builds
            catalog, before, deploys_before, finished = run_once(world, state_dir)
            assert finished and world.builds == builds + (len(catalog["apps"]) if changed else 0), \
                f"seed {seed}: I8 base changed {changed}: {world.builds - builds} builds"
            assert len(world.accepted) == deploys_before + len(catalog["apps"]), \
                f"seed {seed}: I8 base changed {changed}: not every app was looked at again"


def main():
    seeds = [int(s) for s in sys.argv[2:]] or list(range(SEEDS_PER_RUN)) + REGRESSION_SEEDS
    failed = []
    for seed in seeds:
        try:
            seed_run(seed)
        except AssertionError as e:
            failed.append(seed)
            print(f"FAIL {e}")
    print(f"app-builder-sim: {len(seeds) - len(failed)}/{len(seeds)} seeds hold; faults fired: {FIRED}")
    if len(seeds) >= SEEDS_PER_RUN:
        silent = [kind for kind, count in FIRED.items() if count == 0]
        assert not silent, f"faults that never fired: {silent}"
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
