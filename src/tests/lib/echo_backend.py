"""echo_backend: what an app behind the ingresses sees, for edge-apps.nix (200) and sso-access.nix (101).

    echo-backend --ports 80,8081 [--tls-port 8006 --cert c.pem --key k.pem] --log /run/echo/requests.jsonl

Listens on 0.0.0.0 on every port (one machine stands in for many guests by owning their addresses), answers every
method with a json body {node, port, method, path, headers, body_len} and logs the same as one json line per
request. Paths: /big answers 4 KiB of text/html (for compression), /blob BLOB_BYTES of zeros (a download),
/health and */health answer {"ok": true}.
A GET asking to upgrade to a websocket is answered 101 and served as an echo socket: the server sends WEBSOCKET_GREETING
first, then returns every text or binary message as it came, answers pings and closes on a close (unfragmented
frames only, which every message of a test is).
A port listed in --stopped-file (one port per line) refuses to answer (503), so a test can take a "node" down.
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
import ssl
import struct
import threading

BIG_BYTES = 4096
# eight times traefik's in-memory buffer (modules/traefik memRequestBodyBytes): buffered, it would spill to disk
BLOB_BYTES = 8 * 1024 * 1024

# rfc 6455 section 1.3: the key's suffix of the handshake's accept hash
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WEBSOCKET_GREETING = b"hello"
OPCODE_TEXT, OPCODE_BINARY, OPCODE_CLOSE, OPCODE_PING, OPCODE_PONG = 0x1, 0x2, 0x8, 0x9, 0xA
FRAME_FIN = 0x80
FRAME_MASKED = 0x80
FRAME_OPCODE = 0x0F
FRAME_LENGTH = 0x7F
# a 7-bit length of 126 or 127 announces a 16- or 64-bit one
LENGTH_16 = 126
LENGTH_64 = 127
MASK_BYTES = 4


def handler_for(log_path, stopped_path):
    lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def handle_any(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                body = self.read_chunked()
            node, port = self.connection.getsockname()[:2]
            entry = {"node": node, "port": port, "method": self.command, "path": self.path,
                     "headers": {k.lower(): v for k, v in self.headers.items()}, "body_len": len(body)}
            with lock, open(log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry) + "\n")
            stopped = open(stopped_path).read().split() if os.path.exists(stopped_path) else []
            if f"{node}:{port}" in stopped:
                return self.reply(503, "text/plain", b"stopped\n")
            if self.command == "GET" and self.headers.get("Upgrade", "").lower() == "websocket":
                return self.websocket_serve()
            if self.path.split("?")[0].endswith("/big"):
                return self.reply(200, "text/html", b"x" * BIG_BYTES)
            if self.path.split("?")[0].endswith("/blob"):
                return self.reply(200, "application/octet-stream", bytes(BLOB_BYTES))
            return self.reply(200, "application/json", json.dumps(entry).encode())

        def read_chunked(self):
            data = b""
            while True:
                size = int(self.rfile.readline().strip(), 16)
                if size == 0:
                    self.rfile.readline()
                    return data
                data += self.rfile.read(size)
                self.rfile.readline()

        def websocket_receive(self):
            """One frame as (opcode, payload), None once the peer is gone."""
            head = self.rfile.read(2)
            if len(head) < 2:
                return None
            length = head[1] & FRAME_LENGTH
            if length == LENGTH_16:
                length = struct.unpack("!H", self.rfile.read(2))[0]
            elif length == LENGTH_64:
                length = struct.unpack("!Q", self.rfile.read(8))[0]
            mask = self.rfile.read(MASK_BYTES) if head[1] & FRAME_MASKED else bytes(MASK_BYTES)
            payload = self.rfile.read(length)
            return head[0] & FRAME_OPCODE, bytes(b ^ mask[i % MASK_BYTES] for i, b in enumerate(payload))

        def websocket_send(self, opcode, payload):
            if len(payload) < LENGTH_16:
                length = bytes([len(payload)])
            elif len(payload) < 1 << 16:
                length = bytes([LENGTH_16]) + struct.pack("!H", len(payload))
            else:
                length = bytes([LENGTH_64]) + struct.pack("!Q", len(payload))
            self.wfile.write(bytes([FRAME_FIN | opcode]) + length + payload)

        def websocket_serve(self):
            key = self.headers["Sec-WebSocket-Key"] + WEBSOCKET_GUID
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
            self.end_headers()
            self.close_connection = True
            self.websocket_send(OPCODE_TEXT, WEBSOCKET_GREETING)
            while (frame := self.websocket_receive()) is not None:
                opcode, payload = frame
                if opcode == OPCODE_CLOSE:
                    return self.websocket_send(OPCODE_CLOSE, payload)
                if opcode == OPCODE_PING:
                    self.websocket_send(OPCODE_PONG, payload)
                elif opcode in (OPCODE_TEXT, OPCODE_BINARY):
                    self.websocket_send(opcode, payload)

        def reply(self, status, content_type, data):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = do_HEAD = handle_any

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ports", default="")
    parser.add_argument("--tls-port", type=int)
    parser.add_argument("--cert")
    parser.add_argument("--key")
    parser.add_argument("--log", required=True)
    parser.add_argument("--stopped-file", default="/run/echo/stopped")
    args = parser.parse_args()
    os.makedirs(os.path.dirname(args.log), exist_ok=True)
    handler = handler_for(args.log, args.stopped_file)
    servers = [http.server.ThreadingHTTPServer(("0.0.0.0", int(p)), handler) for p in args.ports.split(",") if p]
    if args.tls_port:
        server = http.server.ThreadingHTTPServer(("0.0.0.0", args.tls_port), handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.cert, args.key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        servers.append(server)
    for server in servers[1:]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    with open(f"{args.log}.ready", "w"):
        pass
    servers[0].serve_forever()


if __name__ == "__main__":
    main()
