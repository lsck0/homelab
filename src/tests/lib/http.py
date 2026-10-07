# lib/http.py: one http request from a test machine, prepended to a testScript by lab.testScript
#
# curl on the machine, from a chosen source address, to a chosen ingress address, verified against the test ca
# every lab node trusts (lib/pki.nix); the result is a dict, so every assertion about a route is one table row.
#
#     r = http_request(world, "https://wat.lsck0.dev/api/health", address="10.200.0.200", src="104.16.0.10",
#                      headers={"X-Forwarded-For": "203.0.113.9"})
#     assert r["status"] == 200 and r["headers"]["content-type"].startswith("application/json"), r
#
# headers in the result are lowercased; a header sent more than once keeps its last value. body is text (utf-8,
# undecodable bytes replaced); body_bytes the length on the wire after curl's decoding (--compressed only when the
# request asks for an encoding).
import shlex
import urllib.parse

HTTP_DIR_VM = "/run/lab-http"
HTTP_TIMEOUT_S = 20


def http_request(machine: Machine, url: str, address: str | None = None, src: str | None = None,
                 method: str = "GET", headers: dict[str, str] | None = None, body: str | None = None) -> dict:
    """Send one request with curl from `machine` and return {status, headers, body, body_bytes}."""
    parsed = urllib.parse.urlsplit(url)
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    # -X HEAD would wait for the body its content-length announces; --head reads none (and prints the headers as one)
    method_args = ["--head"] if method == "HEAD" else ["-X", method]
    machine.succeed(f"mkdir -p {HTTP_DIR_VM} && : > {HTTP_DIR_VM}/body")
    body_out = "/dev/null" if method == "HEAD" else f"{HTTP_DIR_VM}/body"
    args = ["curl", "-sS", "--max-time", str(HTTP_TIMEOUT_S), *method_args, "-o", body_out,
            "-D", f"{HTTP_DIR_VM}/headers", "-w", "%{http_code}", "--path-as-is"]
    if address is not None:
        args += ["--resolve", f"{parsed.hostname}:{port}:{address}"]
    if src is not None:
        args += ["--interface", src]
    for name, value in (headers or {}).items():
        args += ["-H", f"{name}: {value}"]
    if body is not None:
        machine.succeed(f"mkdir -p {HTTP_DIR_VM} && printf %s {shlex.quote(body)} > {HTTP_DIR_VM}/request")
        args += ["--data-binary", f"@{HTTP_DIR_VM}/request"]
    status = machine.succeed(f"mkdir -p {HTTP_DIR_VM} && {shlex.join(args + [url])}").strip()
    response_headers = {}
    for line in machine.succeed(f"cat {HTTP_DIR_VM}/headers").splitlines():
        if ":" in line:
            name, value = line.split(":", 1)
            response_headers[name.strip().lower()] = value.strip()
    response_body = machine.succeed(f"cat {HTTP_DIR_VM}/body")
    body_bytes = int(machine.succeed(f"stat -c %s {HTTP_DIR_VM}/body").strip())
    return {"status": int(status), "headers": response_headers, "body": response_body, "body_bytes": body_bytes}
