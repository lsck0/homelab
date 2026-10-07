"""zones.py: the router's forward policy, stated as the owner means it, for tests/router-zones.nix.

Written from the policy, not from the nftables the router renders (modules/flows.nix, instances/300-router/main.nix):
if the two disagree, one of them is wrong, and the test says which probe showed it. The only inputs taken from the
lab are the ones the claim itself is about: which guests vm-109 exports to (nas clients), which ports the enabled
swarm apps publish, who leaves through the vpn exit, and which worker holds the apps' state.

    oracle = ZoneOracle(facts)        # facts: {"nasClients", "appsPorts", "vpnMembers", "appsNodes", "stateWorker"}
    expect, seen_src = oracle.forward("10.200.0.203", "10.100.0.109", "tcp", 2049)

expect is "open" or "closed" (labprobe's vocabulary); seen_src is the source the destination sees: the router's wan
address when the path leaves through the house (masquerade), the probe's own source otherwise.
"""

import ipaddress

# -----------------------------------------------------------------------------
# CONSTANTS: the lab as the owner describes it
# -----------------------------------------------------------------------------

ROUTER_WAN = "192.168.178.29"
WORKSTATION = "192.168.178.138"
PROXMOX = "192.168.178.200"
NETWORKS = {
    "internal": ipaddress.ip_network("10.100.0.0/24"),
    "dmz": ipaddress.ip_network("10.200.0.0/24"),
    "apps": ipaddress.ip_network("10.250.0.0/24"),
    "lan": ipaddress.ip_network("192.168.178.0/24"),
}
PRIVATE = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]

INGRESS = "10.100.0.100"
COLLECTOR = "10.100.0.105"
NAS = "10.100.0.109"
MANAGER = "10.100.0.140"
EDGE = "10.200.0.200"

NFS_PORTS = (111, 2049)
# the push door; the query api (3100) is for named readers only
LOKI_PUSH = 3102
JOURNAL = 19532
OTLP = 4317
OTLP_HTTP = 4318
OTLP_FRONTEND = 4319
PYROSCOPE = 4040
# the swarm controller on the manager: ci's redeploy through the edge's public deploy route, the state worker's wakes
CONTROLLER = 8095
HTTPS = 443
SSH = 22
PROXMOX_API = 8006
SWARM_TCP = (2377, 7946)
SWARM_UDP = (7946, 4789)

# -----------------------------------------------------------------------------
# FUNCTIONS
# -----------------------------------------------------------------------------


def network_of(address):
    """internal, dmz, apps, lan, or internet for anything public."""
    ip = ipaddress.ip_address(address)
    for name, net in NETWORKS.items():
        if ip in net:
            return name
    if any(ip in net for net in PRIVATE):
        return "other-private"
    return "internet"


class ZoneOracle:
    def __init__(self, facts):
        self.nas_clients = set(facts["nasClients"])
        self.apps_ports = set(facts["appsPorts"])
        self.vpn_members = set(facts["vpnMembers"])
        self.apps_nodes = set(facts["appsNodes"])
        self.state_worker = facts["stateWorker"]

    def _dmz_allows(self, src, dst, proto, port):
        tcp = proto == "tcp"
        return (
            (src == EDGE and dst == INGRESS and tcp and port == HTTPS)
            or (src == EDGE and dst == COLLECTOR and tcp and port in (LOKI_PUSH, OTLP_FRONTEND))
            or (src == EDGE and dst == MANAGER and tcp and port == CONTROLLER)
            or (dst == COLLECTOR and tcp and port == JOURNAL)
            or (src in self.nas_clients and dst == NAS and proto in ("tcp", "udp") and port in NFS_PORTS)
            or (src == EDGE and dst == PROXMOX and tcp and port == PROXMOX_API)
            or (src == EDGE and dst in self.apps_nodes and tcp and port in self.apps_ports)
        )

    def _apps_allows(self, src, dst, proto, port):
        tcp = proto == "tcp"
        return (
            (dst == INGRESS and tcp and port == HTTPS)
            or (dst == COLLECTOR and tcp and port in (JOURNAL, OTLP, OTLP_HTTP, PYROSCOPE, LOKI_PUSH))
            or (dst == MANAGER and ((tcp and port in SWARM_TCP) or (proto == "udp" and port in SWARM_UDP) or proto == "esp"))
            or (src == self.state_worker and dst == MANAGER and tcp and port == CONTROLLER)
            or (src in self.nas_clients and dst == NAS and proto in ("tcp", "udp") and port in NFS_PORTS)
        )

    def forward(self, src, dst, proto, port):
        """What a connection from src to dst (through the router) does: (expect, seen_src)."""
        zs, zd = network_of(src), network_of(dst)
        assert zs != zd, f"{src} -> {dst} does not cross the router"
        leaves_through_house = zd in ("lan", "internet")
        seen = ROUTER_WAN if leaves_through_house and zs in ("internal", "dmz", "apps") else src
        # the vpn exit is offline in the lab: a member's internet traffic dies in the killswitch
        if src in self.vpn_members and zd == "internet":
            return "closed", None
        if zs == "internal":
            return "open", seen
        if zs == "lan":
            if zd in ("internal", "dmz"):
                return "open", seen
            if zd == "apps" and src == WORKSTATION and proto == "tcp" and port == SSH:
                return "open", seen
            return "closed", None
        if zs == "internet":
            # only the port forwards, which go to the router's own address and are checked separately
            return "closed", None
        if zs == "dmz":
            if self._dmz_allows(src, dst, proto, port):
                return "open", seen
            return ("open", seen) if zd == "internet" else ("closed", None)
        if zs == "apps":
            if self._apps_allows(src, dst, proto, port):
                return "open", seen
            return ("open", seen) if zd == "internet" else ("closed", None)
        raise AssertionError(f"no policy for a source in {zs}: {src}")
