# logging in to the Proxmox host (sync.nu, init.nu, deinit.nu): the pinned host key, the terraform connection vars,
# the ssh command built from both, and the host's converge (scripts/pve-install.nu)

use tools.nu [die sh-quote tools-require]
use secrets.nu [secrets-get secrets-set secrets-encrypt SECRETS_TFVARS_FILE]

export const PROXMOX_SSH_PORT_DEFAULT = 22
export const PROXMOX_SSH_USER_DEFAULT = "root"
# a dead connection ends the ssh after this, instead of hanging the run
export const PROXMOX_SSH_ALIVE_INTERVAL_S = 15
export const PROXMOX_SSH_ALIVE_COUNT = 4
# pve-install.nu leaves the secret of each api token it had to create here, one file per role
const TOKEN_DIR = "/root/homelab-tokens"
# sync.nu uploads them; terraform's nixos_image_id and nixos_lxc_template name them in proxmox's storage
export const PROXMOX_IMAGE = "/var/lib/vz/template/iso/nixos.img"
export const PROXMOX_LXC_TEMPLATE = "/var/lib/vz/template/cache/nixos-homelab.tar.xz"
const TOKENS_LIST = r#'for f in DIR/*; do [ -f "$f" ] && echo "${f##*/} $(cat "$f")"; done; true'#
# pve-install.nu runs under this nu, the release the flake pins, static so Debian's libraries do not matter; the hash
# is github's own digest of that release asset
const PROXMOX_NU = "/usr/local/bin/nu"
const PROXMOX_NU_VERSION = "0.108.0"
const PROXMOX_NU_ASSET = $"nu-($PROXMOX_NU_VERSION)-x86_64-unknown-linux-musl"
const PROXMOX_NU_URL = $"https://github.com/nushell/nushell/releases/download/($PROXMOX_NU_VERSION)/($PROXMOX_NU_ASSET).tar.gz"
const PROXMOX_NU_SHA256 = "3a3695d3fbaae1553229e263143ee02359f703efbc982bb1b475d2769d4ff6d9"
# Debian has no nu, so a plain sh installs it once per version, checked against the pinned hash before it runs
const PROXMOX_NU_BOOTSTRAP = r#'set -eu
[ "$("$NU" --version 2>/dev/null || true)" != "$VERSION" ] || exit 0
echo ">>> Proxmox: installing nu $VERSION"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 --max-time 300 -o "$tmp/nu.tar.gz" "$URL"
echo "$SHA256  $tmp/nu.tar.gz" | sha256sum --check --quiet
tar -xzf "$tmp/nu.tar.gz" -C "$tmp" "$ASSET/nu"
install -m 755 "$tmp/$ASSET/nu" "$NU"'#

# every host key of the lab (Proxmox's pinned by init.nu --pin, the guests' written by sync.nu), the machine and the
# house network (init.nu), the zones, the terraform connection
export def lab-files [src: path]: nothing -> record {
    {
        known_hosts: ($src | path join generated known_hosts)
        site: ($src | path join generated site.json)
        zones: ($src | path join generated zones.json)
        tfvars: ($src | path join $SECRETS_TFVARS_FILE)
    }
}

# the decrypted terraform vars, null when there are none
export def proxmox-tfvars-load [src: path]: nothing -> any {
    let file = (lab-files $src).tfvars
    if not ($file | path exists) { return null }
    let plain = do { ^sops --decrypt $file } | complete
    if $plain.exit_code != 0 { die $"cannot decrypt ($file)" }
    try { $plain.stdout | from json } catch { die $"the decrypted ($file) is no json" }
}

export def proxmox-login [tfvars: any]: nothing -> record {
    let vars = $tfvars | default {}
    {
        port: ($vars.proxmox_ssh_port? | default $PROXMOX_SSH_PORT_DEFAULT | into int)
        user: ($vars.proxmox_ssh_user? | default $PROXMOX_SSH_USER_DEFAULT)
    }
}

# the host's name in known_hosts
export def proxmox-pinned-host [ip: string, port: int]: nothing -> string {
    if $port == $PROXMOX_SSH_PORT_DEFAULT { $ip } else { $"[($ip)]:($port)" }
}

# the ssh argv; dies unless the host key is pinned
export def --env proxmox-ssh-init [src: path, ip: string, port: int, password: string = ""]: nothing -> list<string> {
    let known_hosts = (lab-files $src).known_hosts
    if (do { ^ssh-keygen -F (proxmox-pinned-host $ip $port) -f $known_hosts } | complete).exit_code != 0 {
        die ([
            "Proxmox's host key is not pinned in src/generated/known_hosts."
            $"       Run src/scripts/init.nu --pin ($ip) and compare the fingerprint on the Proxmox console."
        ] | str join "\n")
    }
    let ssh = [
        ssh -p ($port | into string) -o $"UserKnownHostsFile=($known_hosts)" -o StrictHostKeyChecking=yes
        -o $"ServerAliveInterval=($PROXMOX_SSH_ALIVE_INTERVAL_S)" -o $"ServerAliveCountMax=($PROXMOX_SSH_ALIVE_COUNT)"
    ]
    if $password == "" { return $ssh }
    tools-require sshpass
    # sshpass -e reads it from the environment: -p would show it in ps
    $env.SSHPASS = $password
    [sshpass -e] ++ $ssh
}

