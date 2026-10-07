# who reaches which internal route, through the real internal ingress (100-internal-traefik.nix) and the real
# authelia with lldap (101-internal-authelia.nix): anonymous, first factor only, and three users each with a second
# factor, the own-login routes, the login redirect, regulation, the login rate limit, oidc's policy, the read-only
# bind user, the guarded portal port, and the apps zone refused
#
# The oracle is the table below, the policy as stated: admins everywhere, a user where their app-<route> group
# says, own-login routes without forwardauth and without any identity header reaching them.
{ pkgs, lib, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  net = import ../../../modules/net.nix { inherit lib; inherit (specialArgs) inventory site; };
  ip = id: lab.inventory.${id}.ip;
  appsCatalog = lib.recursiveUpdate lab.appsCatalog { apps.wat.enable = true; };
  # the internal routes under test: the instances' nixos services and wat's internal page (src/apps/wat)
  routes = lab.routes.internal // {
    wat-db = { host = "wat-db"; inherit (appsCatalog.apps.wat.routes.wat-db) port; };
  };
  echoBackend = pkgs.writers.writePython3Bin "echo-backend" { flakeIgnore = [ "E501" ]; } (builtins.readFile ../../../tests/lib/echo_backend.py);

  # a proxmox certificate for its address, from a ca the internal ingress pins (secret proxmox-ca)
  proxmoxPki = pkgs.runCommand "fake-proxmox-pki" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out && cd $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj /CN=pve-ca -keyout ca.key -out ca.pem
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj /CN=pve -keyout key.pem -out req.csr
    printf 'subjectAltName=IP:${net.wan.proxmox}\n' > ext
    openssl x509 -req -in req.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 -extfile ext -out cert.pem
  '';
  proxmoxCa = pkgs.runCommand "fake-proxmox-ca.pem" { } "cp ${proxmoxPki}/ca.pem $out";

  # the backends of the routes under test, each at its guest's address and route port; all always-on guests
  backendAddresses = map ip [ "103" "105" "109" "115" "125" "138" "250" "251" "252" ];
  backendPorts = lib.unique (map (r: r.port) (with routes; [ homepage grafana kopia forgejo homeassistant headscale wat-db ]));

  # client addresses on the house lan, one per actor, so the login limit (per client) counts each alone
  clients = { anon = "192.168.178.138"; luca = "192.168.178.139"; guest = "192.168.178.140"; dbuser = "192.168.178.141"; probe = "192.168.178.142"; };
  # 25 bytes each, base32 of sha256("homelab-test/totp-<user>"): authelia refuses a secret of 20 bytes or less
  totpSecrets = { luca = "SAB4DI6V2SGFPRIURUPZ3GBYSCR3PBTRZMJGJT3B"; guest = "NRP6ALV5Q6A5YNERCN7ARIWL3D64HKDAX7YRJURF"; dbuser = "EKVYFAJFL2ILTUGLLOAI3TTXW6BSKY3LDX5MRHE6"; };
  dbuserPassword = "dbuser-test-password";

  # page -> the expected status for anon, guest after the first factor only, guest, dbuser, luca. A first factor
  # names the user: authelia sends it on to the second factor where a rule admits the user, and refuses it elsewhere.
  # traefik's dashboard is /dashboard/: its / redirects there, which would read as authelia's 302
  matrix = {
    "${net.fqdn routes.homepage.host}/" = [ 302 302 200 403 200 ];
    "${net.fqdn routes.grafana.host}/" = [ 302 403 403 403 200 ];
    "${net.fqdn routes.kopia.host}/" = [ 302 403 403 403 200 ];
    "${net.fqdn routes.wat-db.host}/" = [ 302 403 403 200 200 ];
    "${net.fqdn "traefik"}/dashboard/" = [ 302 403 403 403 200 ];
    "${net.fqdn "proxmox"}/" = [ 302 403 403 403 200 ];
  };
  ownHosts = map (name: net.fqdn routes.${name}.host) [ "forgejo" "homeassistant" "headscale" ];

  guest = vmid: instance: extra: { imports = [ (lab.guest vmid { flat = true; inherit instance; }) extra ]; };
