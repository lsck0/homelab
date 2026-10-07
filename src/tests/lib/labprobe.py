"""labprobe: reachability probes between lab test nodes, and the sinks that answer and record them.

Runs inside the test vms (packaged by lib/labprobe.nix); the test driver drives it through lib/probe.py.

    labprobe sink --tcp 22,80 --udp 53 --esp --log /run/labprobe/sink.jsonl
        listen on 0.0.0.0 for every port given; log one json line per probe that arrives:
        {"id", "proto", "src", "sport", "dst", "dport", "t"}. A tcp sink reads the probe id the client sends as its
        first line and answers "ok", a udp sink echoes the datagram, the esp sink records every packet. Traffic that
        carries no id (the lab's own, a journald upload) is logged with id null. Writes <log>.ready once every
        listener is bound; a port it cannot bind is an error, never a silent gap in the oracle.

    labprobe run --plan plan.json --out results.json [--seed N] [--timeout-ms 700] [--concurrency 512]
        send every probe {"id", "src", "dst", "proto", "port"} of the plan from its source address and write
        {"id": state} in plan order. States: open (the sink answered), foreign (something answered that is not a
        sink), refused (rst or icmp port unreachable), unreachable (icmp host, net or admin prohibited), filtered
        (no answer within the timeout), sent (esp: one-way, the sink log decides). The order in which probes go
        out is shuffled from the seed.

    labprobe expect --plan plan.json --results results.json --sink-logs a.jsonl,b.jsonl
        compare every probe's "expect" with what happened, print one line per mismatch, exit 1 if any.
        expect "open": the probe was answered (or, esp, logged) by a sink that saw it come from "seen_src"
        (default: the probe's own src; set it where the path masquerades). "closed": not open and no sink saw it
        (a udp probe whose request arrived but whose reply was dropped is a leak, not closed). "refused",
        "filtered", "unreachable": exactly that state, and no sink saw it.
"""

import argparse
import asyncio
import errno
import json
import os
import random
import re
import socket
import struct
import sys
import time

# -----------------------------------------------------------------------------
# CONSTANTS
# -----------------------------------------------------------------------------

PROTOS = ("tcp", "udp", "esp")
STATES = ("open", "foreign", "refused", "unreachable", "filtered", "sent")
EXPECTS = ("open", "closed", "refused", "filtered", "unreachable")
REPLY_OK = b"ok\n"
# a probe id: what probe.py assigns (p<n>), never the first line of real traffic such as an http request
ID_PATTERN = re.compile(rb"[A-Za-z0-9._:-]{1,64}")
# a sink waits this long for a probe id before logging the connection as id-less traffic
SINK_ID_TIMEOUT_S = 2.0
ESP_PROTO = 50
# esp header: spi and sequence number, then the probe id as payload
ESP_HEADER = struct.Struct("!II")
ESP_SPI_PROBE = 0x1AB0
UDP_DATAGRAM_BYTES_MAX = 2048
# struct in_pktinfo: interface index, local address, header destination address
IN_PKTINFO = struct.Struct("I4s4s")
IP_PACKET_BYTES_MAX = 65535
UNREACHABLE_ERRNOS = (errno.EHOSTUNREACH, errno.ENETUNREACH, errno.EACCES, errno.EPERM)


# -----------------------------------------------------------------------------
# INTERNAL
# -----------------------------------------------------------------------------


def json_load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def json_save(path, value):
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(value, f, indent=1)
    os.replace(tmp, path)


def ports_parse(text):
    if not text:
        return []
    ports = [int(p) for p in text.split(",") if p]
    for port in ports:
        if not 0 < port < 65536:
            raise SystemExit(f"labprobe: port {port} out of range")
    return ports


def plan_parse(plan):
    """Check every probe of a plan before anything is sent: a malformed plan is the test's bug."""
    seen = set()
    for probe in plan:
        for key in ("id", "src", "dst", "proto"):
            if key not in probe:
                raise SystemExit(f"labprobe: probe {probe} has no {key}")
        if probe["proto"] not in PROTOS:
            raise SystemExit(f"labprobe: probe {probe['id']}: unknown proto {probe['proto']}")
        if probe["proto"] != "esp" and not 0 < probe.get("port", 0) < 65536:
            raise SystemExit(f"labprobe: probe {probe['id']}: no valid port")
        if probe.get("expect", "open") not in EXPECTS:
            raise SystemExit(f"labprobe: probe {probe['id']}: unknown expect {probe['expect']}")
        if probe["id"] in seen:
            raise SystemExit(f"labprobe: probe id {probe['id']} twice")
        seen.add(probe["id"])
    return plan


def probe_id_parse(data):
    """The probe id a payload carries, or None for traffic that is not a probe."""
    data = data.strip()
    return data.decode("ascii") if ID_PATTERN.fullmatch(data) else None


