"""Sync the syncthing folder with its Proton Drive copy both ways through proton's own drive cli.

Usage: proton-bisync-engine sync|resync
    run by proton-bisync.nu, which holds the proton lock, guards the folder and checks that proton is up; the
    environment is lib/kopia.nix's bisyncEnv.

State (<PROTON_BISYNC_STATE>/state.json) is the last snapshot both sides agreed on, one entry per relative path:
    file {"t": "f", "ls", "lm": local size and mtime (ms), "rs", "rm", "rr": remote claimed size, claimed mtime (ms)
          and revision uid (null until a listing shows it)}
    dir  {"t": "d", "listed": unix time its remote listing was last read (0: list it first), "hot": time of its last
          change}
A side changed where it differs from its half of the entry. Per path: one side changed -> the other follows (a new or
changed file is copied, a folder created; a deletion is deleted: on proton into its trash, here into
<TRASH>/<date>/<path>, pruned after TRASH_DAYS); both changed to different content -> both kept: the local version
under the name, the remote one beside it as <stem>.<CONFLICT_SUFFIX>[n]<ext>, on both sides; a change beats a
deletion. Two versions are the same content at the same size and mtime (ms, which the cli keeps as the claimed
modification time of an upload) or the same sha1. An entry changes the moment its item succeeded, so a run cut short
or failing on some items resumes with the rest; a folder with a failure is listed first next run.

resync lays the baseline: every remote folder listed, both sides merged without deleting anything (the union; a path
whose two versions differ keeps both, as a conflict does).

Listing: the cli lists one folder per call, at 1-4 s (the session, keys and path resolution, every time), and a
folder's modificationTime stays put when its children change, so nothing short of listing a folder shows what changed
in it. All ~13k folders of the real tree take ~7 h. So a sync run lists the root, the folder of every local change (its remote side decides
between upload and conflict) and then the folders read longest ago, one changed within HOT_DAYS counted HOT_BOOST
older, until SWEEP_SECONDS are spent; a folder not listed is taken as the state has it. Local changes go up every
run; a remote change arrives once its folder's turn comes.

Guards: a missing remote root is refused; a run deleting more than MAX_DELETE_PERCENT of the entries on either side
syncs nothing (exit EXIT_GUARD) unless PROTON_BISYNC_ALLOW_LARGE=1; a path that is a file on one side and a folder on
the other is left for the owner, and so is a name that would land beside a twin differing from it only in unicode
normalization (NFC/NFD: syncthing refuses to scan such a pair). A download that would leave less than
FREE_RESERVE_PERCENT of the folder's file system free fails that file, not the disk. Symlinks and special files stay
local (proton stores none), logged. A failed cli call while PROBE says proton is down ends the run with the probe's
status, the state saved.
"""

import calendar
import grp
import hashlib
import heapq
import json
import os
import pwd
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import unicodedata
from datetime import datetime
from fnmatch import fnmatchcase
from itertools import groupby
from typing import NamedTuple

ENV = os.environ
SOURCE = ENV["PROTON_BISYNC_SOURCE"]
# the remote folder SOURCE is synced with, a posix path below /my-files
REMOTE = ENV["PROTON_BISYNC_REMOTE"]
STATE_FILE = os.path.join(ENV["PROTON_BISYNC_STATE"], "state.json")
# name patterns that stay on their side, matched against every path component
EXCLUDES = ENV["PROTON_BISYNC_EXCLUDES"].split()
MAX_DELETE_PERCENT = int(ENV["PROTON_BISYNC_MAX_DELETE_PERCENT"])
ALLOW_LARGE = ENV.get("PROTON_BISYNC_ALLOW_LARGE") == "1"
CONFLICT_SUFFIX = ENV["PROTON_BISYNC_CONFLICT_SUFFIX"]
# where local deletions wait, a folder per day; beside SOURCE, so a move into it stays on the file system
TRASH = ENV["PROTON_BISYNC_TRASH"]
TRASH_DAYS = int(ENV["PROTON_BISYNC_TRASH_DAYS"])
SWEEP_SECONDS = int(ENV["PROTON_BISYNC_SWEEP_SECONDS"])
FREE_RESERVE_PERCENT = int(ENV["PROTON_BISYNC_FREE_RESERVE_PERCENT"])
OWNER_USER, OWNER_GROUP = ENV["PROTON_BISYNC_OWNER"].split(":")
CLI = ENV["PROTON_BISYNC_CLI"]
# exits 0 while proton answers, its own status (modules/upstream's unavailable) while it is down
PROBE = ENV["PROTON_BISYNC_PROBE"]

