# CI/CD target (vm-209): the real stack definitions pull from a registry,
# a new push rolls out with no failed requests, and an image that fails its
# healthcheck is rolled back. A local registry answers for both
# registry.lsck0.dev (Forgejo) and ghcr.io (GitHub).
{ pkgs, lib, ... }:
let
  # tiny web app like example/: serves its version, has curl for the healthcheck.
  app = version: healthy: pkgs.dockerTools.buildLayeredImage {
    name = "hello";
    tag = version;
    contents = [ pkgs.busybox (pkgs.writeTextDir "www/index.html" "hello ${version}\n") ]
      ++ lib.optional healthy pkgs.curl;
    config.Cmd = [ "httpd" "-f" "-p" "8000" "-h" "/www" ];
  };

  # TLS like the real registries; the test CA is trusted by dockerd per host.
  certs = pkgs.runCommand "registry-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out && cd $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=test-ca -keyout ca.key -out ca.crt
    openssl req -newkey rsa:2048 -nodes -subj /CN=registry.lsck0.dev -keyout tls.key -out tls.csr
    printf 'subjectAltName=DNS:registry.lsck0.dev,DNS:ghcr.io\n' > san.ext
    openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 -extfile san.ext -out tls.crt
  '';
in
pkgs.testers.runNixOSTest {
  name = "swarm";

  nodes.machine = {
    imports = [ ../modules/docker-stack.nix ../instances/209-external-hello.nix ];
    virtualisation.memorySize = 3072;
    virtualisation.diskSize = 6144;
    environment.systemPackages = [ pkgs.curl ];

    networking.hosts."127.0.0.1" = [ "registry.lsck0.dev" "ghcr.io" ];
    environment.etc."docker/certs.d/registry.lsck0.dev/ca.crt".source = "${certs}/ca.crt";
    environment.etc."docker/certs.d/ghcr.io/ca.crt".source = "${certs}/ca.crt";
    services.dockerRegistry = {
      enable = true;
      listenAddress = "0.0.0.0";
      port = 443;
      enableDelete = true;
      extraConfig.http.tls = { certificate = "${certs}/tls.crt"; key = "${certs}/tls.key"; };
    };
    # binding 443 as the registry's own user.
    systemd.services.docker-registry.serviceConfig.AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
    # poll quickly in the test.
    homelab.swarm.updateInterval = lib.mkForce "15s";
  };

  testScript = ''
    def push(image, version, repo):
        machine.succeed(f"docker load -i {image}")
        machine.succeed(f"docker tag hello:{version} {repo}")
        machine.succeed(f"docker push {repo}")

    machine.wait_for_unit("docker-registry.service")
    machine.wait_for_unit("docker-swarm-init.service")
    machine.wait_for_open_port(443)

    with subtest("both CI pipelines' images deploy"):
        push("${app "v1" true}", "v1", "registry.lsck0.dev/hello:latest")
        push("${app "v1" true}", "v1", "ghcr.io/lsck0/hello:latest")
        machine.succeed("systemctl restart swarm-deploy.service")
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:80/ | grep -q 'hello v1'", timeout=180)
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:8080/ | grep -q 'hello v1'", timeout=180)

    with subtest("new push rolls out with zero failed requests"):
        machine.succeed(
          "printf '%s\\n' 'while :; do curl -s -o /dev/null -w \"%{http_code}\\\\n\" --max-time 3 http://127.0.0.1:80/ >> /tmp/codes; sleep 0.2; done' > /tmp/probe.sh",
          "bash /tmp/probe.sh >/dev/null 2>&1 & echo $! > /tmp/probe.pid",
        )
        push("${app "v2" true}", "v2", "registry.lsck0.dev/hello:latest")
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:80/ | grep -q 'hello v2'", timeout=180)
        # let the old task drain
        machine.sleep(15)
        machine.succeed("kill $(cat /tmp/probe.pid)")
        codes = machine.succeed("sort /tmp/codes | uniq -c")
        print(codes)
        bad = machine.succeed("grep -vc '^200$' /tmp/codes || true").strip()
        total = machine.succeed("wc -l < /tmp/codes").strip()
        assert int(total) > 50, f"too few probes ({total})"
        assert bad == "0", f"{bad} failed requests during rollout"

    with subtest("GitHub stack untouched by the Forgejo push"):
        machine.succeed("curl -sf http://127.0.0.1:8080/ | grep -q 'hello v1'")

    with subtest("unhealthy image is rolled back, service keeps serving"):
        push("${app "v3" false}", "v3", "registry.lsck0.dev/hello:latest")
        machine.succeed("systemctl start swarm-update.service")
        machine.wait_until_succeeds(
          "docker service inspect hello_web --format '{{.UpdateStatus.State}}' | grep -q rollback_completed",
          timeout=300,
        )
        machine.succeed("curl -sf http://127.0.0.1:80/ | grep -q 'hello v2'")

    with subtest("rolled-back build is not retried every poll"):
        machine.succeed("systemctl start swarm-update.service")
        machine.succeed("journalctl -u swarm-update -n 20 | grep -q 'still the build that was rolled back'")
        machine.succeed("docker service inspect hello_web --format '{{.UpdateStatus.State}}' | grep -q rollback_completed")

    with subtest("next good push rolls out again"):
        push("${app "v4" true}", "v4", "registry.lsck0.dev/hello:latest")
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:80/ | grep -q 'hello v4'", timeout=180)
  '';
}