def probe_render(probe):
    port = f":{probe['port']}" if probe["proto"] != "esp" else ""
    return f"{probe['id']} {probe['src']} -> {probe['dst']}{port}/{probe['proto']}"


# -----------------------------------------------------------------------------
# SINK
# -----------------------------------------------------------------------------


class SinkLog:
    def __init__(self, path):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self.file = open(path, "a", encoding="utf-8")

    def write(self, probe_id, proto, src, sport, dst, dport):
        entry = {"id": probe_id, "proto": proto, "src": src, "sport": sport, "dst": dst, "dport": dport,
                 "t": time.time()}
        self.file.write(json.dumps(entry) + "\n")
        self.file.flush()


def sink_tcp_handler(log):
    async def handle(reader, writer):
        src, sport = writer.get_extra_info("peername")[:2]
        dst, dport = writer.get_extra_info("sockname")[:2]
        probe_id = None
        try:
            probe_id = probe_id_parse(await asyncio.wait_for(reader.readline(), SINK_ID_TIMEOUT_S))
        except (asyncio.TimeoutError, ConnectionError):
            pass
        log.write(probe_id, "tcp", src, sport, dst, dport)
        try:
            if probe_id is not None:
                writer.write(REPLY_OK)
                await writer.drain()
            writer.close()
            await writer.wait_closed()
        except ConnectionError:
            pass

    return handle


def sink_udp_reader(log, sock, port):
    """Echo every datagram from the address it was sent to: a node owning many addresses must answer a probe of
    each from that one, or the prober's connected socket drops the reply. IP_PKTINFO names it both ways."""
    def read():
        data, ancillary, _, addr = sock.recvmsg(UDP_DATAGRAM_BYTES_MAX, socket.CMSG_SPACE(IN_PKTINFO.size))
        dst = None
        for level, kind, value in ancillary:
            if level == socket.IPPROTO_IP and kind == socket.IP_PKTINFO:
                dst = socket.inet_ntoa(IN_PKTINFO.unpack(value)[2])
        log.write(probe_id_parse(data), "udp", addr[0], addr[1], dst, port)
        source = [] if dst is None else [(socket.IPPROTO_IP, socket.IP_PKTINFO,
                                         IN_PKTINFO.pack(0, socket.inet_aton(dst), bytes(4)))]
        sock.sendmsg([data], source, 0, addr)

    return read


def sink_esp_reader(log, sock):
    def read():
        packet, _ = sock.recvfrom(IP_PACKET_BYTES_MAX)
        header_bytes = (packet[0] & 0x0F) * 4
        src = socket.inet_ntoa(packet[12:16])
        dst = socket.inet_ntoa(packet[16:20])
        log.write(probe_id_parse(packet[header_bytes + ESP_HEADER.size:]), "esp", src, None, dst, None)

    return read


async def sink_main(args):
    log = SinkLog(args.log)
    loop = asyncio.get_running_loop()
    for port in ports_parse(args.tcp):
        await asyncio.start_server(sink_tcp_handler(log), "0.0.0.0", port, reuse_address=True)
    for port in ports_parse(args.udp):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_PKTINFO, 1)
        sock.bind(("0.0.0.0", port))
        sock.setblocking(False)
        loop.add_reader(sock.fileno(), sink_udp_reader(log, sock, port))
    if args.esp:
        sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, ESP_PROTO)
        sock.setblocking(False)
        loop.add_reader(sock.fileno(), sink_esp_reader(log, sock))
    with open(f"{args.log}.ready", "w", encoding="utf-8") as f:
        f.write("ready\n")
    await asyncio.Event().wait()


# -----------------------------------------------------------------------------
# RUN
# -----------------------------------------------------------------------------


async def run_tcp(probe, timeout_s):
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(probe["dst"], probe["port"], local_addr=(probe["src"], 0)), timeout_s)
    except asyncio.TimeoutError:
        return "filtered"
    except ConnectionRefusedError:
        return "refused"
    except OSError as e:
        if e.errno in UNREACHABLE_ERRNOS:
            return "unreachable"
        raise
    try:
        writer.write(probe["id"].encode() + b"\n")
        await writer.drain()
        reply = await asyncio.wait_for(reader.readline(), timeout_s)
        return "open" if reply == REPLY_OK else "foreign"
    except (asyncio.TimeoutError, ConnectionError):
        return "foreign"
    finally:
        writer.close()


async def run_udp(probe, timeout_s):
    loop = asyncio.get_running_loop()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setblocking(False)
    try:
        sock.bind((probe["src"], 0))
        # connected, so an icmp port unreachable surfaces as ECONNREFUSED on the next receive
        sock.connect((probe["dst"], probe["port"]))
        await loop.sock_sendall(sock, probe["id"].encode())
        reply = await asyncio.wait_for(loop.sock_recv(sock, UDP_DATAGRAM_BYTES_MAX), timeout_s)
        return "open" if reply.decode("ascii", "replace").strip() == probe["id"] else "foreign"
    except asyncio.TimeoutError:
        return "filtered"
    except ConnectionRefusedError:
        return "refused"
    except OSError as e:
        if e.errno in UNREACHABLE_ERRNOS:
            return "unreachable"
        raise
    finally:
        sock.close()