# downloads land here first, then move into place whole
STAGING = os.path.join(TRASH, ".staging")
# paths per cli call: a bound keeps a call's runtime and argv small
BATCH_COUNT = 100
# a list, trash or create-folder call; a transfer gets this plus its bytes at MIN_TRANSFER_RATE
CALL_TIMEOUT = 600
MIN_TRANSFER_RATE = 1 << 20
SAVE_SECONDS = 60
HOT_DAYS = 7
HOT_BOOST = 12 * 3600
# syncthing's own modes
FILE_MODE = 0o644
DIR_MODE = 0o755
# the cli's error for a path that is not there
GONE = "Node not found"
# the cli prints its error under a row of '=' after a source excerpt: the tail holds the cause
ERROR_CHARS = 400
EXIT_FAILED = 1
EXIT_GUARD = 3
STATE_VERSION = 1
NS_PER_MS = 1_000_000
KIND_NAMES = {"f": "file", "d": "folder", "x": "special file"}


class Node(NamedTuple):
    """one side's item: kind f(ile), d(irectory) or x (neither); size -1 when the remote does not claim one"""

    kind: str
    size: int = 0
    mtime: int = 0
    rev: str | None = None
    sha1: str | None = None


# a remote item in a folder this run has not listed
UNKNOWN = Node("?")


class Outage(Exception):
    """proton went down mid-run: the run ends with the probe's status"""


class Refused(Exception):
    """the run must not start: the reason is the message"""


class Guard(Exception):
    """the run would delete past MAX_DELETE_PERCENT"""


class Stop(Exception):
    """systemd stops the run (timeout or by hand)"""


def log(message):
    print(message, flush=True)


def parent(rel):
    return rel.rpartition("/")[0]


def basename(rel):
    return rel.rpartition("/")[2]


def join(folder, name):
    return f"{folder}/{name}" if folder else name


def ancestors(rel):
    """the folders above rel, the root ("") last"""
    while rel:
        rel = parent(rel)
        yield rel


def under(rel, root):
    return rel.startswith(root + "/")


def path_key(rel):
    """a folder sorts right before its own subtree"""
    return rel.split("/")


def local_path(rel):
    return os.path.join(SOURCE, rel) if rel else SOURCE


# the cli takes a local argument holding * ? [ or { as a glob pattern ({GUID} folders, name[1].ext files) and any
# other one as it is
def glob_literal(path):
    if not re.search(r"[*?\[{]", path):
        return path
    return re.sub(r"([][{}()*?!+@\\])", r"\\\1", path)


def remote_path(rel):
    return f"{REMOTE}/{rel}" if rel else REMOTE


def excluded(name):
    return any(fnmatchcase(name, pattern) for pattern in EXCLUDES)


def ms_of_iso(text):
    moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    return calendar.timegm(moment.utctimetuple()) * 1000 + moment.microsecond // 1000


def short(text):
    """the tail of a cli error on one line, its banner rows dropped"""
    kept = (line for line in text.splitlines() if line.strip(" \t=-"))
    return " ".join(" ".join(kept).split())[-ERROR_CHARS:]


def nfc(rel):
    return unicodedata.normalize("NFC", rel)


def free_bytes(path):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize


def reserve_bytes(path):
    st = os.statvfs(path)
    return st.f_blocks * st.f_frsize * FREE_RESERVE_PERCENT // 100