in
pkgs.testers.runNixOSTest {
  name = "sso-access";
  node.specialArgs = lab.specialArgs;

  nodes.vm-100 = guest "100" ../../100-internal-traefik/main.nix {
    imports = [ ../../../tests/lib/offline-traefik.nix ];
    homelab.appsCatalog = appsCatalog;
    testing.secretValues.proxmox-ca = proxmoxCa;
    virtualisation.memorySize = 1024;
  };
  nodes.vm-101 = guest "101" ../main.nix {
    homelab.appsCatalog = appsCatalog;
    environment.systemPackages = [ pkgs.authelia pkgs.curl pkgs.jq ];
    virtualisation.memorySize = 1024;
  };
  nodes.backends = {
    imports = [ (lab.multi { addresses = map (a: "${a}/8") backendAddresses; }) ];
    environment.systemPackages = [ pkgs.curl pkgs.netcat ];
    systemd.services.echo-backend = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${echoBackend}/bin/echo-backend --ports ${lib.concatMapStringsSep "," toString backendPorts} --log /run/echo/requests.jsonl";
    };
  };
  # the gateways of the flat lab, the house lan's clients, and proxmox's api
  nodes.world = {
    imports = [ (lab.multi { addresses = [ "10.100.0.1/8" "10.250.0.1/8" "${net.wan.proxmox}/24" ] ++ map (a: "${a}/24") (lib.attrValues clients); }) ];
    environment.systemPackages = [ pkgs.curl pkgs.python3 pkgs.netcat ];
    systemd.services.fake-proxmox = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${echoBackend}/bin/echo-backend --tls-port ${toString net.ports.proxmoxApi} --cert ${proxmoxPki}/cert.pem --key ${proxmoxPki}/key.pem --log /run/echo/proxmox.jsonl";
    };
  };

  testScript = lab.driverPython + ''
    import base64
    import hashlib
    import hmac
    import struct
    import time

    MATRIX = json.loads('${builtins.toJSON matrix}')
    OWN = json.loads('${builtins.toJSON ownHosts}')
    CLIENTS = json.loads('${builtins.toJSON clients}')
    TOTP = json.loads('${builtins.toJSON totpSecrets}')
    INGRESS = "${ip "100"}"
    PORTAL = "https://${net.fqdn routes.authelia.host}"
    STATE = "/var/lib/authelia-main"

    def totp(secret):
        key = base64.b32decode(secret)
        digest = hmac.new(key, struct.pack(">Q", int(time.time()) // 30), hashlib.sha1).digest()
        offset = digest[-1] & 0x0F
        return "%06d" % ((struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 1000000)

    def curl(src, url, jar=None, method="GET", data=None, extra=""):
        host = url.split("/")[2]
        cookies = f"-b {jar} -c {jar}" if jar else ""
        body = f"-H 'Content-Type: application/json' --data '{json.dumps(data)}'" if data is not None else ""
        out = world.succeed(f"curl -s -o /tmp/body -D /tmp/headers -w '%{{http_code}}' --interface {src} --resolve {host}:443:{INGRESS} "
                            f"-X {method} {cookies} {body} {extra} '{url}'")
        return int(out), world.succeed("cat /tmp/headers"), world.succeed("cat /tmp/body")

    # a first-factor session keeps its own jar: the user's full session must survive it
    def login(user, password, second_factor=True):
        jar = f"/tmp/jar-{user}" if second_factor else f"/tmp/jar-{user}-first-factor"
        world.succeed(f"rm -f {jar}")
        status, _, body = curl(CLIENTS[user], f"{PORTAL}/api/firstfactor", jar, "POST",
                               {"username": user, "password": password, "keepMeLoggedIn": False})
        assert status == 200, f"{user} first factor: {status} {body}"
        if second_factor:
            status, _, body = curl(CLIENTS[user], f"{PORTAL}/api/secondfactor/totp", jar, "POST", {"token": totp(TOTP[user])})
            assert status == 200, f"{user} second factor: {status} {body}"
        return jar

    start_all()
    vm_101.wait_for_unit("authelia-main.service")
    vm_101.wait_for_unit("lldap-bootstrap.service")
    vm_100.wait_for_unit("traefik.service")
    vm_100.wait_for_file("/var/lib/crowdsec/data/stub-ready")
    backends.wait_for_file("/run/echo/requests.jsonl.ready")

    secret = lambda name: vm_101.succeed(f"cat /run/secrets/{name}").strip()
    passwords = {"luca": secret("authelia-admin-pass"), "guest": secret("lldap-guest-password"), "dbuser": "${dbuserPassword}"}

    with subtest("lldap holds the users; the bind user reads and cannot write"):
        # the owner's own tool, its password prompt answered on stdin
        vm_101.succeed("printf '%s\\n%s\\n' ${dbuserPassword} ${dbuserPassword} | lab-user add dbuser app-wat-db")
        token = vm_101.succeed(
            "jq -cn --rawfile p /run/secrets/lldap-authelia-bind-password '{username:\"authelia-bind\", password:($p|rtrimstr(\"\\n\"))}' "
            "| curl -sf -X POST http://127.0.0.1:${toString routes.lldap.port}/auth/simple/login -H 'Content-Type: application/json' --data-binary @- | jq -r .token"
        ).strip()
        denied = vm_101.succeed(
            f"curl -s -X POST http://127.0.0.1:${toString routes.lldap.port}/api/graphql -H 'Authorization: Bearer {token}' -H 'Content-Type: application/json' "
            "-d '{\"query\":\"mutation{createUser(user:{id:\\\"intruder\\\",email:\\\"i@x\\\"}){id}}\"}'"
        )
        assert "errors" in denied, denied
        listed = vm_101.succeed(
            f"curl -sf -X POST http://127.0.0.1:${toString routes.lldap.port}/api/graphql -H 'Authorization: Bearer {token}' -H 'Content-Type: application/json' "
            "-d '{\"query\":\"{users{id}}\"}'"
        )
        assert "dbuser" in listed and "intruder" not in listed, listed

    with subtest("second factors registered for the three users"):
        for user, totp_secret in TOTP.items():
            vm_101.succeed(f"authelia storage user totp generate {user} --secret {totp_secret} --force "
                           f"--encryption-key \"$(cat /run/secrets/authelia-storage-key)\" --sqlite.path {STATE}/db.sqlite3")

    jars = {user: login(user, password) for user, password in passwords.items()}
    one_factor = login("guest", passwords["guest"], second_factor=False)

    with subtest("each route answers exactly the users the policy names"):
        wrong = []
        for page, expected in MATRIX.items():
            actors = [("anon", None), ("guest", one_factor), ("guest", jars["guest"]), ("dbuser", jars["dbuser"]), ("luca", jars["luca"])]
            for (actor, jar), want in zip(actors, expected):
                status, _, _ = curl(CLIENTS[actor], f"https://{page}", jar)
                if status != want:
                    suffix = " (first factor only)" if jar == one_factor else ""
                    wrong.append(f"{page} as {actor}{suffix}: {status}, expected {want}")
        assert not wrong, "\n".join(wrong)

    with subtest("own-login routes skip authelia and never receive an identity header"):
        backends.succeed(": > /run/echo/requests.jsonl")
        for host in OWN:
            status, _, body = curl(CLIENTS["anon"], f"https://{host}/", extra="-H 'Remote-User: admin' -H 'Remote-Groups: admins'")
            assert status == 200, f"{host}: {status}"
            seen = json.loads(body)
            assert "remote-user" not in seen["headers"] and "remote-groups" not in seen["headers"], seen
        # positive control: an sso route hands authelia's identity on
        status, _, body = curl(CLIENTS["luca"], "https://${net.fqdn routes.grafana.host}/", jars["luca"])
        assert status == 200 and json.loads(body)["headers"].get("remote-user") == "luca", body

    with subtest("forgejo's login page is authelia's"):
        status, headers, _ = curl(CLIENTS["anon"], "https://${net.fqdn routes.forgejo.host}/user/login?redirect_to=/x")
        assert status in (301, 302, 307, 308) and "/user/oauth2/authelia" in headers, headers

    with subtest("the session cookie is the lab's, secure and http only"):
        _, headers, _ = curl(CLIENTS["probe"], f"{PORTAL}/api/firstfactor", "/tmp/jar-probe", "POST",
                             {"username": "luca", "password": passwords["luca"], "keepMeLoggedIn": False})
        cookie = next(l for l in headers.splitlines() if l.lower().startswith("set-cookie: authelia_session"))
        # attribute names are case-insensitive (rfc 6265 5.2); the value after the name is the session id
        attributes = [a.strip().lower() for a in cookie.split(";")[1:]]
        assert "domain=${net.domain}" in attributes and "secure" in attributes and "httponly" in attributes, cookie

    with subtest("oidc is no cheaper way in: a code only for a member of the client's group"):
        authorize = ("https://${net.fqdn routes.authelia.host}/api/oidc/authorization?client_id=forgejo&response_type=code&scope=openid"
                     "&state=test-state-123&redirect_uri=https%3A%2F%2F${net.fqdn routes.forgejo.host}%2Fuser%2Foauth2%2Fauthelia%2Fcallback")
        _, luca_headers, _ = curl(CLIENTS["luca"], authorize, jars["luca"])
        _, guest_headers, _ = curl(CLIENTS["guest"], authorize, jars["guest"])
        assert "code=" in luca_headers, luca_headers
        assert "code=" not in guest_headers, guest_headers

    with subtest("authelia's port answers the ingress and the granted probers only"):
        backends.fail("nc -z -w 2 -s ${ip "115"} ${ip "101"} ${toString routes.authelia.port}")
        world.fail("nc -z -w 2 -s ${clients.anon} ${ip "101"} ${toString routes.authelia.port}")
        backends.succeed("nc -z -w 2 -s ${ip "103"} ${ip "101"} ${toString routes.authelia.port}")
        backends.succeed("nc -z -w 2 -s ${ip "105"} ${ip "101"} ${toString routes.authelia.port}")

    with subtest("the apps zone gets a 404 for every internal route"):
        for host in [page.split("/")[0] for page in MATRIX] + OWN:
            status = backends.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' --interface ${ip "250"} --resolve {host}:443:{INGRESS} https://{host}/")
            assert status == "404", f"{host} from the apps zone: {status}"

    with subtest("password guessing hits the per-client login limit"):
        codes = [curl(CLIENTS["anon"], f"{PORTAL}/api/firstfactor", None, "POST",
                      {"username": "nobody", "password": f"wrong-{i}", "keepMeLoggedIn": False})[0] for i in range(15)]
        assert 429 in codes, codes
        # positive control: another client is unaffected
        status, _, _ = curl(CLIENTS["dbuser"], f"{PORTAL}/api/state", jars["dbuser"])
        assert status == 200, status

    with subtest("regulation bans a user after three wrong passwords, and lifts the ban"):
        for i in range(3):
            curl(CLIENTS["probe"], f"{PORTAL}/api/firstfactor", None, "POST", {"username": "guest", "password": f"wrong-{i}", "keepMeLoggedIn": False})
        status, _, _ = curl(CLIENTS["probe"], f"{PORTAL}/api/firstfactor", "/tmp/jar-ban", "POST",
                            {"username": "guest", "password": passwords["guest"], "keepMeLoggedIn": False})
        assert status != 200, f"banned user logged in: {status}"
        world.wait_until_succeeds(
            f"[ $(curl -s -o /dev/null -w '%{{http_code}}' --interface {CLIENTS['probe']} --resolve ${net.fqdn routes.authelia.host}:443:{INGRESS} "
            f"-H 'Content-Type: application/json' --data '{json.dumps({'username': 'guest', 'password': passwords['guest'], 'keepMeLoggedIn': False})}' "
            f"{PORTAL}/api/firstfactor) = 200 ]", timeout=420)
  '';
}
