#!/usr/bin/env -S nu --no-config-file
# initialize the homelab against an existing proxmox ve: pin the host key, ask the site, make secrets, converge proxmox
#
# The pin is the root of every later ssh: sync.nu and deinit.nu refuse any other key for Proxmox, and read every
# guest's key through it. It is taken once, after the owner compared the fingerprint with the one the Proxmox console
# shows, never from the network alone.

const ROOT = path self | path dirname | path dirname | path dirname
const SRC = $ROOT | path join src
use lib/tools.nu [die run-text tools-require]
use lib/proxmox.nu [
    lab-files proxmox-pinned-host proxmox-ssh-init proxmox-converge proxmox-upgrade PROXMOX_SSH_PORT_DEFAULT
    PROXMOX_SSH_USER_DEFAULT
]
use lib/secrets.nu [secrets-age-key-ready secrets-set SECRETS_CATALOG_FILE]

const KEYSCAN_TIMEOUT_S = 5
# of the bulk disk's bytes, the thin pool and its metadata fit in this share
const BULK_POOL_SHARE = 0.96
const BYTES_PER_GIB = 1073741824
# the repo is public: a tenth of a degree (about 10 km) places the weather and the sun, not the house
const LOCATION_DECIMALS = 1
const NIX_FEATURES = [--extra-experimental-features "nix-command flakes"]

# Proxmox's ed25519 host key, confirmed against the console; every other line (the guests' keys) stays
def pin [ip: string, port: int]: nothing -> nothing {
    let known_hosts = (lab-files $SRC).known_hosts
    let pinned = proxmox-pinned-host $ip $port
    let scanned = do { ^ssh-keyscan -T $KEYSCAN_TIMEOUT_S -t ed25519 -p $port $ip } | complete | get stdout | lines
        | where { not ($in | str starts-with "#") and $in != "" }
    if ($scanned | is-empty) { die $"no ssh host key from ($ip):($port)" }
    let fingerprint = $scanned | str join "\n" | run-text ssh-keygen -lf - | split row " " | get 1
    print $">>> ($ip) presents the ssh host key ($fingerprint)"
    print "    On the Proxmox console (not over the network) run: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
    if (input $"    Does it print ($fingerprint)? Type 'yes' to pin it: ") != "yes" { die "Not pinned." }
    let others = if ($known_hosts | path exists) { open --raw $known_hosts | lines | where { not ($in | str starts-with $"($pinned) ") } } else { [] }
    let lines = $others ++ ($scanned | each { split row " " | $"($pinned) ($in.1) ($in.2)" })
    $lines | each { $"($in)\n" } | str join | save --force $"($known_hosts).new"
    mv --force $"($known_hosts).new" $known_hosts
    print ">>> Pinned in src/generated/known_hosts; commit it (sync.nu does)."
}