def local_node(path):
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    if stat.S_ISDIR(st.st_mode):
        return Node("d")
    if stat.S_ISREG(st.st_mode):
        return Node("f", st.st_size, st.st_mtime_ns // NS_PER_MS)
    return Node("x")


def local_scan():
    """every path below SOURCE but the excluded -> Node; symlinks and special files are skipped and logged"""
    items, skipped, stack = {}, [], [""]
    while stack:
        folder = stack.pop()
        with os.scandir(local_path(folder)) as entries:
            for entry in entries:
                if excluded(entry.name):
                    continue
                rel = join(folder, entry.name)
                if entry.is_dir(follow_symlinks=False):
                    items[rel] = Node("d")
                    stack.append(rel)
                elif entry.is_file(follow_symlinks=False):
                    st = entry.stat(follow_symlinks=False)
                    items[rel] = Node("f", st.st_size, st.st_mtime_ns // NS_PER_MS)
                else:
                    skipped.append(rel)
    if skipped:
        more = " ..." if len(skipped) > 10 else ""
        log(f"{len(skipped)} symlinks or special files stay local, proton stores none: {', '.join(skipped[:10])}{more}")
    return items


def sha1_of(path):
    digest = hashlib.sha1()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def cli(*args, timeout=CALL_TIMEOUT):
    """runs `proton-drive filesystem <args>`: (succeeded, stdout, its error text)

    The cli prints some failures on stdout under a banner on stderr: the error text holds both, stderr last."""
    try:
        done = subprocess.run(
            [CLI, "filesystem", *args], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired:
        return False, "", f"timed out after {timeout} s"
    succeeded = done.returncode == 0
    return succeeded, done.stdout, done.stderr if succeeded else f"{done.stdout}\n{done.stderr}"


def outage_check():
    """a failure while proton is down is the outage's"""
    status = subprocess.run([PROBE]).returncode
    if status != 0:
        raise Outage(status)


def transfer_timeout(size):
    return CALL_TIMEOUT + size // MIN_TRANSFER_RATE


def children_parse(out):
    """a `list -j` answer -> ({name: Node}, names to leave alone: undecryptable, ambiguous or of another type)"""
    nodes, murky = {}, set()
    for item in json.loads(out):
        label = item.get("name") or {}
        name = label.get("value")
        if not label.get("ok") or not name or "/" in name:
            log(f"a remote item with an undecryptable name or one holding '/' is left alone: {item.get('uid')}")
            continue
        if excluded(name):
            continue
        kind = item.get("type")
        if kind == "folder":
            node = Node("d")
        elif kind == "file":
            revision = item.get("activeRevision") or {}
            size = revision.get("claimedSize")
            mtime = revision.get("claimedModificationTime") or item["modificationTime"]
            sha1 = (revision.get("claimedDigests") or {}).get("sha1")
            node = Node("f", size if isinstance(size, int) else -1, ms_of_iso(mtime), revision.get("uid"), sha1)
        else:
            log(f"remote {name} is a {kind}, neither file nor folder: left alone")
            murky.add(name)
            continue
        if name in nodes or name in murky:
            log(f"remote {name} is there twice: left alone")
            nodes.pop(name, None)
            murky.add(name)
            continue
        nodes[name] = node
    return nodes, murky


def entry_local(entry):
    if entry is None:
        return None
    return Node("f", entry["ls"], entry["lm"]) if entry["t"] == "f" else Node("d")


def entry_remote(entry):
    if entry is None:
        return None
    return Node("f", entry["rs"], entry["rm"], entry["rr"]) if entry["t"] == "f" else Node("d")


def local_changed(node, entry):
    return node != entry_local(entry)


def remote_changed(node, entry):
    known = entry_remote(entry)
    if node is None or known is None or node.kind != known.kind:
        return node != known
    if node.kind == "d":
        return False
    if node.rev and known.rev and node.rev != known.rev:
        return True
    return (node.size, node.mtime) != (known.size, known.mtime)


def file_entry(local, remote):
    return {"t": "f", "ls": local.size, "lm": local.mtime, "rs": remote.size, "rm": remote.mtime, "rr": remote.rev}


def dir_entry(listed):
    return {"t": "d", "listed": listed, "hot": 0}


def owner_ids():
    return pwd.getpwnam(OWNER_USER).pw_uid, grp.getgrnam(OWNER_GROUP).gr_gid


def makedirs_owned(path, ids):
    """creates path and its missing parents as the folder owner's, DIR_MODE"""
    missing = []
    while not os.path.isdir(path):
        missing.append(path)
        path = os.path.dirname(path)
    for folder in reversed(missing):
        os.mkdir(folder)
        os.chown(folder, *ids)
        os.chmod(folder, DIR_MODE)


def trash_prune(now):
    """deletes the day folders of TRASH older than TRASH_DAYS"""
    if not os.path.isdir(TRASH):
        return
    for entry in os.scandir(TRASH):
        try:
            day = time.mktime(time.strptime(entry.name, "%Y-%m-%d"))
        except ValueError:
            continue
        if now - day > TRASH_DAYS * 86400:
            log(f"pruning {entry.path}, older than {TRASH_DAYS} days")
            shutil.rmtree(entry.path)


class Run:
    def __init__(self, resync, entries):
        self.resync = resync
        self.entries = entries
        self.now = int(time.time())
        self.ids = owner_ids()
        self.local = {}
        # remote folder -> its children, for the folders this run listed; absent: folders known not to be on proton
        self.listed = {}
        self.murky = {}
        self.absent = set()
        self.local_changed_dirs = set()
        self.remote_changed_dirs = set()
        self.forgotten = set()
        self.failures = 0
        self.counts = dict.fromkeys(
            ["listed", "agreed", "uploaded", "downloaded", "conflicts", "folders", "trashed", "quarantined"], 0
        )
        self.mkdirs_local, self.downloads, self.mkdirs_remote, self.uploads = [], [], [], []
        self.trashes, self.quarantines = [], []
        # NFC form -> the paths on either side holding it
        self.forms = {}
        self.saved_at = time.monotonic()

    def save(self):
        if self.forgotten:
            self.entries = {
                rel: e
                for rel, e in self.entries.items()
                if rel not in self.forgotten and not any(a in self.forgotten for a in ancestors(rel))
            }
            self.forgotten.clear()
        tmp = STATE_FILE + ".tmp"
        with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
            json.dump({"version": STATE_VERSION, "entries": self.entries}, f, separators=(",", ":"))
        os.replace(tmp, STATE_FILE)
        self.saved_at = time.monotonic()

    def checkpoint(self):
        if time.monotonic() - self.saved_at > SAVE_SECONDS:
            self.save()

    def fail(self, message, folder=None):
        """a failed item: the run fails, and its folder is listed first next time"""
        log(f">>> {message}")
        self.failures += 1
        if folder and self.entries.get(folder, {}).get("t") == "d":
            self.entries[folder]["listed"] = 0

    def forget(self, rel):
        self.entries.pop(rel, None)
        self.forgotten.add(rel)

    def hot(self, rel):
        folder = self.entries.get(parent(rel))
        if not self.resync and folder and folder["t"] == "d":
            folder["hot"] = self.now

    def root_check(self):
        above, name = REMOTE.rsplit("/", 1)
        ok, out, err = cli("list", "-j", above)
        if not ok:
            outage_check()
            raise Refused(f"cannot list {above}, which holds the remote root: {short(err)}")
        nodes, _ = children_parse(out)
        if nodes.get(name, Node("?")).kind != "d":
            raise Refused(
                f"the remote root {REMOTE} is missing: refusing to sync (FEATURES.md, Storage, backups and off-site)"
            )

    def list_folder(self, folder, quiet=False):
        ok, out, err = cli("list", "-j", remote_path(folder))
        if ok:
            try:
                self.listed[folder], self.murky[folder] = children_parse(out)
            except (ValueError, KeyError, TypeError, AttributeError) as e:
                ok, err = False, f"unreadable listing: {e}"
        if not ok:
            outage_check()
            if not quiet:
                self.fail(f"cannot list {remote_path(folder)}: {short(err)}", folder)
            return False
        self.counts["listed"] += 1
        if folder in self.entries:
            self.entries[folder]["listed"] = self.now
        return True

    def is_absent(self, rel):
        return rel in self.absent or any(a in self.absent for a in ancestors(rel))

    def presence(self, folder):
        """whether remote folder is there, from its parent's listing; None when that is unknown"""
        above, name = parent(folder), basename(folder)
        if not self.ensure(above):
            return None
        if self.is_absent(above):
            return False
        if name in self.murky[above]:
            return None
        return self.listed[above].get(name, Node("?")).kind == "d"

    def ensure(self, folder):
        """makes the remote children of folder known (listed, or absent with it); False when that failed"""
        if folder in self.listed or self.is_absent(folder):
            return True
        if not folder:
            return self.list_folder(folder)
        # a folder the state knows lists without its parent; a failure leaves the parent to say whether it is there
        known = self.entries.get(folder, {}).get("t") == "d"
        if known and parent(folder) not in self.listed and self.list_folder(folder, quiet=True):
            return True
        there = self.presence(folder)
        if there is None:
            return False
        if not there:
            self.absent.add(folder)
            return True
        return self.list_folder(folder)

    def priority(self, folder):
        entry = self.entries[folder]
        if not entry["listed"]:
            return -1
        boost = HOT_BOOST if self.now - entry.get("hot", 0) < HOT_DAYS * 86400 else 0
        return entry["listed"] - boost

    def sweep(self):
        """lists folders, the longest unread first, until SWEEP_SECONDS are spent (resync: all of them)"""
        deadline = float("inf") if self.resync else time.monotonic() + SWEEP_SECONDS
        queue = [(self.priority(rel), rel) for rel, e in self.entries.items() if e["t"] == "d"]
        queue += [
            (-1, join(folder, name))
            for folder, kids in self.listed.items()
            for name, node in kids.items()
            if node.kind == "d" and join(folder, name) not in self.entries
        ]
        heapq.heapify(queue)
        while queue and time.monotonic() < deadline:
            _, folder = heapq.heappop(queue)
            if folder in self.listed or self.is_absent(folder) or not self.ensure(folder) or self.is_absent(folder):
                continue
            # a folder new on proton: what it holds is new too, so it is read in this run
            for name, node in self.listed[folder].items():
                if node.kind == "d" and join(folder, name) not in self.entries:
                    heapq.heappush(queue, (-1, join(folder, name)))
        unread = sum(1 for e in self.entries.values() if e["t"] == "d" and e["listed"] < self.now)
        log(f"listed {self.counts['listed']} remote folders; {unread} known ones wait for a later run")

    def remote_view(self, rel):
        above, name = parent(rel), basename(rel)
        if above in self.listed:
            return UNKNOWN if name in self.murky[above] else self.listed[above].get(name)
        if self.is_absent(above):
            return None
        # a folder its parent's listing lacks holds nothing, and neither does a file
        up = self.remote_view(above)
        if up is None or (up is not UNKNOWN and up.kind != "d"):
            self.absent.add(above)
            return None
        return UNKNOWN

    def changes_mark(self):
        """the folders holding a local change, and every folder whose remote side must be read for it"""
        for rel in set(self.local) | set(self.entries):
            node = self.local.get(rel)
            if local_changed(node, self.entries.get(rel)):
                if node is not None:
                    self.local_changed_dirs.update(ancestors(rel))
                # a change below a folder deleted here is that folder's, whose parent this reads
                above = parent(rel)
                if not above or self.local.get(above) == Node("d"):
                    self.ensure(above)

    def remote_changes_mark(self):
        for folder, kids in self.listed.items():
            for name, node in kids.items():
                rel = join(folder, name)
                if remote_changed(node, self.entries.get(rel)):
                    self.remote_changed_dirs.update(ancestors(rel))

    def same(self, rel, local, remote):
        if local.size != remote.size:
            return False
        return local.mtime == remote.mtime or (remote.sha1 is not None and sha1_of(local_path(rel)) == remote.sha1)

    def conflict_name(self, rel):
        folder, name = parent(rel), basename(rel)
        stem, dot, ext = name[1:].rpartition(".")
        stem, ext = (name[0] + stem, dot + ext) if dot else (name, "")
        taken = set(self.listed.get(folder, {})) | self.murky.get(folder, set())
        n = 1
        while True:
            candidate = join(folder, f"{stem}.{CONFLICT_SUFFIX}{n if n > 1 else ''}{ext}")
            if candidate not in self.local and candidate not in self.entries and basename(candidate) not in taken:
                self.local[candidate] = None
                return candidate
            n += 1

    def twin(self, rel):
        """a path beside rel differing from it only in unicode normalization, or None"""
        return next((other for other in self.forms.get(nfc(rel), ()) if other != rel), None)

    def decide(self, rel, local, entry, remote, lchg, rchg):
        """queues what rel needs; True when that covers its whole subtree"""
        deletes = entry is not None and not self.resync
        if (local is None) != (remote is None) and (twin := self.twin(rel)) is not None:
            self.fail(f"{rel!a} and {twin!a} differ only in unicode normalization: rename one of them", parent(rel))
            return True
        if local is None and remote is None:
            self.forget(rel)
        elif local is None:
            if deletes and not rchg and rel not in self.remote_changed_dirs:
                self.trashes.append(rel)
                return True
            if remote.kind == "d":
                self.mkdirs_local.append(rel)
            else:
                self.downloads.append((rel, remote, rel))
        elif remote is None:
            if deletes and not lchg and rel not in self.local_changed_dirs:
                self.quarantines.append(rel)
                return True
            if local.kind == "d":
                self.mkdirs_remote.append(rel)
            elif local.kind == "f":
                self.uploads.append(rel)
        elif local.kind != remote.kind:
            self.fail(
                f"{rel} is a {KIND_NAMES[local.kind]} here and a {KIND_NAMES[remote.kind]} on proton: "
                "rename one of them",
                parent(rel),
            )
            return True
        elif local.kind == "d":
            self.entries[rel] = dir_entry(self.now if rel in self.listed else 0)
        elif self.same(rel, local, remote):
            self.entries[rel] = file_entry(local, remote)
            self.counts["agreed"] += 1
        elif lchg and not rchg:
            self.uploads.append(rel)
        elif rchg and not lchg:
            self.downloads.append((rel, remote, rel))
        else:
            self.downloads.append((rel, remote, self.conflict_name(rel)))
        return False

    def plan(self):
        paths = set(self.local) | set(self.entries)
        paths.update(join(folder, name) for folder, kids in self.listed.items() for name in kids)
        for rel in set(self.local) | {join(folder, name) for folder, kids in self.listed.items() for name in kids}:
            self.forms.setdefault(nfc(rel), set()).add(rel)
        skip = None
        for rel in sorted(paths, key=path_key):
            if skip is not None and under(rel, skip):
                continue
            skip = None
            local, entry, remote = self.local.get(rel), self.entries.get(rel), self.remote_view(rel)
            lchg = local_changed(local, entry)
            if remote is UNKNOWN:
                if lchg:
                    self.fail(f"{rel} changed here, but its proton folder could not be read; next run", parent(rel))
                    skip = rel
                continue
            rchg = remote_changed(remote, entry)
            if not lchg and not rchg:
                if remote is not None and remote.rev and entry["t"] == "f" and not entry["rr"]:
                    entry["rr"] = remote.rev
                continue
            if self.decide(rel, local, entry, remote, lchg, rchg):
                skip = rel

    def guard(self):
        """refuses a run that deletes past MAX_DELETE_PERCENT of the entries on either side"""
        subtree = {}
        for rel in self.entries:
            for folder in ancestors(rel):
                subtree[folder] = subtree.get(folder, 0) + 1
        tripped = False
        for side, rels in (("on proton", self.trashes), ("here", self.quarantines)):
            count = sum(1 + subtree.get(rel, 0) for rel in rels)
            if count and count * 100 > len(self.entries) * MAX_DELETE_PERCENT:
                log(
                    f">>> this run would delete {count} of {len(self.entries)} entries {side}, over "
                    f"{MAX_DELETE_PERCENT}%: {', '.join(rels[:10])}"
                )
                tripped = True
        if tripped and not ALLOW_LARGE:
            raise Guard()

    def each_batch(self, items, run):
        """run(batch) per BATCH_COUNT items; a failed batch is retried item by item"""
        for i in range(0, len(items), BATCH_COUNT):
            batch = items[i : i + BATCH_COUNT]
            if not run(batch) and len(batch) > 1:
                for item in batch:
                    run([item])
            self.checkpoint()

    def mkdir_local(self, rel):
        try:
            makedirs_owned(local_path(rel), self.ids)
        except OSError as e:
            self.fail(f"cannot create {local_path(rel)}: {e}", parent(rel))
            return
        log(f"folder here: {rel}")
        self.entries[rel] = dir_entry(self.now if rel in self.listed else 0)
        self.counts["folders"] += 1
        self.hot(rel)

    def place(self, rel, remote, target, got):
        """moves a downloaded file into place as the owner's, with the remote mtime"""
        node = local_node(got)
        if node is None or node.kind != "f" or (remote.size >= 0 and node.size != remote.size):
            self.fail(f"download of {rel} came as {node}, not a file of {remote.size} bytes", parent(rel))
            return
        os.chown(got, *self.ids)
        os.chmod(got, FILE_MODE)
        os.utime(got, ns=(remote.mtime * NS_PER_MS, remote.mtime * NS_PER_MS))
        dest = local_path(target)
        if local_node(dest) != self.local.get(target):
            log(f"{target} changed here during the run: next run")
            return
        try:
            os.replace(got, dest)
        except OSError as e:
            self.fail(f"cannot place {dest}: {e}", parent(rel))
            return
        placed = local_node(dest)
        self.local[target] = placed
        if target == rel:
            log(f"down: {rel}")
            self.entries[rel] = file_entry(placed, remote)
            self.counts["downloaded"] += 1
            self.hot(rel)
            return
        # both versions go up next; until then the entry holds the remote version and a local one that never was
        log(f"conflict: {rel} changed on both sides; proton's version is now {target} on both")
        self.entries[rel] = file_entry(Node("f", -1, -1), remote)
        self.uploads += [rel, target]
        self.counts["conflicts"] += 1

    def download(self, batch):
        size = sum(max(remote.size, 0) for _, remote, _ in batch)
        os.makedirs(STAGING, exist_ok=True)
        if free_bytes(STAGING) - size < reserve_bytes(STAGING):
            if len(batch) == 1:
                self.fail(
                    f"download of {batch[0][0]} ({size} bytes) would leave less than {FREE_RESERVE_PERCENT}% of "
                    f"{STAGING}'s file system free: next run",
                    parent(batch[0][0]),
                )
            return False
        staging = os.path.join(STAGING, str(time.time_ns()))
        os.makedirs(staging)
        ok, _, err = cli(
            "download",
            "-f",
            "remove",
            *(remote_path(rel) for rel, _, _ in batch),
            staging,
            timeout=transfer_timeout(size),
        )
        if ok:
            for rel, remote, target in batch:
                self.place(rel, remote, target, os.path.join(staging, basename(rel)))
        else:
            outage_check()
            if len(batch) == 1:
                self.fail(f"download of {batch[0][0]} failed: {short(err)}", parent(batch[0][0]))
        shutil.rmtree(staging, ignore_errors=True)
        return ok

    def mkdir_remote(self, rel):
        if not self.remote_has(parent(rel)):
            self.fail(f"{rel}: its proton folder is missing", parent(rel))
            return
        ok, _, err = cli("create-folder", remote_path(parent(rel)), basename(rel))
        if not ok:
            outage_check()
            self.fail(f"cannot create {remote_path(rel)}: {short(err)}", parent(rel))
            return
        log(f"folder on proton: {rel}")
        self.entries[rel] = dir_entry(self.now)
        self.counts["folders"] += 1
        self.hot(rel)

    def remote_has(self, folder):
        return not folder or self.entries.get(folder, {}).get("t") == "d"

    def upload(self, batch):
        files = []
        for rel in batch:
            node = local_node(local_path(rel))
            if node is not None and node.kind == "f":
                files.append((rel, node))
            else:
                log(f"{rel} went away here before its upload: next run")
        if not files:
            return True
        folder = parent(batch[0])
        ok, _, err = cli(
            "upload",
            "-j",
            "-f",
            "create-new-revision",
            "-t",
            *(glob_literal(local_path(rel)) for rel, _ in files),
            remote_path(folder),
            timeout=transfer_timeout(sum(node.size for _, node in files)),
        )
        if not ok:
            outage_check()
            if len(batch) == 1:
                self.fail(f"upload of {batch[0]} failed: {short(err)}", folder)
            return False
        for rel, node in files:
            log(f"up: {rel}")
            # the cli keeps the local mtime (ms) as the claimed modification time
            self.entries[rel] = file_entry(node, node)
            self.counts["uploaded"] += 1
            self.hot(rel)
        return True

    def trash(self, batch):
        cli_ok, out, err = cli("trash", "-j", *(remote_path(rel) for rel in batch))
        try:
            ok = cli_ok and all(item.get("ok") for item in json.loads(out))
        except (ValueError, AttributeError):
            ok = False
        if not ok:
            outage_check()
            if len(batch) > 1:
                return False
            # a refused item is told in the listing on stdout, a failed call in the error text
            detail = out if cli_ok else err
            if GONE not in detail:
                self.fail(f"cannot trash {remote_path(batch[0])}: {short(detail)}", parent(batch[0]))
                return False
        for rel in batch:
            log(f"trashed on proton: {rel}")
            self.forget(rel)
            self.counts["trashed"] += 1
            self.hot(rel)
        return True

    def quarantine(self, rel):
        src = local_path(rel)
        if local_node(src) != self.local.get(rel):
            log(f"{rel} changed here during the run: next run")
            return
        dest = os.path.join(TRASH, time.strftime("%Y-%m-%d"), rel)
        try:
            makedirs_owned(os.path.dirname(dest), self.ids)
            if os.path.lexists(dest):
                dest += f".{time.time_ns()}"
            os.rename(src, dest)
        except OSError as e:
            self.fail(f"cannot move {src} to {dest}: {e}", parent(rel))
            return
        log(f"deleted on proton, moved to {dest}")
        self.forget(rel)
        self.counts["quarantined"] += 1
        self.hot(rel)

    def apply(self):
        for rel in self.mkdirs_local:
            self.mkdir_local(rel)
        shutil.rmtree(STAGING, ignore_errors=True)
        for _, items in groupby(self.downloads, key=lambda d: parent(d[0])):
            self.each_batch(list(items), self.download)
        for rel in self.mkdirs_remote:
            self.mkdir_remote(rel)
            self.checkpoint()
        uploads = sorted(set(self.uploads), key=path_key)
        for folder, items in groupby(uploads, key=parent):
            items = list(items)
            if self.remote_has(folder):
                self.each_batch(items, self.upload)
            else:
                self.fail(f"{len(items)} files of {folder} wait for their proton folder", folder)
        self.each_batch(self.trashes, self.trash)
        for rel in self.quarantines:
            self.quarantine(rel)
        self.checkpoint()

    def go(self):
        self.root_check()
        trash_prune(self.now)
        self.local = local_scan()
        if not self.ensure(""):
            raise Refused(f"cannot list the remote root {REMOTE}")
        self.changes_mark()
        self.sweep()
        self.remote_changes_mark()
        self.plan()
        self.guard()
        self.apply()


def stop(signum, _frame):
    raise Stop(signal.Signals(signum).name)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("sync", "resync"):
        print("usage: proton-bisync-engine sync|resync", file=sys.stderr)
        return 2
    resync = sys.argv[1] == "resync"
    try:
        with open(STATE_FILE) as f:
            entries = json.load(f)["entries"]
    except FileNotFoundError:
        # proton-bisync.nu refuses a sync without its baseline
        if not resync:
            raise
        entries = {}
    os.umask(0o022)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    run = Run(resync, entries)
    try:
        run.go()
    except Refused as e:
        log(str(e))
        return EXIT_FAILED
    except Guard:
        return EXIT_GUARD
    except Outage as e:
        run.save()
        log("proton went down mid-run; the state keeps what was done")
        return e.args[0]
    except Stop as e:
        run.save()
        log(f"stopped by {e}; the next run resumes")
        return EXIT_FAILED
    run.save()
    log(", ".join(f"{name} {count}" for name, count in run.counts.items()) + f", failures {run.failures}")
    return EXIT_FAILED if run.failures else 0


if __name__ == "__main__":
    sys.exit(main())
