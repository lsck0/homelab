# lib/probe.py: the test driver's side of labprobe (lib/labprobe.py), prepended to a testScript by lab.testScript
#
# A test states its policy as a plan and lets labprobe check it: sinks listen on the destinations, every source
# machine sends its probes, the driver joins the results with every sink's log and fails on the first mismatch,
# printing all of them. Every negative needs its positive control in the same plan: the same listener reached from
# an allowed source.
#
#     probe_sinks_start([vm_121, vm_203], tcp=(22, 8080), udp=(53,), esp=True)
#     probe_check([
#         {"src": "10.100.0.121", "dst": "10.200.0.203", "proto": "tcp", "port": 8080, "expect": "open"},
#         {"src": "10.200.0.203", "dst": "10.100.0.121", "proto": "tcp", "port": 8080, "expect": "closed"},
#     ], sources={"10.100.0.121": vm_121, "10.200.0.203": vm_203}, sinks=[vm_121, vm_203], seed=SEED)
#
# expect is one of open, closed, refused, filtered, unreachable; "seen_src" names the source a sink must see when
# the path rewrites it (masquerade). "via" names an entry of `runners`, a command prefix the source machine runs
# labprobe under: another user (`runuser -u ci --`), or a container (`docker run -v /var/lib/labprobe:/var/lib/labprobe
# ... labprobe:test`, src 0.0.0.0, seen_src the host's address); its plan and results live in PROBE_DIR_VIA/via-<via>,
# which that identity can write.
# LABPROBE is the store path lab.testScript fills in.
import json
import os
import subprocess
import tempfile

PROBE_SINK_LOG = "/run/labprobe/sink.jsonl"
PROBE_DIR_VM = "/run/labprobe"
# a runner's plan and results: not under /run or /etc, which a rootless docker daemon copies up at its start
PROBE_DIR_VIA = "/var/lib/labprobe"
PROBE_STATE = {"next_id": 0}


def probe_sinks_start(sinks: list[Machine], tcp: tuple[int, ...] = (), udp: tuple[int, ...] = (),
                      esp: bool = False) -> None:
    """Start `labprobe sink` on every machine, as a transient unit, and wait until all listeners are bound."""
    ports = (f" --tcp {','.join(map(str, tcp))}" if tcp else "") + (f" --udp {','.join(map(str, udp))}" if udp else "")
    ports += " --esp" if esp else ""
    for machine in sinks:
        # a transient unit runs with systemd's PATH: the binary by its resolved path
        machine.succeed(f'systemd-run --unit=labprobe-sink "$(command -v labprobe)" sink{ports} --log {PROBE_SINK_LOG}')
    for machine in sinks:
        machine.wait_for_file(f"{PROBE_SINK_LOG}.ready", timeout=60)


def probe_check(plan: list[dict], sources: dict[str, Machine], sinks: list[Machine], seed: int,
                timeout_ms: int = 700, runners: dict[str, str] | None = None) -> None:
    """Run every probe from its source machine and assert every expectation; ids are assigned here."""
    commands: dict[str, str] = runners or {}
    probes = []
    for entry in plan:
        probes.append({"id": f"p{PROBE_STATE['next_id']}", **entry})
        PROBE_STATE["next_id"] += 1
    host_dir = tempfile.mkdtemp(prefix="labprobe-")
    results: dict[str, str] = {}
    for src, via in sorted({(p["src"], p.get("via", "")) for p in probes}):
        assert src in sources, f"probe_check: no machine owns source {src}"
        assert not via or via in commands, f"probe_check: no runner {via}"
        plan_path = os.path.join(host_dir, "plan.json")
        with open(plan_path, "w", encoding="utf-8") as f:
            json.dump([p for p in probes if p["src"] == src and p.get("via", "") == via], f)
        machine = sources[src]
        vm_dir = f"{PROBE_DIR_VIA}/via-{via}" if via else PROBE_DIR_VM
        # another identity writes its results here: sticky and world-writable, like /tmp
        machine.succeed(f"mkdir -p {vm_dir} && chmod 1777 {vm_dir} && rm -f {vm_dir}/results.json")
        machine.copy_from_host(plan_path, f"{vm_dir}/plan.json")
        machine.succeed(f"chmod 0644 {vm_dir}/plan.json")
        prefix = f"{commands[via]} " if via else ""
        machine.succeed(f"{prefix}labprobe run --plan {vm_dir}/plan.json --out {vm_dir}/results.json "
                        f"--seed {seed} --timeout-ms {timeout_ms}")
        results.update(json.loads(machine.succeed(f"cat {vm_dir}/results.json")))
    log_paths = []
    for index, machine in enumerate(sinks):
        log_path = os.path.join(host_dir, f"sink-{index}.jsonl")
        with open(log_path, "w", encoding="utf-8") as f:
            f.write(machine.succeed(f"cat {PROBE_SINK_LOG}"))
        log_paths.append(log_path)
    with open(os.path.join(host_dir, "all.json"), "w", encoding="utf-8") as f:
        json.dump(probes, f)
    with open(os.path.join(host_dir, "results.json"), "w", encoding="utf-8") as f:
        json.dump(results, f)
    report = subprocess.run([LABPROBE, "expect", "--plan", os.path.join(host_dir, "all.json"),
                             "--results", os.path.join(host_dir, "results.json"), "--sink-logs", ",".join(log_paths)],
                            capture_output=True, text=True)
    print(report.stdout, end="")
    assert report.returncode == 0, f"probe_check: the lab does not match the plan\n{report.stdout}{report.stderr}"
