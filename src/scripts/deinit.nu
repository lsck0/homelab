#!/usr/bin/env -S nu --no-config-file
# tear the lab down again: pve-install.nu's teardown on the Proxmox host; the local terraform state copy is set aside,
# so the next deploy starts fresh (TF_STATE_FRESH=1). Proxmox's host key must be pinned (init.nu --pin).

const ROOT = path self | path dirname | path dirname | path dirname
const SRC = $ROOT | path join src
use lib/tools.nu [die tools-require]
use lib/proxmox.nu [lab-files proxmox-tfvars-load proxmox-login proxmox-ssh-init proxmox-teardown PROXMOX_SSH_USER_DEFAULT PROXMOX_SSH_PORT_DEFAULT]
use lib/tfstate.nu [tfstate-dir tfstate-set-aside]

# Destroy every guest on Proxmox and what pve-install.nu set up; the ip defaults to site.json's lan.proxmox
def main [proxmox_ip?: string, --yes]: nothing -> nothing {
    tools-require ssh ssh-keygen
    let site = (lab-files $SRC).site
    let ip = $proxmox_ip | default (if ($site | path exists) { open $site | get --optional lan.proxmox })
    if $ip == null { die "no Proxmox address: pass it, or run init.nu, which writes src/generated/site.json." }

    if ((lab-files $SRC).tfvars | path exists) { tools-require sops }
    $env.SOPS_AGE_KEY_FILE = $env.SOPS_AGE_KEY_FILE? | default ($ROOT | path join secrets age.txt)
    let tfvars = proxmox-tfvars-load $SRC
    if $tfvars == null { print $">>> no tfvars: logging in as ($PROXMOX_SSH_USER_DEFAULT) on port ($PROXMOX_SSH_PORT_DEFAULT)" }
    let login = proxmox-login $tfvars
    let ssh = proxmox-ssh-init $SRC $ip $login.port

    if not $yes {
        print $"This destroys all VMs and LXCs on ($ip) and what pve-install.nu set up \(its teardown lists what stays\)."
        print "The local terraform state copy is set aside."
        if (input "Type 'yes' to continue: ") != "yes" { die "Aborted." }
    }

    print $">>> Resetting Proxmox host ($ip)..."
    proxmox-teardown $SRC $ssh $"($login.user)@($ip)"
    let aside = tfstate-set-aside (tfstate-dir | path join terraform.tfstate)
    if $aside != "" { print $aside }
    print ">>> Proxmox reset complete."
    print $">>> Next: ./src/scripts/init.nu ($ip), then TF_STATE_FRESH=1 ./sync.nu"
}
