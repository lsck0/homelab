# vm-115's forge as it ships (../main.nix), from the image it ran before to the one it runs
# now: the bootstrap units on a fresh forge, tokens written to the guest's own token dir (the link stays a link), a
# rejected token minted again, the upgrade keeping the old database and the forge's data, and every setup unit
# converging again on the new version. Images are pinned here and fetched at build time, nothing pulls at run time.
{ pkgs, lib, inputs, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  instance = ../main.nix;
  shipped = inputs.self.nixosConfigurations."115-internal-forgejo".config.virtualisation.oci-containers.containers.forgejo.image;

  imageOf = { tag, imageDigest, hash }: {
    name = "codeberg.org/forgejo/forgejo:${tag}";
    file = pkgs.dockerTools.pullImage {
      imageName = "codeberg.org/forgejo/forgejo";
      inherit imageDigest hash;
      finalImageName = "codeberg.org/forgejo/forgejo";
      finalImageTag = tag;
      os = "linux";
      arch = "amd64";
    };
  };
  # the image the lab ran before the upgrade
  before = imageOf {
    tag = "7.0.16";
    imageDigest = "sha256:d1044fe10757f7cd7725fa470d9e27814d2c5426a114098c24da425d3f25eb49";
    hash = "sha256-6yb2Vbld1ZEl1Xep3qSvKxKnPXIdB7PVVd5BJieK0P0=";
  };
  # the image 115 ships; bump it with the instance (nix-prefetch-docker, see tests/lib/images.nix)
  current = imageOf {
    tag = "15.0.9";
    imageDigest = "sha256:91a5310c86934339e16bd06b6078aada836e3d8935b2d70f6598108cbfaed5d1";
    hash = "sha256-MpFp0WxRPOhaRWopRpphFSSaMiODdYOq3qX+lAlf1kc=";
  };

  # authelia's discovery document, as much of it as forgejo reads when it adds the login source
  discovery = pkgs.writeText "openid-configuration" (builtins.toJSON {
    issuer = "https://auth.${lab.site.domain}";
    authorization_endpoint = "https://auth.${lab.site.domain}/api/oidc/authorization";
    token_endpoint = "https://auth.${lab.site.domain}/api/oidc/token";
    userinfo_endpoint = "https://auth.${lab.site.domain}/api/oidc/userinfo";
    jwks_uri = "https://auth.${lab.site.domain}/jwks.json";
    response_types_supported = [ "code" ];
    subject_types_supported = [ "public" ];
    id_token_signing_alg_values_supported = [ "RS256" ];
  });
  # where the container trusts the test ca: forgejo is go, which reads SSL_CERT_FILE
  containerCa = "/etc/ssl/test-ca.pem";

  T = "/var/lib/lab-tokens";
  own = "/var/lib/lab-tokens.d/vm-115";
  setupUnits = [ "forgejo-init" "forgejo-oauth2-setup" "forgejo-homepage-token" "forgejo-hermes-token" "forgejo-runner-token" ];
  # above the instance's own definition, below nothing: the specialisation's image wins over the base's
  imageOverride = lib.mkOverride 40;
in
assert lib.assertMsg (current.name == shipped) "tests/forgejo.nix pins ${current.name}, 115 ships ${shipped}: bump the pin";
pkgs.testers.runNixOSTest {
  name = "forgejo";

  node.specialArgs = lab.specialArgs;
  nodes.vm-115 = {
    imports = [ (lab.guest "115" { inherit instance; }) ];
    virtualisation = { memorySize = 2048; diskSize = 4096; };
    environment.systemPackages = [ pkgs.sqlite pkgs.jq ];
    # the timer would reach github
    systemd.timers.forgejo-mirror.enable = false;
    # no collector in this test: a failing upload would fail the switch below for a reason outside the forge
    services.journald.upload.enable = lib.mkForce false;
    virtualisation.oci-containers.containers.forgejo = {
      image = lib.mkForce before.name;
      imageFile = lib.mkForce before.file;
      volumes = [ "${lab.pki.ca}:${containerCa}:ro" ];
      environment.SSL_CERT_FILE = containerCa;
    };
    specialisation.upgraded.configuration.virtualisation.oci-containers.containers.forgejo = {
      image = imageOverride current.name;
      imageFile = imageOverride current.file;
    };
  };

  # the internal ingress, standing in for authelia behind it: the discovery document forgejo checks the login with
  nodes.ingress = {
    imports = [ (lab.multi { addresses = [ "${lab.inventory."100".ip}/24" ]; vlan = lab.vlans.internal; }) ];
    services.nginx = {
      enable = true;
      virtualHosts."auth.${lab.site.domain}" = {
        onlySSL = true;
        sslCertificate = lab.pki.lsck0.cert;
        sslCertificateKey = lab.pki.lsck0.key;
        locations."= /.well-known/openid-configuration".alias = discovery;
      };
    };
  };

  testScript = ''
    def api_user(token):
        return vm_115.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' -H 'Authorization: token {token}' http://127.0.0.1/api/v1/user").strip()

    def setup_converges():
        for unit in ${builtins.toJSON setupUnits}:
            vm_115.wait_for_unit(f"{unit}.service", timeout=600)

    ingress.start()
    ingress.wait_for_open_port(443)
    vm_115.start()
    vm_115.wait_for_unit("podman-forgejo.service")
    setup_converges()

    with subtest("a fresh forge: the owner, the authelia login, the tokens in the guest's own dir"):
        users = vm_115.succeed("podman exec -u git forgejo forgejo admin user list")
        assert " luca " in users and " homepage-bot " in users and " hermes-bot " in users, users
        assert "authelia" in vm_115.succeed("podman exec -u git forgejo forgejo admin auth list")
        for token in ["forgejo-key", "forgejo-hermes", "forgejo-runner"]:
            vm_115.succeed(f"test -L ${T}/{token}.token && test -f ${own}/{token}.token && ! test -L ${own}/{token}.token")
        assert api_user(vm_115.succeed("cat ${T}/forgejo-hermes.token")) == "200"

    with subtest("data the upgrade must keep"):
        hermes = vm_115.succeed("cat ${T}/forgejo-hermes.token")
        vm_115.succeed(
            f"curl -sf -X POST -H 'Authorization: token {hermes}' -H 'Content-Type: application/json' "
            "-d '{\"name\":\"keep\",\"auto_init\":true}' http://127.0.0.1/api/v1/user/repos")

    with subtest("a rejected token is minted again into the own dir, the link stays a link"):
        vm_115.succeed("printf bogus > ${own}/forgejo-key.token")
        vm_115.succeed("systemctl restart forgejo-homepage-token.service")
        token = vm_115.succeed("cat ${T}/forgejo-key.token")
        assert token != "bogus" and api_user(token) == "200", token
        vm_115.succeed("test -L ${T}/forgejo-key.token")

    with subtest("the upgrade keeps the old database and every repository"):
        vm_115.succeed("/run/booted-system/specialisation/upgraded/bin/switch-to-configuration test")
        vm_115.wait_for_unit("podman-forgejo.service")
        setup_converges()
        # the new version migrates the db before it answers; sign-in is required even for the version
        version = vm_115.wait_until_succeeds(
            f"curl -sf -H 'Authorization: token {hermes}' http://127.0.0.1/api/v1/version | jq -er .version", timeout=300)
        assert version.startswith("${lib.last (lib.splitString ":" current.name)}"), version
        kept = "/var/lib/forgejo/gitea/gitea.db.before-${lib.last (lib.splitString ":" current.name)}"
        assert "keep" in vm_115.succeed(f"sqlite3 {kept} 'select name from repository'")
        vm_115.succeed(f"curl -sf -H 'Authorization: token {hermes}' http://127.0.0.1/api/v1/repos/hermes-bot/keep")
        # tokens minted before the upgrade still open the forge
        assert api_user(hermes) == "200"

    with subtest("setup is idempotent on the new version"):
        for unit in ${builtins.toJSON setupUnits}:
            vm_115.succeed(f"systemctl restart {unit}.service")
        vm_115.succeed("journalctl -u forgejo-init --since -1min | grep -q 'users exist'")
        vm_115.succeed("podman exec -u git forgejo forgejo doctor check --all >&2")
  '';
}
