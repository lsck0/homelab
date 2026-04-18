# Homelab IaC

Declarative homelab. Proxmox + NixOS, managed entirely through Terraform and Nix.

## Architecture

- **Hypervisor:** Proxmox VE
- **Router (vm-300):** NixOS — nftables, NAT, CoreDNS, Kea DHCP, WireGuard
- **OS:** NixOS on every instance
- **Networks:**
  - `10.100.0.0/24` — Internal: reverse proxy + all homelab services
  - `10.200.0.0/24` — External DMZ: isolated, public-facing apps
  - `10.0.0.0/24` — WireGuard VPN
- **Isolation:** DMZ cannot reach internal or local network
- **DNS:** CoreDNS on router — `*.internal.local` → vm-100 (Traefik), `*.external.local` → vm-200 (Traefik)
- **SSO:** Authentik forward auth on Traefik for internal services
- **Port forwarding:** Router `10100->vm-100:443`, `10200->vm-200:443`, `25565->vm-200:25565`

### VM Layout

| VM  | IP           | Role                                  |
| --- | ------------ | ------------------------------------- |
| 100 | 10.100.0.100 | Traefik reverse proxy (Authentik SSO) |
| 101 | 10.100.0.101 | Authentik                             |
| 102 | 10.100.0.102 | Homepage                              |
| 103 | 10.100.0.103 | Forgejo                               |
| 104 | 10.100.0.104 | Forgejo Runner                        |
| 105 | 10.100.0.105 | Docker Registry                       |
| 106 | 10.100.0.106 | Nextcloud                             |
| 107 | 10.100.0.107 | Vaultwarden                           |
| 108 | 10.100.0.108 | Paperless                             |
| 109 | 10.100.0.109 | Home Assistant                        |
| 110 | 10.100.0.110 | Jellyfin                              |
| 111 | 10.100.0.111 | Uptime Kuma                           |
| 112 | 10.100.0.112 | Huginn                                |
| 113 | 10.100.0.113 | PrivateBin                            |
| 114 | 10.100.0.114 | Taskchampion                          |
| 115 | 10.100.0.115 | Hello world (test)                    |
| 116 | 10.100.0.116 | NAS (Samba)                           |
| 117 | 10.100.0.117 | Shared sccache Redis backend          |
| 200 | 10.200.0.200 | Traefik external reverse proxy        |
| 201 | 10.200.0.201 | Hello world (external)                |
| 202 | 10.200.0.202 | Hello world (external)                |
| 203 | 10.200.0.203 | Hello world (external)                |
| 204 | 10.200.0.204 | Minecraft (Forge modpack)             |
| 300 | DHCP (WAN)   | NixOS Router                          |
| 301 | DHCP (LAN)   | Grafana + Prometheus system metrics   |

### Defaults

Default VM profile: 2 cores, 1 GB RAM, 8 GB disk (Grafana VM uses a larger profile in `vm_local`).

## Project Structure

```
scripts/init.sh         One-time bootstrap (Proxmox + image + tfvars)
sync.sh                 Deploy everything (Terraform + NixOS)

src/                 Terraform root & NixOS entrypoint
  main.tf               (includes Terraform variables)
  secrets.yaml          Encrypted sops-nix secrets
  terraform.tfvars.sops.json  Encrypted Terraform connection/config vars
  terraform.tfstate     Terraform state (tracked in git)
  flake.nix             NixOS flake (auto-discovers 1XX/2XX + special 300-router and 301-grafana)
  # shared NixOS base config is inlined in flake.nix

src/instances/        Per-instance `.tf` + `.nix` definitions
src/modules/          Reusable TF modules (vm_*, plus shared vm base module)
src/modules/docker-stack.nix  Docker Compose deployment module

scripts/
  pve-install.sh        Proxmox bridge + API token setup
  deinit.sh             Reset Proxmox host for fresh init
```

## Quick Start

### Prerequisites

`nix`, `sops`, `terraform`, `age`, `jq`, `openssl`, `sshpass` (if using password auth)

### 1. Initialize

Only input needed: Proxmox IP and root password. Everything else (SSH keys, age keys, secrets, golden image, API tokens) is auto-generated.

```bash
./scripts/init.sh 192.168.178.200
```

`scripts/init.sh` writes encrypted Terraform vars to `src/terraform.tfvars.sops.json` (committable). Keep only `keys/age.txt` out of git.

### 2. Deploy

```bash
./sync.sh
```

Re-run `sync.sh` after any `.tf` or `.nix` change.
By default `sync.sh` also runs auto-git steps (pull/submodules before sync, then add/commit/push after success). Disable with `HOMELAB_AUTO_GIT=0 ./sync.sh`.

