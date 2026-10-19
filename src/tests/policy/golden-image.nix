# a new vm's first boot leaves nothing failed for its first switch to inherit: the golden image runs no
# systemd-resolved (no guest does; the switch removes it, dbus restarts it orphaned and it dies failed), and cloud-init
# leaves the host keys to sshd-keygen (both writing one key fails sshd-keygen, and a key replaced after the hypervisor
# read it no longer matches known_hosts)
{ lib, goldenImage, ... }:
let
  cloudInit = goldenImage.services.cloud-init.settings;
in
lib.optional goldenImage.services.resolved.enable "the golden image runs systemd-resolved, which no guest keeps"
++ lib.optional (cloudInit.ssh_deletekeys or true
) "the golden image's cloud-init deletes the host keys sshd-keygen made"
++ lib.optional (
  (cloudInit.ssh_genkeytypes or [ "default" ]) != [ ]
) "the golden image's cloud-init generates host keys beside sshd-keygen"
