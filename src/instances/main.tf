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
    "103" = { name = "103-internal-uptime-kuma", type = "internal" }
    "104" = { name = "104-internal-grafana", type = "internal" }
    "105" = { name = "105-internal-forgejo", type = "internal" }
    "106" = { name = "106-internal-forgejo-runner", type = "internal" }
    "107" = { name = "107-internal-sccache", type = "internal" }
    "108" = { name = "108-internal-registry", type = "internal" }
    "109" = { name = "109-internal-taskchampion", type = "internal" }
    "110" = { name = "110-internal-vaultwarden", type = "internal" }
    "111" = { name = "111-internal-nas", type = "internal", disk = 500 }
    "112" = { name = "112-internal-nextcloud", type = "internal" }
    "113" = { name = "113-internal-qbittorrent", type = "internal" }
    "114" = { name = "114-internal-prowlarr", type = "internal" }
    "115" = { name = "115-internal-sonarr", type = "internal" }
    "116" = { name = "116-internal-radarr", type = "internal" }
    "117" = { name = "117-internal-jellyfin", type = "internal" }
    "118" = { name = "118-internal-audiobookshelf", type = "internal" }
    "119" = { name = "119-internal-paperless", type = "internal" }
    "120" = { name = "120-internal-wikijs", type = "internal" }
    "121" = { name = "121-internal-huginn", type = "internal" }
    "122" = { name = "122-internal-homeassistant", type = "internal" }
    "123" = { name = "123-internal-navidrome", type = "internal" }
    "124" = { name = "124-internal-kavita", type = "internal" }
    # ── external ──
    "200" = { name = "200-external-traefik", type = "external" }
    "201" = { name = "201-external-headscale", type = "external" }
    "202" = { name = "202-external-shlink", type = "external" }
    "203" = { name = "203-external-privatebin", type = "external" }
    "204" = { name = "204-external-share", type = "external" }
    "205" = { name = "205-external-minecraft", type = "external", memory = 4096, cores = 6 }
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
