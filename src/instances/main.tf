terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

variable "target_node" { type = string }
variable "proxmox_datastore" { type = string }
variable "ssh_public_key" { type = string }
variable "nixos_image_id" { type = string }
variable "wan_bridge" { type = string }
variable "internal_bridge" { type = string }
variable "internal_subnet" { type = string }
variable "router_internal_ip" { type = string }
variable "external_bridge" { type = string }
variable "external_subnet" { type = string }
variable "router_external_ip" { type = string }

locals {
  instances = {
    # ── internal ── (10.100.0.0/24; reachable via internal Traefik, Authelia-gated)
    "100" = { name = "100-internal-traefik", type = "internal" }                                                                                            # internal reverse proxy: TLS/ACME + Authelia ForwardAuth + on-demand proxy
    "102" = { name = "102-internal-homepage", type = "internal" }                                                                                           # dashboard / service landing page
    "103" = { name = "103-internal-grafana", type = "internal" }                                                                                            # observability: Prometheus + Loki + Tempo + Alertmanager + Grafana
    "104" = { name = "104-internal-uptime-kuma", type = "internal" }                                                                                        # uptime/status monitoring
    "105" = { name = "105-internal-nas", type = "internal", memory = 2048, disk = 750 }                                                                     # storage: NFS + SMB + Syncthing + FileBrowser + backups
    "106" = { name = "106-internal-sccache", type = "internal" }                                                                                            # shared Rust/C++ compile cache
    "107" = { name = "107-internal-forgejo", type = "internal" }                                                                                            # git forge (OIDC + SSH)
    "108" = { name = "108-internal-forgejo-runner", type = "internal" }                                                                                     # CI runner for Forgejo
    "109" = { name = "109-internal-registry", type = "internal" }                                                                                           # Docker image registry + UI (internal-only)
    "110" = { name = "110-internal-taskchampion", type = "internal", enabled = false }                                                                      # Taskwarrior sync server (headless API)
    "111" = { name = "111-internal-vaultwarden", type = "internal", enabled = false }                                                                       # password manager (Bitwarden-compatible)
    "112" = { name = "112-internal-nextcloud", type = "internal", enabled = false }                                                                         # files / groupware cloud
    "113" = { name = "113-internal-paperless", type = "internal", enabled = false }                                                                         # document management (paperless-ngx)
    "114" = { name = "114-internal-huginn", type = "internal", enabled = false }                                                                            # automation agents / scraping
    "115" = { name = "115-internal-homeassistant", type = "internal", enabled = false }                                                                     # home automation hub
    "116" = { name = "116-internal-wikijs", type = "internal", enabled = false }                                                                            # wiki / knowledge base
    "117" = { name = "117-internal-qbittorrent", type = "internal", enabled = false }                                                                       # torrent client (egress via tor-router)
    "118" = { name = "118-internal-prowlarr", type = "internal", enabled = false }                                                                          # indexer manager for the *arr stack
    "119" = { name = "119-internal-radarr", type = "internal", enabled = false }                                                                            # movie library manager
    "120" = { name = "120-internal-sonarr", type = "internal", enabled = false }                                                                            # TV library manager
    "121" = { name = "121-internal-jellyfin", type = "internal", enabled = false }                                                                          # media streaming server
    "122" = { name = "122-internal-audiobookshelf", type = "internal", enabled = false }                                                                    # audiobook / podcast server
    "123" = { name = "123-internal-navidrome", type = "internal", enabled = false }                                                                         # music streaming (Subsonic API)
    "124" = { name = "124-internal-kavita", type = "internal", enabled = false }                                                                            # manga / ebook reader
    "125" = { name = "125-internal-paperless-ai", type = "internal", memory = 2048, enabled = false }                                                       # AI auto-tagging for paperless
    "126" = { name = "126-internal-hermes", type = "internal", memory = 12288, cores = 8, disk = 60, enabled = false, machine = "q35", hostpci = ["gpu"], } # GPU LLM agent (Ollama on the passed-through RTX 2060)
    "127" = { name = "127-internal-tor-router", type = "internal", enabled = false }                                                                        # Tor SOCKS gateway for qbittorrent egress
    "128" = { name = "128-internal-authelia", type = "internal" }                                                                                           # SSO: OIDC provider + ForwardAuth (backed by lldap)
    "129" = { name = "129-internal-calendar", type = "internal", enabled = false }                                                                          # synced calendar feeds (Outlook/StudIP/Proton → TRMNL)
    "131" = { name = "131-internal-attic", type = "internal", disk = 40 }                                                                                   # Nix binary cache (substituter)
    "132" = { name = "132-internal-smtp", type = "internal", enabled = true }                                                                               # Postfix null-client SMTP relay
    "133" = { name = "133-internal-lldap", type = "internal" }                                                                                              # LDAP identity store + admin dashboard (users/groups)
    "135" = { name = "135-internal-actual", type = "internal", onDemand = true }                                                                            # Actual Budget (on-demand)
    "136" = { name = "136-internal-jellyseerr", type = "internal" }                                                                                         # media request portal
    "137" = { name = "137-internal-bazarr", type = "internal" }                                                                                             # subtitle downloader for *arr
    "138" = { name = "138-internal-recyclarr", type = "internal" }                                                                                          # syncs TRaSH-guide configs into radarr/sonarr
    "139" = { name = "139-internal-mosquitto", type = "internal" }                                                                                          # MQTT broker (Home Assistant / IoT)
    "140" = { name = "140-internal-firefly", type = "internal", onDemand = true }                                                                           # Firefly III personal finance (on-demand)

    # ── external ── (10.200.0.0/24 DMZ; public via external Traefik, CrowdSec/Anubis/WAF)
    "200" = { name = "200-external-traefik", type = "external" }                                               # public reverse proxy: TLS + CrowdSec + Anubis + WAF + internal relay
    "201" = { name = "201-external-headscale", type = "external" }                                             # Tailscale control server (VPN mesh)
    "202" = { name = "202-external-searxng", type = "external", onDemand = true }                              # privacy metasearch (on-demand)
    "203" = { name = "203-external-shlink", type = "external" }                                                # URL shortener
    "204" = { name = "204-external-privatebin", type = "external", onDemand = true }                           # encrypted pastebin (on-demand)
    "205" = { name = "205-external-share", type = "external", onDemand = true }                                # public file sharing / FileBrowser (on-demand)
    "207" = { name = "207-external-minecraft", type = "external", memory = 20480, cores = 8, onDemand = true } # Minecraft server (on-demand)
    "206" = { name = "206-external-ntfy", type = "external" }                                                  # push notifications (alert delivery)
    "208" = { name = "208-external-hello", type = "external" }                                                 # demo app / Docker Swarm test target
    "209" = { name = "209-external-tor-relay", type = "external", enabled = false }                            # non-exit Tor relay

    # ── router ──
    "300" = { name = "luca-router", type = "router" } # gateway: NAT + nftables firewall + Kea DHCP + CoreDNS/blocky + WireGuard + DDNS
  }
}