# the cluster CA (site.json) that the api's certificate chains to
export def proxmox-ca-write [src: path, file: path]: nothing -> nothing {
    let ca = open (lab-files $src).site | get --optional proxmoxCa
    if ($ca | is-empty) { die $"no proxmoxCa in (lab-files $src).site: run src/scripts/init.nu." }
    $ca | save --force $file
}

# "<token id>=<secret>" of a role, where its consumer reads it
def token-store [src: path, role: string, value: string]: nothing -> nothing {
    let id = $value | split row "=" | first
    let secret = $value | str substring (($id | str length) + 1)..
    match $role {
        "terraform" => {
            proxmox-tfvars-load $src | default {} | merge {proxmox_api_token_id: $id, proxmox_api_token_secret: $secret}
                | to json | secrets-encrypt ($src | path dirname) (lab-files $src).tfvars
        }
        "homepage" => {
            secrets-set $src proxmox-user $id
            secrets-set $src proxmox-pass $secret
        }
        $wake if ($wake | str starts-with "wake-") => {
            secrets-set $src $"proxmox-wake-token-($wake | str substring 5..)" $value
        }
        _ => { die $"Proxmox created a token for ($role), which nothing reads." }
    }
    print $">>> Proxmox: stored the new ($role) api token"
}

# scripts/pve-install.nu on the Debian host under the pinned nu, its inputs a json record on stdin, out of argv
export def proxmox-install-run [src: path, ssh: list<string>, host: string, action: string, inputs: record = {}]: nothing -> bool {
    let bootstrap = {NU: $PROXMOX_NU, VERSION: $PROXMOX_NU_VERSION, ASSET: $PROXMOX_NU_ASSET, URL: $PROXMOX_NU_URL, SHA256: $PROXMOX_NU_SHA256}
        | transpose name value | each { $"($in.name)=(sh-quote $in.value)\n" } | str join
    let installed = $"($bootstrap)($PROXMOX_NU_BOOTSTRAP)\n" | do { ^$ssh.0 ...($ssh | skip 1) $host "sh -s" } | complete
    print --no-newline $installed.stdout
    if $installed.exit_code != 0 {
        print -e $"ERROR: nu ($PROXMOX_NU_VERSION) did not install on the Proxmox host: ($installed.stderr | str trim)"
        return false
    }
    let all = {token_dir: $TOKEN_DIR, templates: [$PROXMOX_IMAGE $PROXMOX_LXC_TEMPLATE]} | merge $inputs
    let script = open --raw ($src | path join scripts pve-install.nu)
    let source = $script + "\n$in | main " + $action
    let run = $"($PROXMOX_NU) --no-config-file --stdin -c (sh-quote $source)"
    try { $all | to json | ^$ssh.0 ...($ssh | skip 1) $host $run; true } catch { false }
}

export def proxmox-teardown [src: path, ssh: list<string>, host: string]: nothing -> nothing {
    if not (proxmox-install-run $src $ssh $host teardown) { die "the Proxmox host was not torn down (above)." }
}

# scripts/pve-install.nu on the host, then the tokens it had to create stored and removed there
export def proxmox-converge [src: path, ssh: list<string>, user: string, lab_export: path, bulk_disk: string]: nothing -> nothing {
    let files = lab-files $src
    let site = open $files.site
    let exported = open $lab_export
    let host = $"($user)@($site.lan.proxmox)"
    let ldap = $exported.ldap? | default {}
    if not ([vmid host port baseDn adminGroup certFile bindUser] | all {|k| ($ldap | get --optional $k) != null }) {
        die "the lab export names no ldaps listener for the realm (modules/lab-export.nix, ldap)."
    }
    let bind_password = secrets-get $src lldap-proxmox-bind-password
    let root_password = secrets-get $src proxmox-root-pass
    if $bind_password == "" or $root_password == "" {
        die "lldap-proxmox-bind-password or proxmox-root-pass is empty: run src/scripts/secrets-sync.nu --apply."
    }
    let inputs = {
        proxmox_ip: $site.lan.proxmox
        zone_bridges: (open $files.zones | values | get bridge)
        wake_zones: ($exported.zones | transpose zone spec | where { $in.spec.ingress? != null } | get zone)
        gpu_ids: ($site.gpu?.functionIds? | default [])
        bulk_disk: $bulk_disk
        nas_id: $exported.routes.nas.vmid
        lldap: {
            vmid: $ldap.vmid, host: $ldap.host, port: $ldap.port, base_dn: $ldap.baseDn, admin_group: $ldap.adminGroup
            cert: $ldap.certFile, bind_user: $ldap.bindUser, bind_password: $bind_password
        }
        root_password: $root_password
        root_keys: (glob ($src | path join secrets keys *.pub) | sort | each { open --raw $in | str trim --right })
    }
    if not (proxmox-install-run $src $ssh $host converge $inputs) { die "the Proxmox host did not converge (above)." }

    let tokens = ^$ssh.0 ...($ssh | skip 1) -n $host ($TOKENS_LIST | str replace DIR $TOKEN_DIR)
    let listed = $tokens | lines | where $it != ""
    for line in $listed {
        let role = $line | split row " " | first
        token-store $src $role ($line | str substring (($role | str length) + 1)..)
    }
    if ($listed | is-not-empty) {
        let stored = $listed | each { split row " " | first | $"($TOKEN_DIR)/($in)" }
        ^$ssh.0 ...($ssh | skip 1) -n $host rm -f ...$stored
    }
}
