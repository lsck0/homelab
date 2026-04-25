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
    # ── internal ──
    "100" = { name = "100-internal-traefik", type = "internal" }
    "101" = { name = "101-internal-authentik", type = "internal", memory = 4096 }
    "102" = { name = "102-internal-homepage", type = "internal" }
    "103" = { name = "103-internal-grafana", type = "internal" }
    "104" = { name = "104-internal-uptime-kuma", type = "internal" }
    "105" = { name = "105-internal-nas", type = "internal", disk = 750 }
    "106" = { name = "106-internal-sccache", type = "internal" }
    "107" = { name = "107-internal-forgejo", type = "internal" }
    "108" = { name = "108-internal-forgejo-runner", type = "internal" }
    "109" = { name = "109-internal-registry", type = "internal" }
    "110" = { name = "110-internal-taskchampion", type = "internal" }
    "111" = { name = "111-internal-vaultwarden", type = "internal" }
    "112" = { name = "112-internal-nextcloud", type = "internal" }
    "113" = { name = "113-internal-paperless", type = "internal" }
    "114" = { name = "114-internal-huginn", type = "internal", enabled = true }
    "115" = { name = "115-internal-homeassistant", type = "internal", enabled = true }
    "116" = { name = "116-internal-wikijs", type = "internal", enabled = true }
    "117" = { name = "117-internal-qbittorrent", type = "internal", enabled = true }
    "118" = { name = "118-internal-prowlarr", type = "internal", enabled = true }
    "119" = { name = "119-internal-radarr", type = "internal", enabled = true }
    "120" = { name = "120-internal-sonarr", type = "internal", enabled = true }
    "121" = { name = "121-internal-jellyfin", type = "internal", enabled = true }
    "122" = { name = "122-internal-audiobookshelf", type = "internal", enabled = true }
    "123" = { name = "123-internal-navidrome", type = "internal", enabled = true }
    "124" = { name = "124-internal-kavita", type = "internal", enabled = true }
    # ── external ──
    "200" = { name = "200-external-traefik", type = "external" }
    "201" = { name = "201-external-headscale", type = "external" }
    "202" = { name = "202-external-searxng", type = "external" }
    "203" = { name = "203-external-shlink", type = "external" }
    "204" = { name = "204-external-privatebin", type = "external" }
    "205" = { name = "205-external-share", type = "external" }
    "207" = { name = "207-external-minecraft", type = "external", memory = 12288, cores = 8 }
    "208" = { name = "208-external-hello", type = "external" }
    # ── router ──
    "300" = { name = "luca-router", type = "router" }
  }
}

module "vm" {
  source   = "../modules/vm"
  for_each = local.instances

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
