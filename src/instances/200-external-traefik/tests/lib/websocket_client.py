"""websocket_client: websockets held open through an ingress, for edge-apps.nix.

    websocket-client --url wss://wat.lsck0.dev/api/socket --address 10.200.0.200 --source 104.16.0.10 --ca ca.pem \
        --header 'X-Forwarded-For: 203.0.113.20' --count 101 --idle-s 190 --report /tmp/report.json --release /tmp/fifo

Opens up to --count sockets to --url one after another, connecting to --address from --source over tls verified
against --ca, and checks each for the backend's greeting and an echo (tests/lib/echo_backend.py); the first refused
upgrade ends the opening. It writes the report, whole, to --report:

    {"opened": 100, "refused": {"status": 429, "retry_after": null}, "idle_echoed": null}

With --idle-s it then leaves every open socket idle that long (no keepalive pings), counts the sockets that echo
again into idle_echoed and writes the report again. With --release it holds the sockets until a line arrives on that
fifo; then it closes them. A websocket library is the client, never the backend's own frame code: the two sides check
each other.
"""

import argparse
import asyncio
import json
import os
import ssl

from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed, InvalidStatus

# what tests/lib/echo_backend.py sends first on every socket
GREETING = "hello"
HTTPS_PORT = 443
OPEN_TIMEOUT_S = 20
REPLY_TIMEOUT_S = 20


async def socket_echo(socket, message):
    """Whether one message came back unchanged; a socket the way cut answers nothing."""
    try:
        await socket.send(message)
        return await asyncio.wait_for(socket.recv(), REPLY_TIMEOUT_S) == message
    except (ConnectionClosed, TimeoutError):
        return False


async def socket_open(args, context, headers, index):
    """One socket whose greeting and echo arrived, or the refusal of its upgrade."""
    hostname = args.url.split("/")[2]
    try:
        socket = await connect(args.url, additional_headers=headers, ssl=context, server_hostname=hostname,
                               host=args.address, port=HTTPS_PORT, local_addr=(args.source, 0), proxy=None,
                               ping_interval=None, open_timeout=OPEN_TIMEOUT_S)
    except InvalidStatus as refusal:
        return None, {"status": refusal.response.status_code, "retry_after": refusal.response.headers.get("Retry-After")}
    greeting = await asyncio.wait_for(socket.recv(), REPLY_TIMEOUT_S)
    assert greeting == GREETING, greeting
    assert await socket_echo(socket, f"open {index}"), f"socket {index} echoed nothing"
    return socket, None


def report_write(path, report):
    with open(f"{path}.part", "w", encoding="utf-8") as f:
        json.dump(report, f)
    os.rename(f"{path}.part", path)


async def main():
    parser = argparse.ArgumentParser(description="hold websockets open through an ingress")
    parser.add_argument("--url", required=True)
    parser.add_argument("--address", required=True, help="the ingress to connect to, whatever the url's host resolves to")
    parser.add_argument("--source", required=True)
    parser.add_argument("--ca", required=True)
    parser.add_argument("--header", action="append", default=[], help="'Name: value', repeatable")
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--idle-s", type=int, default=0)
    parser.add_argument("--report", required=True)
    parser.add_argument("--release", help="a fifo: the sockets stay open until a line arrives on it")
    args = parser.parse_args()

    context = ssl.create_default_context(cafile=args.ca)
    headers = [tuple(part.strip() for part in h.split(":", 1)) for h in args.header]
    sockets, refused = [], None
    for index in range(args.count):
        socket, refused = await socket_open(args, context, headers, index)
        if socket is None:
            break
        sockets.append(socket)
    report = {"opened": len(sockets), "refused": refused, "idle_echoed": None}
    report_write(args.report, report)
    if args.idle_s > 0:
        await asyncio.sleep(args.idle_s)
        echoes = [await socket_echo(socket, f"after idle {index}") for index, socket in enumerate(sockets)]
        report_write(args.report, report | {"idle_echoed": sum(echoes)})
    if args.release:
        await asyncio.to_thread(lambda: open(args.release, encoding="utf-8").readline())
    for socket in sockets:
        await socket.close()


if __name__ == "__main__":
    asyncio.run(main())
