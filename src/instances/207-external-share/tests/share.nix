# vm-207's file share (instances/207-external-share/main.nix) from archived Pingvin Share to the Pingvin Share X image it
# ships now: an account made on the old image signs in on the new one, so the data dir and its sqlite carry over, and
# the declared config.yaml closes sign up.
# Images are pinned here and fetched at build time, nothing pulls at run time.
{ pkgs, lib, inputs, specialArgs, ... }:
let
  lab = import ../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  shippedContainer = inputs.self.nixosConfigurations."207-external-share".config.virtualisation.oci-containers.containers.share;
  shipped = shippedContainer.image;

  imageOf = { name, tag, imageDigest, hash }: {
    name = "${name}:${tag}";
    file = pkgs.dockerTools.pullImage {
      imageName = name;
      inherit imageDigest hash;
      finalImageName = name;
      finalImageTag = tag;
      os = "linux";
      arch = "amd64";
    };
  };
  # the image the lab ran before (archived upstream)
  before = imageOf {
    name = "stonith404/pingvin-share";
    tag = "v1.13.0";
    imageDigest = "sha256:6bf2bcd3043ee68cb61264f0857511ccf7f212fdb984382b7f2d491635184ad6";
    hash = "sha256-AsnpgnzC3YVwkG4eCnebqegzwXclsAfjLM27XCBOcWM=";
  };
  # the image 207 ships; bump it with the instance (nix-prefetch-docker, see tests/lib/images.nix)
  current = imageOf {
    name = "ghcr.io/smp46/pingvin-share-x";
    tag = "v2.0.0";
    imageDigest = "sha256:d509135afd1d2cefcdeae64a455d52ad5635f7bb37701c6f858f179023ba2910";
    hash = "sha256-nczOK5z+gzIcOrPqtcWQ6NxXFaXY7idWacLWV10qzYQ=";
  };
  imageOverride = lib.mkOverride 40;
  account = { email = "owner@example.org"; username = "owner"; password = "kept-across-the-upgrade"; };
  declared = {
    "security.allowRegistration" = "false";
    "share.maxExpiration" = "30 days";
    "general.appUrl" = "https://${lab.catalog.external.share.host}.${lab.site.domain}";
  };
in
assert lib.assertMsg (current.name == shipped) "tests/share.nix pins ${current.name}, 207 ships ${shipped}: bump the pin";
pkgs.testers.runNixOSTest {
  name = "share";

  node.specialArgs = lab.specialArgs;
  nodes.vm-207 = {
    imports = [ (lab.guest "207" { instance = ../main.nix; }) ];
    virtualisation = { memorySize = 2048; diskSize = 4096; };
    services.journald.upload.enable = lib.mkForce false;
    virtualisation.oci-containers.containers.share = {
      image = lib.mkForce before.name;
      imageFile = lib.mkForce before.file;
      # the archived image crashes on a config.yaml without initUser; the declared one is the fork's
      volumes = lib.mkForce (lib.filter (v: !lib.hasInfix "config.yaml" v) shippedContainer.volumes);
    };
    specialisation.upgraded.configuration.virtualisation.oci-containers.containers.share = {
      image = imageOverride current.name;
      imageFile = imageOverride current.file;
      volumes = imageOverride shippedContainer.volumes;
    };
  };

  testScript = ''
    import json
    import re
    account = json.loads('${builtins.toJSON account}')
    api = "http://127.0.0.1/api"

    def post(path, body):
        return vm_207.succeed(f"curl -sf -c /tmp/jar -b /tmp/jar -H 'Content-Type: application/json' -d '{json.dumps(body)}' {api}{path}")

    vm_207.start()
    vm_207.wait_for_unit("podman-share.service")
    vm_207.wait_until_succeeds(f"curl -sf -m 10 {api}/configs", timeout=300)

    with subtest("an account on the archived image"):
        post("/auth/signUp", account)

    with subtest("the fork starts on the same data dir and the account signs in"):
        # podman runs the image's healthcheck as transient units, which fail while the app starts; sync.sh
        # (switch_failures_real) ignores a failed unit that is transient or already collected, so does this switch
        status, out = vm_207.execute("/run/booted-system/specialisation/upgraded/bin/switch-to-configuration test 2>&1")
        failed = [u.strip() for line in re.findall(r"the following units failed: (.*)", out) for u in line.split(",")]
        show = lambda u, p: vm_207.succeed(f"systemctl show -P {p} {u}").strip()
        declared = lambda u: show(u, "Transient") == "no" and show(u, "LoadState") != "not-found"
        assert status == 0 or (failed and not any(map(declared, failed))), out
        # the state podman's own probe keeps; `podman healthcheck run` here stops on the driver's tty (SIGTTOU) for good
        vm_207.wait_until_succeeds("podman inspect share --format '{{.State.Health.Status}}' | grep -qx healthy", timeout=300)
        vm_207.succeed("podman inspect share --format '{{.ImageName}}' | grep -q pingvin-share-x")
        vm_207.wait_until_succeeds(f"curl -sf -m 10 {api}/configs", timeout=300)
        vm_207.succeed("rm -f /tmp/jar")
        post("/auth/signIn", {"email": account["email"], "password": account["password"]})
        me = json.loads(vm_207.succeed(f"curl -sf -b /tmp/jar {api}/users/me"))
        assert me["username"] == account["username"] and me["isAdmin"], me

    with subtest("the declared config holds: no sign up, finite expiry, the public url"):
        configs = {c["key"]: c["value"] for c in json.loads(vm_207.succeed(f"curl -sf {api}/configs"))}
        expected = json.loads('${builtins.toJSON declared}')
        assert all(configs[k] == v for k, v in expected.items()), configs
        stranger = {"email": "stranger@example.org", "username": "stranger", "password": "not-welcome-here"}
        vm_207.fail(f"curl -sf -H 'Content-Type: application/json' -d '{json.dumps(stranger)}' {api}/auth/signUp")
  '';
}