### Reset Proxmox and start over

```bash
./scripts/deinit.sh --yes
./scripts/init.sh 192.168.178.200
```

### 3. Home router setup (manual, one-time)

Configure your home router to:

- Route `10.100.0.0/24` and `10.200.0.0/24` through the luca-router VM's WAN IP
- Port-forward external traffic to `luca-router:10100` (internal HTTPS) and `luca-router:10200` (external HTTPS)

## Adding a New VM

Step-by-step guide to add a new VM to the homelab.

### 1. Pick an ID

Choose the next available VM ID. Internal services use the `1XX` range (e.g. `115`), external/DMZ services use `2XX`. The VM ID determines the IP: ID `115` gets `10.100.0.115`.

### 2. Create the Terraform file

Create `src/instances/115-internal-my-service.tf`:

```hcl
module "vm_115" {
  source  = "../modules/vm_internal"   # or vm_external for DMZ
  globals = var.globals
  vm_id   = 115
  name    = "my-service"
}

output "ip_115" { value = module.vm_115.ipv4_address }
```

Sizing defaults are centralized in `src/modules/vm/main.tf`.

### 3. Create the NixOS config

Create `src/instances/115-internal-my-service.nix`. The flake auto-discovers `1XX-internal-*.nix`, `2XX-external-*.nix`, `300-router.nix`, and `301-grafana.nix`.

**Option A: Native NixOS service**

```nix
{ ... }: {
  networking.hostName = "vm-115";

  services.my-service = {
    enable = true;
    # ... service-specific config
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
```

**Option B: Docker container (OCI)**

```nix
{ ... }: {
  networking.hostName = "vm-115";

  virtualisation.oci-containers.containers.my-service = {
    image = "myimage:latest";
    ports = [ "80:8080" ];
    volumes = [ "/var/lib/my-service:/data" ];
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
```

**Option C: Docker Compose stack (inline)**

```nix
{ ... }: {
  networking.hostName = "vm-115";

  homelab.dockerStack = {
    enable = true;
    stackName = "my-service";
    composeFile = ''
      services:
        app:
          image: myimage:latest
          ports:
            - "80:8080"
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
```

**Option D: Docker Compose from a git repo**

```nix
{ ... }: {
  networking.hostName = "vm-115";

  homelab.dockerStack = {
    enable = true;
    stackName = "my-service";
    gitRepo = "https://github.com/user/repo.git";
    gitBranch = "main";              # optional, defaults to repo default
    composePath = "deploy";          # optional, subdirectory in repo
    composeFilename = "compose.yml"; # optional, defaults to docker-compose.yaml
    pollInterval = "10m";            # optional, defaults to 5m
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
```

### 4. Register the output

Add the VM to `src/instances/outputs.tf`:

```hcl
"115" = module.vm_115.ipv4_address
```

### 5. Add a Traefik route (optional)

If the service should be reachable via a hostname, add a router and service entry to the Traefik config in `src/instances/100-internal-traefik.nix` (internal) or `src/instances/200-external-traefik.nix` (external):

```nix
# In routers:
my-service = {
  rule = "Host(`my-service.internal`)";
  service = "my-service";
  entryPoints = [ "websecure" ];
  tls.certResolver = "cloudflare";
  middlewares = [ "authentik" ];  # remove for no SSO
};

# In services:
my-service.loadBalancer.servers = [{ url = "http://10.100.0.115:80"; }];
```

### 6. Add secrets (optional)

If the service needs secrets, add them to `src/secrets.yaml` and reference via sops:

```nix
{ config, ... }: {
  sops.secrets.my-secret = {};
  # Use: config.sops.secrets.my-secret.path
}
```

### 7. Stage and deploy

```bash
git add -A
./sync.sh
```

The flake auto-discovers new instance nix files (`1XX-internal-*`, `2XX-external-*`, plus `300-router` and `301-grafana`), Terraform creates the VM, and sync.sh deploys the NixOS config.

## Secrets

Encrypted with [sops-nix](https://github.com/Mic92/sops-nix). Edit: `sops src/secrets.yaml`. WireGuard keys auto-generated on router first boot (`wg show` to get public key).

## Shared sccache setup

Shared backend runs on `vm-117` via Redis (`redis://10.100.0.117:6379`).

For your local machine:

```bash
export SCCACHE_REDIS=redis://10.100.0.117:6379
export RUSTC_WRAPPER=sccache
```

For Forgejo runner jobs, set the same env vars in your workflow/job container and ensure `sccache` is installed in that build environment.
