# who reaches which internal route, through the real internal ingress (100-internal-traefik.nix) and the real
# authelia with lldap (101-internal-authelia.nix): anonymous, first factor only, and three users each with a second
# factor, the own-login routes, the login redirect, regulation, the login rate limit, oidc's policy, the read-only
# bind user, lab-user's group removal and offboarding, the guest's groups converged, the guarded portal port, the
# probers' health path, a public route's ssoPaths, the apps zone refused, and the proxmox realm's ldaps: verified
# against the certificate the guest made for itself, from proxmox's address alone, never in plain ldap
#
# The oracle is the table below, the policy as stated: admins everywhere, a user where their app-<route> group
# says, own-login routes without forwardauth and without any identity header reaching them.
{
  pkgs,
  lib,
  specialArgs,
  ...
}:
let
  lab = import ../../../../tests/lib/lab.nix {
    inherit pkgs lib specialArgs;
    # hello, a public demo, moved to the internal zone with its metrics behind authelia: a public route's ssoPaths;
    # its onion stays with the edge, its name on the internet comes through the edge's relay
    apps =
      apps:
      lib.recursiveUpdate apps {
        wat.enable = true;
        hello.routes.hello = {
          zone = "internal";
          onion = false;
          ssoPaths = [ metricsPath ];
          on = apps.hello.routes.hello.on ++ [ "internet" ];
        };
      };
  };
  metricsPath = "/metrics";
  net = import ../../../../modules/net.nix {
    inherit lib;
    inherit (specialArgs) inventory site;
  };
  ip = id: lab.inventory.${id}.ip;
  # the internal routes under test: the instances' nixos services and wat's internal page (src/instances/custom/wat)
  routes = lab.routes.internal // {
    wat-db = {
      host = "wat-db";
      inherit (lab.appsCatalog.apps.wat.routes.wat-db) port;
    };
    inherit (lab.catalog.internal) hello;
  };
  echoBackend = pkgs.writers.writePython3Bin "echo-backend" {
    flakeIgnore = [
      "E501"
      "E203"
      "W503"
    ];
  } (builtins.readFile ../../../../tests/lib/echo_backend.py);

  # a proxmox certificate for its address, from a ca the internal ingress pins (site.json proxmoxCa in the lab)
  proxmoxPki = pkgs.runCommand "fake-proxmox-pki" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out && cd $out
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj /CN=pve-ca -keyout ca.key -out ca.pem
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj /CN=pve -keyout key.pem -out req.csr
    printf 'subjectAltName=IP:${net.wan.proxmox}\n' > ext
    openssl x509 -req -in req.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 -extfile ext -out cert.pem
  '';
  proxmoxCa = pkgs.runCommand "fake-proxmox-ca.pem" { } "cp ${proxmoxPki}/ca.pem $out";

  # the backends of the routes under test, each at its guest's address and route port; all always-on guests
  backendAddresses = map ip (
    [
      "102"
      "103"
      "104"
      "110"
      "130"
      "140"
    ]
    ++ map toString lab.appsCatalog.swarm.workers
  );
  backendPorts = lib.unique (
    map (r: r.port) (
      with routes;
      [
        homepage
        start
        grafana
        kopia
        forgejo
        homeassistant
        headscale
        headplane
        wat-db
        hello
      ]
    )
  );

  # client addresses on the house lan, one per actor, so the login limit (per client) counts each alone
  clients = {
    anon = "192.168.178.138";
    luca = "192.168.178.139";
    guest = "192.168.178.140";
    dbuser = "192.168.178.141";
    probe = "192.168.178.142";
  };
  # 25 bytes each, base32 of sha256("homelab-test/totp-<user>"): authelia refuses a secret of 20 bytes or less
  totpSecrets = {
    luca = "SAB4DI6V2SGFPRIURUPZ3GBYSCR3PBTRZMJGJT3B";
    guest = "NRP6ALV5Q6A5YNERCN7ARIWL3D64HKDAX7YRJURF";
    dbuser = "EKVYFAJFL2ILTUGLLOAI3TTXW6BSKY3LDX5MRHE6";
  };
  dbuserPassword = "dbuser-test-password";
  realm =
    (import ../../../../modules/lab-export.nix {
      inherit lib;
      inherit (specialArgs) lab;
    }).ldap;
  ldapTimeoutS = 5;

  # page -> the expected status for anon, guest after the first factor only, guest, dbuser, luca. A first factor
  # names the user: authelia sends it on to the second factor where a rule admits the user, and refuses it elsewhere.
  # traefik's dashboard is /dashboard/: its / redirects there, which would read as authelia's 302
  matrix = {
    # the admins' dashboard with its widgets, and the one for everyone else
    "${net.fqdn routes.homepage.host}/" = [
      302
      403
      403
      403
      200
    ];
    "${net.fqdn routes.start.host}/" = [
      302
      302
      200
      403
      200
    ];
    "${net.fqdn routes.grafana.host}/" = [
      302
      403
      403
      403
      200
    ];
    "${net.fqdn routes.kopia.host}/" = [
      302
      403
      403
      403
      200
    ];
    "${net.fqdn routes.wat-db.host}/" = [
      302
      403
      403
      200
      200
    ];
    "${net.fqdn "traefik"}/dashboard/" = [
      302
      403
      403
      403
      200
    ];
    "${net.fqdn "proxmox"}/" = [
      302
      403
      403
      403
      200
    ];
  };
  ownHosts = map (name: net.fqdn routes.${name}.host) [
    "forgejo"
    "homeassistant"
    "headscale"
  ];

  guest = vmid: instance: extra: {
    imports = [
      (lab.guest vmid {
        flat = true;
        inherit instance;
      })
      extra
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "sso-access";
  # forgejo's, home assistant's and headscale's guests are parked in the real lab, where their routes answer 503 at
  # once; here their stand-ins answer
  node.specialArgs = lab.specialArgs // {
    inventory =
      lab.specialArgs.inventory
      // lib.genAttrs [ "110" "130" "140" ] (id: lab.specialArgs.inventory.${id} // { powered = true; });
  };

  nodes.vm-100 = guest "100" ../../100-internal-traefik/main.nix {
    imports = [ ../../../../tests/lib/offline-traefik.nix ];
    homelab.onDemand.caFile = "${proxmoxCa}";
    virtualisation.memorySize = 1024;
  };
  nodes.vm-101 = guest "101" ../main.nix {
    environment.systemPackages = [
      pkgs.authelia
      pkgs.curl
      pkgs.jq
    ];
    virtualisation.memorySize = 1024;
  };
  nodes.backends = {
    imports = [ (lab.multi { addresses = map (a: "${a}/8") backendAddresses; }) ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.netcat
    ];
    systemd.services.echo-backend = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${echoBackend}/bin/echo-backend --ports ${
        lib.concatMapStringsSep "," toString backendPorts
      } --log /run/echo/requests.jsonl";
    };
  };
  # the gateways of the flat lab, the house lan's clients, and proxmox's api
  nodes.world = {
    imports = [
      (lab.multi {
        addresses = [
          "10.100.0.1/8"
          "10.250.0.1/8"
          "${net.wan.proxmox}/24"
        ]
        ++ map (a: "${a}/24") (lib.attrValues clients);
      })
    ];
    environment.systemPackages = [
      pkgs.curl
      pkgs.python3
      pkgs.netcat
      pkgs.openldap
      pkgs.openssl
    ];
    systemd.services.fake-proxmox = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${echoBackend}/bin/echo-backend --tls-port ${toString net.ports.proxmoxApi} --cert ${proxmoxPki}/cert.pem --key ${proxmoxPki}/key.pem --log /run/echo/proxmox.jsonl";
    };
  };

  testScript =
    { nodes, ... }:
    lab.driverPython
    + ''
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

      with subtest("lab-user removes groups and offboards a user with its second factors; the guest holds its groups alone"):
          vm_101.succeed("printf '%s\n%s\n' leaver-password leaver-password | lab-user add leaver app-wat-db app-grafana")
          vm_101.succeed(f"authelia storage user totp generate leaver --encryption-key \"$(cat /run/secrets/authelia-storage-key)\" --sqlite.path {STATE}/db.sqlite3")
          vm_101.succeed("lab-user ungroup leaver app-grafana")
          groups = vm_101.succeed("lab-user list | grep '^leaver'")
          assert "app-wat-db" in groups and "app-grafana" not in groups, groups
          out = vm_101.succeed("lab-user offboard leaver")
          assert "Forgejo" in out, out
          assert "leaver" not in vm_101.succeed("lab-user list"), "offboarded user still listed"
          totps = vm_101.succeed(f"authelia storage user totp export uri --encryption-key \"$(cat /run/secrets/authelia-storage-key)\" --sqlite.path {STATE}/db.sqlite3")
          assert ":leaver?" not in totps, totps
          # a group the guest held before its route stopped opening to it goes at the next bootstrap
          vm_101.succeed("lab-user groups guest app-homepage")
          vm_101.succeed("systemctl restart lldap-bootstrap.service")
          guest = vm_101.succeed("lab-user list | grep '^guest'")
          assert "app-homepage" not in guest and "app-start" in guest, guest

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

      with subtest("a public route's ssoPaths need a session however spelled, the rest stays open, the collector reads the backend"):
          public = "https://${net.fqdn routes.hello.host}"
          backends.succeed(": > /run/echo/requests.jsonl")
          for path in ("${metricsPath}", "${metricsPath}/x", "${metricsPath}?format=prometheus", "/METRICS", "//metrics", "/x/../metrics", "/%6detrics"):
              for method in ("GET", "POST"):
                  status, _, _ = curl(CLIENTS["anon"], f"{public}{path}", method=method, extra="--path-as-is")
                  assert status != 200, f"{method} {path}: {status}"
          assert "etrics" not in backends.succeed("cat /run/echo/requests.jsonl").lower(), "an anonymous request reached the metrics"
          status, headers, _ = curl(CLIENTS["anon"], f"{public}${metricsPath}")
          assert status == 302 and PORTAL in headers, f"{status}: {headers}"
          status, _, body = curl(CLIENTS["anon"], f"{public}/")
          assert status == 200 and json.loads(body)["path"] == "/", f"{status}: {body}"
          # admins and the route's group with both factors, nobody else
          status, _, _ = curl(CLIENTS["guest"], f"{public}${metricsPath}", jars["guest"])
          assert status == 403, status
          status, _, body = curl(CLIENTS["luca"], f"{public}${metricsPath}", jars["luca"])
          assert status == 200 and json.loads(body)["headers"].get("remote-user") == "luca", body
          # the collector's scrape: the backend port itself, past the ingress and authelia
          direct = backends.succeed("curl -sf --interface ${ip "103"} http://${lib.head routes.hello.nodes}:${toString routes.hello.port}${metricsPath}")
          assert "remote-user" not in json.loads(direct)["headers"], direct

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

      with subtest("authelia's port answers the ingress only, the probers included"):
          for source in ("${ip "110"}", "${ip "102"}", "${ip "103"}"):
              backends.fail(f"nc -z -w 2 -s {source} ${ip "101"} ${toString routes.authelia.port}")
          world.fail("nc -z -w 2 -s ${clients.anon} ${ip "101"} ${toString routes.authelia.port}")

      with subtest("the proxmox realm reads lldap over ldaps from proxmox's address, verified against the guest's own certificate"):
          world.succeed(f"cat > /tmp/realm.pem <<'EOF'\n{vm_101.succeed('cat ${realm.certFile}')}EOF")
          world.succeed("openssl x509 -in /tmp/realm.pem -noout -ext subjectAltName | grep -qw 'IP Address:${realm.host}'")
          world.succeed(f"printf %s '{secret('lldap-proxmox-bind-password')}' > /tmp/realm.pw")
          # what the hypervisor sends from: its own lan address
          world.succeed("ip route replace ${realm.host}/32 dev eth1 src ${net.wan.proxmox}")

          def realm_search(ca):
              return world.execute(
                  f"LDAPTLS_CACERT={ca} LDAPTLS_REQCERT=demand ldapsearch -o nettimeout=${toString ldapTimeoutS} -LLL "
                  "-H ldaps://${realm.host}:${toString realm.port} -D uid=${realm.bindUser},ou=people,${realm.baseDn} -y /tmp/realm.pw "
                  "-b ou=groups,${realm.baseDn} cn=${realm.adminGroup} cn")

          status, out = realm_search("/tmp/realm.pem")
          assert status == 0 and "cn: ${realm.adminGroup}" in out, out
          # verification is on: a certificate for the same address from anyone else is refused
          world.succeed("openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj /CN=other "
                        "-addext subjectAltName=IP:${realm.host} -keyout /tmp/other.key -out /tmp/other.pem")
          status, out = realm_search("/tmp/other.pem")
          assert status != 0, out
          world.fail("nc -z -w ${toString ldapTimeoutS} -s ${net.wan.proxmox} ${realm.host} ${toString nodes.vm-101.services.lldap.settings.ldap_port}")
          world.fail("nc -z -w ${toString ldapTimeoutS} -s ${clients.anon} ${realm.host} ${toString realm.port}")
          world.succeed("ip route del ${realm.host}/32")

      with subtest("a lost ldaps key makes a new certificate, which the realm's old pin refuses"):
          vm_101.succeed("rm ${dirOf realm.certFile}/ldaps-key.pem")
          vm_101.succeed("systemctl restart lldap.service")
          vm_101.wait_for_open_port(${toString realm.port})
          world.succeed("ip route replace ${realm.host}/32 dev eth1 src ${net.wan.proxmox}")
          status, out = realm_search("/tmp/realm.pem")
          assert status != 0, out
          world.succeed("ip route del ${realm.host}/32")

      with subtest("the probers reach a route's health path past sso, and nothing else of it"):
          def probe(src, path, method="GET"):
              host = "${net.fqdn routes.headplane.host}"
              verb = "-I" if method == "HEAD" else f"-X {method}"
              return backends.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {verb} --interface {src} --resolve {host}:443:{INGRESS} https://{host}{path}")
          backends.succeed(": > /run/echo/requests.jsonl")
          for source in ("${ip "102"}", "${ip "103"}"):
              assert probe(source, "${routes.headplane.health}") == "200", source
              assert probe(source, "${routes.headplane.health}", "HEAD") == "200", source
              # the rest of the route, and any other method on the health path, still meet authelia
              assert probe(source, "/") == "302", source
              assert probe(source, "${routes.headplane.health}", "POST") != "200", source
          # positive control of the source check: another internal guest meets authelia on the health path
          assert probe("${ip "110"}", "${routes.headplane.health}") == "302"
          logged = backends.succeed("cat /run/echo/requests.jsonl")
          assert logged.count("${routes.headplane.health}") == 4 and "remote-user" not in logged, logged

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

      with subtest("regulation bans a client after three wrong passwords, never the user, and lifts the ban"):
          for i in range(3):
              curl(CLIENTS["probe"], f"{PORTAL}/api/firstfactor", None, "POST", {"username": "guest", "password": f"wrong-{i}", "keepMeLoggedIn": False})
          status, _, _ = curl(CLIENTS["probe"], f"{PORTAL}/api/firstfactor", "/tmp/jar-ban", "POST",
                              {"username": "guest", "password": passwords["guest"], "keepMeLoggedIn": False})
          assert status != 200, f"banned client logged in: {status}"
          # the user from their own address is not locked out by someone else's guesses
          login("guest", passwords["guest"], second_factor=False)
          world.wait_until_succeeds(
              f"[ $(curl -s -o /dev/null -w '%{{http_code}}' --interface {CLIENTS['probe']} --resolve ${net.fqdn routes.authelia.host}:443:{INGRESS} "
              f"-H 'Content-Type: application/json' --data '{json.dumps({'username': 'guest', 'password': passwords['guest'], 'keepMeLoggedIn': False})}' "
              f"{PORTAL}/api/firstfactor) = 200 ]", timeout=420)
    '';
}
