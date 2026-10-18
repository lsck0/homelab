"""mc-probe: the minecraft client the vm test drives mc-gate and its backends with.

It speaks the three packets a real client sends before it plays: the handshake (protocol, the address the player
typed, port, intent), then either a status request or a login start. The address matters, because that is what the
gate reads the server's name out of, so the test always dials <server>.mc.lsck0.dev.

  mc-probe status 10.200.0.214:25565 cobblemon.mc.lsck0.dev      # prints the status json, one line
  mc-probe login 10.200.0.214:25565 cobblemon.mc.lsck0.dev       # prints "kick <text>" or "success <player>"
  mc-probe login ... --hold 600                                  # the same, then holds the session open

A held login is one player sitting on a server: the gate counts it as a live session, so the test can ask for
another server and be refused. The test ends it by killing the process.
"""
import argparse
import json
import socket
import sys
import time

# the protocol of minecraft 1.21.1, which is what the test's backends report
PROTOCOL = 767
# packet ids, by state: 0x00 is the handshake, the status request, the status answer and the login kick
ID_HANDSHAKE = 0x00
ID_LOGIN_SUCCESS = 0x02
INTENT_STATUS = 1
INTENT_LOGIN = 2
# a frame the test ever reads is a status answer at most, far below this
FRAME_BYTES_MAX = 128 * 1024


def varint_pack(value):
    out = bytearray()
    while True:
        part = value & 0x7F
        value >>= 7
        if value:
            out.append(part | 0x80)
        else:
            out.append(part)
            return bytes(out)


def string_pack(text):
    raw = text.encode()
    return varint_pack(len(raw)) + raw


def packet_pack(packet_id, body):
    inner = varint_pack(packet_id) + body
    return varint_pack(len(inner)) + inner


def varint_unpack(data, pos):
    value = 0
    for shift in range(0, 35, 7):
        if pos >= len(data):
            raise ValueError("varint: out of bytes")
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, pos
    raise ValueError("varint: over five bytes")


def string_unpack(data, pos):
    length, pos = varint_unpack(data, pos)
    return data[pos:pos + length].decode(errors="replace"), pos + length


def read_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError("the server closed the connection")
        data += chunk
    return data


def packet_read(sock):
    """One frame: its length is a varint, so it is read byte by byte before the body."""
    length = 0
    for shift in range(0, 35, 7):
        byte = read_exact(sock, 1)[0]
        length |= (byte & 0x7F) << shift
        if not byte & 0x80:
            break
    if length <= 0 or length > FRAME_BYTES_MAX:
        raise ValueError("frame length %d" % length)
    payload = read_exact(sock, length)
    packet_id, pos = varint_unpack(payload, 0)
    return packet_id, payload[pos:]


def handshake_pack(address, port, intent):
    body = varint_pack(PROTOCOL) + string_pack(address) + port.to_bytes(2, "big") + varint_pack(intent)
    return packet_pack(ID_HANDSHAKE, body)


def connect(target, timeout):
    host, _, port = target.rpartition(":")
    sock = socket.create_connection((host, int(port)), timeout=timeout)
    sock.settimeout(timeout)
    return sock, int(port)


def status(arguments):
    sock, port = connect(arguments.target, arguments.timeout)
    with sock:
        sock.sendall(handshake_pack(arguments.address, port, INTENT_STATUS) + packet_pack(0x00, b""))
        packet_id, body = packet_read(sock)
        if packet_id != 0x00:
            raise ValueError("status: packet id %d" % packet_id)
        answer, _ = string_unpack(body, 0)
        # the ping is a long the client measures its latency with; a server that drops it is broken
        token = b"\x00\x00\x00\x00\x00\x00\x00\x2a"
        sock.sendall(packet_pack(0x01, token))
        packet_id, echo = packet_read(sock)
        if packet_id != 0x01 or echo[:8] != token:
            raise ValueError("ping: id %d, %r" % (packet_id, echo[:8]))
        print(answer, flush=True)


def login(arguments):
    sock, port = connect(arguments.target, arguments.timeout)
    with sock:
        # login start: the name, then the player's uuid, which no server authenticates against the gate
        body = string_pack(arguments.player) + bytes(16)
        sock.sendall(handshake_pack(arguments.address, port, INTENT_LOGIN) + packet_pack(0x00, body))
        packet_id, payload = packet_read(sock)
        if packet_id == ID_LOGIN_SUCCESS:
            print("success %s" % arguments.player, flush=True)
        elif packet_id == ID_HANDSHAKE:
            message, _ = string_unpack(payload, 0)
            try:
                message = json.loads(message).get("text", message)
            except json.JSONDecodeError:
                pass
            print("kick %s" % message, flush=True)
            return
        else:
            print("packet %d" % packet_id, flush=True)
            return
        # a relayed login is a player on the server: hold it, so the gate counts the session
        if arguments.hold:
            sock.settimeout(arguments.hold)
            time.sleep(arguments.hold)


def main():
    parser = argparse.ArgumentParser(description="a minecraft client for the vm test")
    parser.add_argument("mode", choices=["status", "login"])
    parser.add_argument("target", help="host:port to connect to")
    parser.add_argument("address", help="the address to send in the handshake, <server>.mc.lsck0.dev")
    parser.add_argument("--player", default="tester", help="the login start name")
    parser.add_argument("--hold", type=float, default=0, help="seconds to keep a relayed login open")
    parser.add_argument("--timeout", type=float, default=30, help="socket timeout in seconds")
    arguments = parser.parse_args()
    try:
        (status if arguments.mode == "status" else login)(arguments)
    except (OSError, EOFError, ValueError) as error:
        print("error %s" % error, file=sys.stderr, flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