# PCI hardware mapping for the RTX 2060. A mapping (not a raw PCI id) is what
# lets the Terraform API token attach the GPU to a VM; raw hostpci is root-only.
resource "proxmox_virtual_environment_hardware_mapping_pci" "gpu" {
  name = "gpu"
  map = [{
    node = var.target_node
    id   = "10de:1f08"
    path = "0000:2b:00.0"
  }]
}

module "vm" {
  source   = "../modules/vm"
  for_each = local.instances

  # The GPU mapping must exist before a VM can reference it by name.
  depends_on = [proxmox_virtual_environment_hardware_mapping_pci.gpu]

  vm_id        = tonumber(each.key)
  name         = each.value.name
  target_node  = var.target_node
  datastore_id = var.proxmox_datastore
  cores        = try(each.value.cores, 2)
  memory       = try(each.value.memory, 1024)
  disk         = try(each.value.disk, 8)
  enabled      = try(each.value.enabled, true)
  image_id     = var.nixos_image_id
  ssh_key      = var.ssh_public_key
  machine      = try(each.value.machine, null)
  hostpci      = try(each.value.hostpci, [])

  bridge = (
    each.value.type == "router" ? var.wan_bridge :
    each.value.type == "local" ? var.wan_bridge :
    each.value.type == "external" ? var.external_bridge :
    var.internal_bridge
  )

  extra_bridges = (
    each.value.type == "router" ? [var.internal_bridge, var.external_bridge] : []
  )

  ip_cidr = (
    each.value.type == "router" ? "192.168.178.29/24" :
    each.value.type == "local" ? "dhcp" :
    each.value.type == "external" ? "${cidrhost(var.external_subnet, tonumber(each.key))}/${split("/", var.external_subnet)[1]}" :
    "${cidrhost(var.internal_subnet, tonumber(each.key))}/${split("/", var.internal_subnet)[1]}"
  )

  gw = (
    each.value.type == "router" ? "192.168.178.1" :
    each.value.type == "local" ? null :
    each.value.type == "external" ? var.router_external_ip :
    var.router_internal_ip
  )
}

output "vm_ips" {
  value = join("\n", [for k, v in module.vm : "${k}=${split("/", v.ipv4_address)[0]}"])
}

output "disabled_vms" {
  value = join("\n", [for k, v in local.instances : k if try(v.enabled, true) == false])
}

output "on_demand_vms" {
  value = join("\n", [for k, v in local.instances : k if try(v.onDemand, false)])
}
