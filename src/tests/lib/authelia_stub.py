"""authelia_stub: authelia's forwardauth decision as the real access_control makes it, for modules/traefik/tests/auth-chain.nix and
instances/200-external-traefik/tests/edge-apps.nix.

    authelia-stub --port 9091 --portal auth.lsck0.dev --session authelia_session=valid --log-dir /tmp

The portal host is bypass (200); a request carrying the session cookie is a user's (200 with Remote-User alice,
Remote-Groups users); anything else is sent to the portal (302). Every call appends the X-Forwarded-Host it
was asked about to <log-dir>/forward-auth-hosts and the X-Forwarded-For, whose first entry authelia takes for the
client (its logs and its ip regulation), to <log-dir>/forward-auth-clients, one per line.
"""

import argparse
import http.server
import os


def handler_for(portal, session, log_dir):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_append(self, name, value):
            with open(os.path.join(log_dir, name), "a", encoding="utf-8") as f:
                f.write(value + "\n")

        def do_GET(self):
            host = self.headers.get("X-Forwarded-Host", "")
            self.log_append("forward-auth-hosts", host)
            self.log_append("forward-auth-clients", self.headers.get("X-Forwarded-For", ""))
            if host == portal:
                self.send_response(200)
            elif session in self.headers.get("Cookie", ""):
                self.send_response(200)
                self.send_header("Remote-User", "alice")
                self.send_header("Remote-Groups", "users")
            else:
                self.send_response(302)
                self.send_header("Location", f"https://{portal}/")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *args):
            pass

    return Handler


def main():
    parser = argparse.ArgumentParser(description="authelia's forwardauth decision, for tests")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--portal", required=True, help="the portal's host, bypassed")
    parser.add_argument("--session", required=True, help="the cookie that makes a request authenticated")
    parser.add_argument("--log-dir", default="/tmp")
    args = parser.parse_args()
    handler = handler_for(args.portal, args.session, args.log_dir)
    http.server.ThreadingHTTPServer(("0.0.0.0", args.port), handler).serve_forever()


if __name__ == "__main__":
    main()