# Pin Proxmox's host key, ask the site, make the secrets and converge the host; --pin (re)pins the key only,
# --upgrade upgrades the host's packages only (a maintenance window: the host may need a reboot after it)
def main [proxmox_ip: string, --pin, --upgrade]: nothing -> nothing {
    tools-require ssh ssh-keyscan ssh-keygen
    if not ($pin or $upgrade) { tools-require sops git nix age-keygen }
    let port = $PROXMOX_SSH_PORT_DEFAULT
    let files = lab-files $SRC
    let pinned = (do { ^ssh-keygen -F (proxmox-pinned-host $proxmox_ip $port) -f $files.known_hosts } | complete).exit_code == 0
    if $pin or not $pinned { pin $proxmox_ip $port }
    if $pin { return }
    if $upgrade {
        proxmox-upgrade $SRC (proxmox-ssh-init $SRC $proxmox_ip $port) $"($PROXMOX_SSH_USER_DEFAULT)@($proxmox_ip)"
        return
    }

    print $">>> Initializing Lab on Proxmox at ($proxmox_ip)..."
    # a commit before the first sync gets the plaintext guard too
    ^git -C $ROOT config core.hooksPath .githooks

    let password = if ($env.HOMELAB_ROOT_PASSWORD? | is-not-empty) { $env.HOMELAB_ROOT_PASSWORD } else {
        print $">>> Enter root password for ($proxmox_ip) \(leave blank if using SSH keys\):"
        input --suppress-output "Password: "
    }
    print ""
    let ssh = proxmox-ssh-init $SRC $proxmox_ip $port $password
    let host = $"($PROXMOX_SSH_USER_DEFAULT)@($proxmox_ip)"
    let pve = {|command: string|
        let ran = do { ^$ssh.0 ...($ssh | skip 1) $host $command } | complete
        if $ran.exit_code != 0 { error make {msg: $"Proxmox at ($proxmox_ip) refused `($command)`: ($ran.stderr | str trim)"} }
        $ran.stdout | str trim
    }
    let version = try { do $pve pveversion } catch {
        die ([
            $"Cannot reach Proxmox at ($proxmox_ip)."
            "Ensure Proxmox VE is installed, the credentials are correct and the pinned key is its own (init.nu --pin)."
        ] | str join "\n")
    }
    print $">>> Connected to ($version)"

    # the machine and the house network, asked once and kept in src/generated/site.json for terraform, nix and sync.nu
    let site = if ($files.site | path exists) { open $files.site } else { {} }
    # enter keeps the default, "-" clears it
    let ask = {|question: string, current: any|
        let shown = $current | default "" | into string
        let answer = input $"($question) [(if $shown == '' { '-' } else { $shown })]: "
        match $answer { "" => $shown, "-" => "", _ => $answer }
    }
    print ">>> Site: enter keeps the value in brackets, '-' clears it"
    let lan_subnet = do $pve "ip -4 route show dev vmbr0 scope link" | lines | first | split row " " | first
    let lan_gateway = do $pve "ip -4 route show default" | lines | first | split row " " | get 2
    let route = run-text ip -4 route get $proxmox_ip
    let workstation = $route | parse --regex ' src (?<ip>[0-9.]+)' | get 0.ip
    let workstation_dev = $route | parse --regex ' dev (?<dev>\S+)' | get 0.dev
    let workstation_mac = run-text ip -o link show $workstation_dev | parse --regex 'link/ether (?<mac>[0-9a-f:]+)' | get 0.mac
    let domain = do $ask "public domain, every service is <name>.<domain>" $site.domain?
    let time_zone = do $ask "the house's time zone (tz database name)" $site.timeZone?
    let latitude = do $ask "the house's latitude (weather and sun times)" $site.location?.latitude?
    let longitude = do $ask "the house's longitude" $site.location?.longitude?
    let repo = do $ask "this repository on github (owner/name), which hermes opens pull requests on" $site.repo?
    let router = do $ask "router address on the lan (forward 443 and 25565, the minecraft hosts *.mc, to it)" $site.lan?.router?
    let inverter = do $ask "fronius inverter address" $site.lan?.inverter?
    # vm-104's smb shares admit the workstation and the notebook, both dhcp-reserved in the fritzbox
    let notebook = do $ask "notebook address on the lan" $site.lan?.notebook?

    print ">>> GPUs on the host:"
    do $pve "lspci -nn -D" | lines | where $it =~ 'VGA|3D controller' | enumerate | each { print $"($in.index + 1 | fill --alignment right --width 2)) ($in.item)" } | ignore
    let gpu_path = do $ask "gpu to pass through to jellyfin (pci path)" $site.gpu?.path?

    print ">>> Disks on the host (the nvme pool is local-lvm; the bulk disk gets wiped once):"
    print (do $pve "lsblk -dno NAME,SIZE,ROTA,MODEL; ls -l /dev/disk/by-id/ | grep -v -- -part | awk '/ata-|nvme-|scsi-/ {print $9, $11}'")
    # the disk itself is the host's business and stays out of the public repo; only the pool's size is a lab fact
    let bulk_disk = do $ask "bulk disk for media, wiped once (/dev/disk/by-id/...); blank keeps the bulk pool as it is" ""

    let gpu = if $gpu_path == "" { null } else {
        let id_of = {|path: string| do $pve $"lspci -n -s ($path)" | lines | each { split row " " | get 2 } }
        let vmm = do $pve $"lspci -vmmn -s ($gpu_path)" | lines | parse "{key}:\t{value}"
        {
            id: (do $id_of $gpu_path | first)
            subsystemId: $"($vmm | where key == SVendor | get 0.value):($vmm | where key == SDevice | get 0.value)"
            path: $gpu_path
            iommuGroup: (do $pve $"basename $\(readlink /sys/bus/pci/devices/($gpu_path)/iommu_group\)" | into int)
            functionIds: (do $id_of ($gpu_path | str replace --regex '\.[^.]*$' ''))
        }
    }
    # a pool in use keeps its size, terraform cannot shrink
    let bulk = if $bulk_disk != "" and $site.bulk? == null {
        {sizeGiB: ((do $pve $"lsblk -dbno SIZE ($bulk_disk)" | into int) / $BYTES_PER_GIB * $BULK_POOL_SHARE | math floor)}
    } else { $site.bulk? }
    # merged into what is there: keys this script does not ask for stay
    let lan = $site.lan? | default {} | reject --optional workstationMac | merge {
        subnet: $lan_subnet, gateway: $lan_gateway, router: $router, proxmox: $proxmox_ip, workstation: $workstation
        inverter: $inverter, notebook: $notebook
    }
    $site | merge {
        node: (do $pve hostname)
        domain: $domain
        timeZone: $time_zone
        repo: $repo
        location: ($site.location? | default {} | merge {
            latitude: ($latitude | into float | math round --precision $LOCATION_DECIMALS)
            longitude: ($longitude | into float | math round --precision $LOCATION_DECIMALS)
        })
        lan: $lan
        gpu: $gpu
        bulk: $bulk
        # the cluster ca, read over the pinned ssh: hosts that call the proxmox api verify its tls against it
        proxmoxCa: (do $pve "cat /etc/pve/pve-root-ca.pem")
    } | to json --indent 2 | $"($in)\n" | save --force $"($files.site).new"
    mv --force $"($files.site).new" $files.site
    print $">>> Wrote ($files.site)"

    # the age key's source of truth is the dotfiles repo; src/secrets/admins.txt lists its public key
    secrets-age-key-ready ($ROOT | path join secrets age.txt)

    print ">>> Generating secrets..."
    # a repo without the shared values never deployed, so nothing is guarded yet; later a missing guarded value stops here
    let guarded = if ($SRC | path join $SECRETS_CATALOG_FILE | path exists) { [] } else { [--generate-guarded] }
    ^nu --no-config-file ($SRC | path join scripts secrets-sync.nu) --apply ...$guarded
    # a device identity: the router's secret, not the public site.json
    secrets-set $SRC workstation-mac $workstation_mac

    let images = $ROOT | path join images
    mkdir $images
    if not ($images | path join nixos.img | path exists) {
        print ">>> Building NixOS golden image..."
        ^sudo nix build $"($SRC)#cloud-image" ...$NIX_FEATURES -o ($images | path join nixos-build)
        let image = ^sudo find -L ($images | path join nixos-build) "(" -name "*.qcow2" -o -name "*.img" ")" | lines | first
        ^sudo cp --dereference $image ($images | path join nixos.img)
        ^sudo chown $"(run-text id -un):(run-text id -gn)" ($images | path join nixos.img)
        ^sudo rm -rf ($images | path join nixos-build)
    }

    print ">>> Converging Proxmox..."
    let lab_export = mktemp --tmpdir --suffix .lab.json
    run-text nix eval --json --no-warn-dirty $"($SRC)#lab.export" | save --force $lab_export
    # a rerun keeps the tokens: the converge creates only missing ones, and stores those in the tfvars and secrets
    proxmox-converge $SRC $ssh $PROXMOX_SSH_USER_DEFAULT $lab_export $bulk_disk
    rm --force $lab_export

    print ">>> INIT COMPLETE!"
    print ">>> External secrets (cloudflare-token, telegram-*, ...): fill the empty ones secrets-sync.nu listed with 'sops <file>'"
    print ">>> Next step: ./sync.nu"
}