def run_esp(probe):
    sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, ESP_PROTO)
    try:
        sock.bind((probe["src"], 0))
        sock.sendto(ESP_HEADER.pack(ESP_SPI_PROBE, 1) + probe["id"].encode(), (probe["dst"], 0))
        return "sent"
    except OSError as e:
        if e.errno in UNREACHABLE_ERRNOS:
            return "unreachable"
        raise
    finally:
        sock.close()


async def run_main(args):
    plan = plan_parse(json_load(args.plan))
    timeout_s = args.timeout_ms / 1000
    order = list(range(len(plan)))
    random.Random(args.seed).shuffle(order)
    limit = asyncio.Semaphore(args.concurrency)
    results = {}

    async def run_one(probe):
        async with limit:
            if probe["proto"] == "tcp":
                results[probe["id"]] = await run_tcp(probe, timeout_s)
            elif probe["proto"] == "udp":
                results[probe["id"]] = await run_udp(probe, timeout_s)
            else:
                results[probe["id"]] = run_esp(probe)

    await asyncio.gather(*(run_one(plan[i]) for i in order))
    assert len(results) == len(plan), "every probe has exactly one result"
    json_save(args.out, {probe["id"]: results[probe["id"]] for probe in plan})


# -----------------------------------------------------------------------------
# EXPECT
# -----------------------------------------------------------------------------


def expect_mismatch(probe, state, sightings):
    """None when the probe went as expected, else what happened instead."""
    expect = probe.get("expect", "open")
    seen_src = probe.get("seen_src", probe["src"])
    if expect == "open":
        if not sightings:
            return f"expected open, got {state}, and no sink saw it"
        sources = sorted({s["src"] for s in sightings})
        if sources != [seen_src]:
            return f"expected open from {seen_src}, the sink saw {', '.join(sources)}"
        if state not in ("open", "sent"):
            return f"expected open, the sink saw it, but the reply was {state}"
        return None
    if sightings:
        return f"expected {expect}, but a sink saw it from {sightings[0]['src']} (state {state})"
    if expect == "closed":
        return f"expected closed, got {state}" if state in ("open", "foreign") else None
    if expect != state and not (state == "sent" and expect == "filtered"):
        return f"expected {expect}, got {state}"
    return None


def expect_main(args):
    plan = plan_parse(json_load(args.plan))
    results = json_load(args.results)
    sightings = {}
    for path in args.sink_logs.split(","):
        with open(path, encoding="utf-8") as f:
            for line in f:
                entry = json.loads(line)
                if entry["id"] is not None:
                    sightings.setdefault(entry["id"], []).append(entry)
    mismatches = 0
    for probe in plan:
        if probe["id"] not in results:
            raise SystemExit(f"labprobe: no result for probe {probe['id']}")
        mismatch = expect_mismatch(probe, results[probe["id"]], sightings.get(probe["id"], []))
        if mismatch is not None:
            mismatches += 1
            print(f"MISMATCH {probe_render(probe)}: {mismatch}")
    print(f"labprobe: {len(plan)} probes, {mismatches} mismatches")
    return 1 if mismatches else 0


# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(prog="labprobe", description="reachability probes and sinks for lab tests")
    commands = parser.add_subparsers(dest="command", required=True)

    sink = commands.add_parser("sink", help="answer and log probes on the given ports")
    sink.add_argument("--tcp", default="", help="comma separated tcp ports")
    sink.add_argument("--udp", default="", help="comma separated udp ports")
    sink.add_argument("--esp", action="store_true", help="log every esp packet")
    sink.add_argument("--log", default="/run/labprobe/sink.jsonl", help="json lines log of every probe seen")

    run = commands.add_parser("run", help="send the probes of a plan")
    run.add_argument("--plan", required=True, help="json list of {id, src, dst, proto, port}")
    run.add_argument("--out", required=True, help="json map id -> state")
    run.add_argument("--seed", type=int, default=0, help="shuffles the send order")
    run.add_argument("--timeout-ms", type=int, default=700, help="a probe without an answer by then is filtered")
    run.add_argument("--concurrency", type=int, default=512, help="probes in flight at once")

    expect = commands.add_parser("expect", help="compare results and sink logs with the plan's expectations")
    expect.add_argument("--plan", required=True)
    expect.add_argument("--results", required=True)
    expect.add_argument("--sink-logs", required=True, help="comma separated sink logs")

    args = parser.parse_args()
    if args.command == "sink":
        asyncio.run(sink_main(args))
    elif args.command == "run":
        print(f"seed={args.seed}")
        asyncio.run(run_main(args))
    else:
        sys.exit(expect_main(args))


if __name__ == "__main__":
    main()
