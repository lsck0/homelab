# a guest's secrets as the real sops-nix installs them: modules/base (key at /var/lib/sops-nix/key.txt, no ssh
# key as a second identity) on vm-100, reading from two files encrypted at build time like secrets-sync.sh writes
# them (to an admin key and this host's key): its folder's secrets.sops.json and its shared copy. The host key opens
# both; the secrets land with their declared owner and mode; another host's key opens neither and leaves the
# installed secrets in place; the admin key is nowhere on the guest. Throwaway keys, no network.
{ pkgs, lib, inputs, specialArgs, ... }:
let
  secretValue = "t16-value-5c0e7a";
  netrcValue = "t16-attic-pull-token";

  # what sync.sh pushes (host.key) and what the guest must never hold (the admin key)
  keys = pkgs.runCommand "sops-activation-keys" { nativeBuildInputs = [ pkgs.age ]; } ''
    mkdir $out
    for k in admin host other; do age-keygen -o $out/$k.key 2>/dev/null; age-keygen -y $out/$k.key > $out/$k.pub; done
  '';
  hostKey = pkgs.runCommand "host.key" { } "cp ${keys}/host.key $out";
  otherKey = pkgs.runCommand "other.key" { } "cp ${keys}/other.key $out";
  # the host's own values and its copy of the shared ones: admin and host recipients, as secrets-sync.sh writes them
  sopsFileOf = name: values: pkgs.runCommand name { nativeBuildInputs = [ pkgs.sops pkgs.jq ]; } ''
    export HOME=$TMPDIR
    echo '${builtins.toJSON values}' > plain.json
    sops --encrypt --age "$(cat ${keys}/admin.pub),$(cat ${keys}/host.pub)" \
      --input-type json --output-type json plain.json > $out
  '';
  ownFile = sopsFileOf "secrets.sops.json" { t16-secret = secretValue; };
  sharedFile = sopsFileOf "secrets.shared.sops.json" { attic-pull-token = netrcValue; };
  adminPrivate = lib.removeSuffix "\n" (lib.last (lib.splitString "\n" (lib.removeSuffix "\n"
    (builtins.readFile "${keys}/admin.key"))));
  keyFile = "/var/lib/sops-nix/key.txt";
in
pkgs.testers.runNixOSTest {
  name = "sops-activation";

  node.specialArgs = { inherit (specialArgs) inputs inventory site lab; };
  nodes.vm-100 = { config, ... }: {
    imports = [
      ../default.nix
      ../../egress-vpn.nix
      inputs.sops-nix.nixosModules.sops
      ../../../tests/stubs/platform.nix
    ];
    networking.hostName = "vm-100";
    networking.interfaces.eth0.ipv4.addresses = lib.mkForce [ ];
    networking.defaultGateway = lib.mkForce null;
    # base.nix points them into the repo's folders; these are the same files, built by the test
    sops.secrets.attic-pull-token.sopsFile = lib.mkForce sharedFile;
    sops.secrets.t16-secret = { owner = "nobody"; mode = "0440"; sopsFile = lib.mkForce ownFile; };
    # the build-time check reads the file at evaluation, which a file built by this test is not yet
    sops.validateSopsFiles = false;
    sops.templates."t16-template" = { owner = "nobody"; content = "token=${config.sops.placeholder.t16-secret}"; };
    # sync.sh's push before the first activation; later activations keep whatever key is there, as in the lab
    system.activationScripts.testAgeKey = "[ -e ${keyFile} ] || install -D -m 0400 ${hostKey} ${keyFile}";
    system.activationScripts.setupSecrets.deps = [ "testAgeKey" ];
  };

  testScript = ''
    vm_100.wait_for_unit("multi-user.target")

    def secret():
        return vm_100.succeed("cat /run/secrets/t16-secret")

    with subtest("the host key opens both files; secrets land with their owner and mode"):
        assert secret() == "${secretValue}"
        assert vm_100.succeed("stat -L -c '%U %a' /run/secrets/t16-secret").strip() == "nobody 440"
        assert vm_100.succeed("stat -L -c '%U %a' /run/secrets/attic-pull-token").strip() == "root 400"
        assert "${netrcValue}" in vm_100.succeed("cat /run/secrets/rendered/nix-netrc")
        assert vm_100.succeed("cat /run/secrets/rendered/t16-template") == "token=${secretValue}"

    with subtest("another host's key opens nothing and leaves the installed secrets in place"):
        vm_100.succeed("install -m 0400 ${otherKey} ${keyFile}")
        out = vm_100.fail("/run/current-system/activate 2>&1")
        print(out)
        assert secret() == "${secretValue}", "a failed activation removed the installed secret"
        vm_100.succeed("install -m 0400 ${hostKey} ${keyFile} && /run/current-system/activate")
        assert secret() == "${secretValue}"

    with subtest("the admin key is nowhere on the guest"):
        vm_100.fail("grep -rqsF '${adminPrivate}' /etc /var /run /root /home /tmp")
        # positive control: the scan finds a key that is there
        vm_100.succeed("grep -rqsF \"$(grep AGE-SECRET-KEY ${keyFile})\" /var")
  '';
}
