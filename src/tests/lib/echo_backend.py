"""echo_backend: what an app behind the ingresses sees, for edge-apps.nix (200) and sso-access.nix (101).

    echo-backend --ports 80,8081 [--tls-port 8006 --cert c.pem --key k.pem] --log /run/echo/requests.jsonl

Listens on 0.0.0.0 on every port (one machine stands in for many guests by owning their addresses), answers every
method with a json body {node, port, method, path, headers, body_len} and logs the same as one json line per
request. Paths: /big answers 4 KiB of text/html (for compression), /health and */health answer {"ok": true}.
A port listed in --stopped-file (one port per line) refuses to answer (503), so a test can take a "node" down.
"""

import argparse
import http.server
import json
import os
import ssl
import threading

BIG_BYTES = 4096


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
            if self.path.split("?")[0].endswith("/big"):
                return self.reply(200, "text/html", b"x" * BIG_BYTES)
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
