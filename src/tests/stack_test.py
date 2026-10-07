"""stack.sh over the real instance files: every phase and state touches only that phase's guest files, and status, read
from the collector again, then reports the wanted state for each of them. Run by tests/stack.nix:
stack_test.py <dir with src/>."""

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PHASES = ("apps", "media", "public")
STATES = ("on", "off")


def guest_files(src):
    """file (relative to src) -> (boot phase, text) for every guest file stack.sh edits."""
    files = [p for p in sorted((src / "instances").glob("*/instance.nix")) if not p.parent.name.startswith("_")]
    files.append(src / "apps/swarm.nix")
    return {str(p.relative_to(src)): (re.search(r'bootPhase\s*=\s*"([^"]+)"', p.read_text()).group(1), p.read_text())
            for p in files}


def status_name(file):
    """the name stack.sh's status prints for a guest file."""
    return file if file == "apps/swarm.nix" else Path(file).parent.name


def stack(root, *args):
    return subprocess.run(["bash", str(root / "src/scripts/stack.sh"), *args], capture_output=True, text=True)


def main():
    fixture = Path(sys.argv[1])
    before = guest_files(fixture / "src")
    assert before, "no guest files"
    checked = 0
    for phase in PHASES:
        for state in STATES:
            root = Path(tempfile.mkdtemp())
            shutil.copytree(fixture / "src", root / "src")
            for path in (root / "src").rglob("*"):
                path.chmod(0o755 if path.is_dir() else 0o644)
            run = stack(root, phase, state, "--apply")
            assert run.returncode == 0, f"{phase} {state}: {run.stderr}"
            after = guest_files(root / "src")
            assert after.keys() == before.keys(), f"{phase} {state}: guests appeared or vanished"
            for file, (p, text) in before.items():
                if p != phase:
                    assert after[file][1] == text, f"{phase} {state}: touched {file} of phase {p}"
            status = stack(root, "status")
            assert status.returncode == 0, status.stderr
            for file, (p, _) in before.items():
                if p == phase:
                    line = next(l for l in status.stdout.splitlines() if l.split()[:1] == [status_name(file)])
                    assert state in line.split(), f"{phase} {state}: {file} reports {line}"
            assert stack(root, phase, state, "--apply").stdout.endswith("nothing to change.\n"), "not idempotent"
            checked += 1
            print(f"ok: {phase} {state}: only {phase}'s guests changed, all now {state}")
    dry = stack(fixture, "public", "off")
    assert dry.returncode == 0 and guest_files(fixture / "src") == before, "a dry run wrote"
    assert stack(fixture, "public", "of").returncode == 2, "a typo was accepted"
    assert stack(fixture, "public", "off", "--aply").returncode == 2, "an unknown flag was accepted"
    print(f"stack: {checked} phase and state combinations hold; dry run and bad input change nothing")


main()
