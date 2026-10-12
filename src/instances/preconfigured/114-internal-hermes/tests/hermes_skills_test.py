"""hermes' skills against the lab's facts: tokens, tools, secrets, units and addresses they name must exist, and
each skill's name is the one it is installed under, every related skill one that exists.

usage: hermes_skills_test.py <facts.json> <skills dir>

The facts come from the evaluated configurations (hermes-skills.nix). A line runs on the host it names, by
`ssh <address>` or as "on vm-<id>", and its continuation lines (after a trailing backslash) with it; any other
line runs on vm-114. A foreign host (the proxmox host) is no nixos host: its lines are not checked for units or
secrets. Placeholders (`<name>`) are skipped.
"""

import ipaddress
import json
import pathlib
import re
import sys

# -----------------------------------------------------------------------------
# CONSTANTS

TOKEN_RE = re.compile(r"lab-token ([a-z0-9][a-z0-9-]*)")
TOOL_RE = re.compile(r"(?<![\w/.-])(lab-[a-z][a-z0-9-]*)")
SECRET_RE = re.compile(r"/run/secrets/([A-Za-z0-9_.-]+)")
SSH_RE = re.compile(r"ssh (?:-\S+ (?:\S+ )?)*(\d+\.\d+\.\d+\.\d+)")
ON_VM_RE = re.compile(r"\bon vm-(\d+)\b")
UNIT_RE = re.compile(r"(?:systemctl (?:[a-z-]+ )*(?:--[a-z-]+ )*|journalctl (?:-[a-zA-Z]+ )*-[a-zA-Z]*u ?)"
                     r"([a-z][a-z0-9@._-]*)")
ADDRESS_RE = re.compile(r"(?<![\d.])(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(/\d{1,2})?(?!\.?\d)")
NAME_RE = re.compile(r"^name: (\S+)$", re.M)
RELATED_RE = re.compile(r"^\s*related_skills: \[([^\]]*)\]$", re.M)
# addresses that are no lab fact: loopback and the unspecified one
GENERIC_ADDRESSES = {"127.0.0.1", "0.0.0.0"}
# systemctl verbs and words that take no unit
SYSTEMCTL_WORDS = {"daemon-reload", "list-units", "list-timers", "--failed", "-n", "status"}


# -----------------------------------------------------------------------------
# FUNCTIONS

def facts_load(path):
    facts = json.loads(pathlib.Path(path).read_text())
    hosts = {h["address"]: h for h in facts["hosts"] if h["address"] is not None}
    router = next(h for h in facts["hosts"] if h["name"] == facts["routerName"])
    for address in facts["routerAddresses"]:
        hosts[address] = router
    assert facts["hermes"]["address"] in hosts, "the facts lack vm-114"
    return facts, hosts


def target_find(facts, hosts, line, carried):
    """the address of the host a line runs on, or the one carried from the line before"""
    ssh = SSH_RE.search(line)
    if ssh:
        return ssh.group(1)
    on_vm = ON_VM_RE.search(line)
    if on_vm:
        return facts["vmAddresses"].get(on_vm.group(1), f"vm-{on_vm.group(1)}")
    return carried or facts["hermes"]["address"]


def unit_known(host, unit):
    name = unit.removesuffix(".service")
    return name in host["units"] or unit in host["units"]


def line_check(facts, hosts, where, line, address):
    problems = []
    remote = address != facts["hermes"]["address"]
    target = hosts.get(address)
    for token in TOKEN_RE.findall(line):
        if token not in facts["tokens"]:
            problems.append(f"{where}: lab-token {token}: no guest exports it (modules/tokens)")
    # `lab-token` in an ssh line runs here, `lab-user` there: either path will do
    tools = facts["hermes"]["tools"] + (target or {}).get("tools", [])
    for tool in TOOL_RE.findall(line):
        if tool not in tools:
            problems.append(f"{where}: {tool} is on neither vm-114's path nor the path of the host the line runs on")
    if target is None:
        if address not in facts["foreignHosts"]:
            problems.append(f"{where}: {address} is no host of the lab")
        return problems
    for secret in SECRET_RE.findall(line):
        if secret not in target["secrets"]:
            problems.append(f"{where}: /run/secrets/{secret} is not declared on {target['name']}")
    if remote:
        for unit in UNIT_RE.findall(line):
            if unit in SYSTEMCTL_WORDS or unit.endswith("-"):
                continue
            if not unit_known(target, unit):
                problems.append(f"{where}: unit {unit} does not exist on {target['name']}")
    return problems


def address_check(facts, hosts, where, line):
    house = ipaddress.ip_network(facts["houseSubnet"])
    known = set(hosts) | set(facts["houseAddresses"]) | GENERIC_ADDRESSES | {str(house.broadcast_address)}
    problems = []
    for address, prefix in ADDRESS_RE.findall(line):
        if prefix:
            if f"{address}{prefix}" not in facts["subnets"]:
                problems.append(f"{where}: {address}{prefix} is no zone, wireguard or house subnet")
        elif address not in known:
            problems.append(f"{where}: {address} is no address of the lab")
    return problems


def frontmatter_check(path, names):
    text = path.read_text()
    where = f"{path.parent.name}/SKILL.md"
    problems = []
    name = NAME_RE.search(text)
    if name is None or name.group(1) != path.parent.name:
        problems.append(f"{where}: name is not {path.parent.name}, the name hermes installs it under")
    related = RELATED_RE.search(text)
    for other in related.group(1).split(", ") if related else []:
        if other not in names:
            problems.append(f"{where}: related skill {other} does not exist")
    return problems


def skills_check(facts, hosts, skills_dir):
    problems = []
    files = sorted(pathlib.Path(skills_dir).glob("*/SKILL.md"))
    assert files, f"no skills under {skills_dir}"
    names = {path.parent.name for path in files}
    for path in files:
        problems += frontmatter_check(path, names)
        carried = None
        for number, line in enumerate(path.read_text().splitlines(), start=1):
            where = f"{path.parent.name}/SKILL.md:{number}"
            address = target_find(facts, hosts, line, carried)
            problems += line_check(facts, hosts, where, line, address)
            problems += address_check(facts, hosts, where, line)
            carried = address if line.rstrip().endswith("\\") else None
    return files, problems


# -----------------------------------------------------------------------------
# MAIN

def main():
    facts, hosts = facts_load(sys.argv[1])
    files, problems = skills_check(facts, hosts, sys.argv[2])
    for problem in problems:
        print(f"FAIL {problem}")
    if problems:
        sys.exit(1)
    print(f"PASS {len(files)} skills name only tokens, tools, secrets, units and addresses the lab has")


if __name__ == "__main__":
    main()
