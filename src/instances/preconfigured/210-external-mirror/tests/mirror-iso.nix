# vm-210 serves the install iso that vm-112's publish put in iso/ (112-internal-archbuild archrepo-build.nu iso-publish):
# the internet reads it under its prefix like the status, the house without; the index lists it and the latest links
# lead to the dated files
{
  pkgs,
  lib,
  specialArgs,
  ...
}:
let
  lab = import ../../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  prefix = lab.specialArgs.lab.routes.mirror.publicPrefix;
  repoDir = "/var/lib/archrepo";
  iso = "archlinux-lsck0-2026.10.18-x86_64.iso";
  latest = "archlinux-lsck0-latest-x86_64.iso";
in
pkgs.testers.runNixOSTest {
  name = "mirror-iso";

  node.specialArgs = lab.specialArgs;
  nodes.vm-210 = {
    imports = [ (lab.guest "210" { instance = ../main.nix; }) ];
    services.journald.upload.enable = lib.mkForce false;
  };

  testScript = ''
    vm_210.start()
    vm_210.wait_for_unit("nginx.service")
    vm_210.wait_for_open_port(80)
    vm_210.succeed(
        "install -d -o archrepo -g archrepo ${repoDir}/iso ${repoDir}${prefix}",
        "echo iso > ${repoDir}/iso/${iso}",
        "echo sig > ${repoDir}/iso/${iso}.sig",
        "ln -s ${iso} ${repoDir}/iso/${latest}",
        "ln -s ${iso}.sig ${repoDir}/iso/${latest}.sig",
    )

    for root in ["${prefix}", ""]:
        with subtest(f"the iso index and its latest links under '{root}/'"):
            index = vm_210.succeed(f"curl -sf http://127.0.0.1{root}/iso/")
            assert "${iso}" in index and "${latest}" in index, index
            assert vm_210.succeed(f"curl -sf http://127.0.0.1{root}/iso/${latest}") == "iso\n"
            assert vm_210.succeed(f"curl -sf http://127.0.0.1{root}/iso/${latest}.sig") == "sig\n"

    with subtest("the internet's tree shares nothing else of the full one"):
        vm_210.succeed("mkdir -p ${repoDir}/x86_64 && echo db > ${repoDir}/x86_64/lsck0.db")
        vm_210.fail("curl -sf http://127.0.0.1${prefix}/x86_64/lsck0.db")
        vm_210.fail("curl -sf http://127.0.0.1${prefix}/isolation")
  '';
}
