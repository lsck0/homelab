terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.70.0"
    }
  }
}

# -----------------------------------------------------------------------------
# SITE: the machine and the house network, written by scripts/init.sh
locals {
  site = jsondecode(file("${path.module}/site.json"))
}

# -----------------------------------------------------------------------------
# PROXMOX CONNECTION
variable "proxmox_api_token_id" { type = string }
variable "proxmox_api_token_secret" {
  type      = string
  sensitive = true
}
variable "proxmox_insecure" {
  type    = bool
  default = false
}
variable "proxmox_datastore" {
  type    = string
  default = "local-lvm"
}
variable "proxmox_ssh_port" {
  type    = number
  default = 22
}
variable "proxmox_ssh_user" {
  type    = string
  default = "root"
}
variable "proxmox_ssh_password" {
  type      = string
  sensitive = true
  default   = null
}

# -----------------------------------------------------------------------------
# VM DEFAULTS
variable "nixos_lxc_template" {
  description = "NixOS container template (sync.sh uploads packages.lxc-template)."
  type        = string
  default     = "local:vztmpl/nixos-homelab.tar.xz"
}

variable "nixos_image_id" {
  type    = string
  default = "local:iso/nixos.img"
}

# -----------------------------------------------------------------------------
# NETWORK BRIDGES
variable "wan_bridge" {
  type    = string
  default = "vmbr0"
}
# -----------------------------------------------------------------------------
# ZONES: an instance's type picks its bridge, subnet and gateway; its id is the host part of its address
# internal: sso apps behind authelia (vm-100). external: public apps behind the edge (vm-200).
# apps: the swarm cluster, a dmz of its own: reached only through the two ingresses, never reaching inward.
variable "zones" {
  type = map(object({
    bridge    = string
    subnet    = string
    router_ip = string
  }))
  default = {
    internal = { bridge = "vmbr100", subnet = "10.100.0.0/24", router_ip = "10.100.0.1" }
    external = { bridge = "vmbr200", subnet = "10.200.0.0/24", router_ip = "10.200.0.1" }
    apps     = { bridge = "vmbr150", subnet = "10.150.0.0/24", router_ip = "10.150.0.1" }
  }
}

# the router's nics after wan, in order: they appear as ens19, ens20, ens21 in 300-router.nix
variable "router_zones" {
  type    = list(string)
  default = ["internal", "external", "apps"]
}

provider "proxmox" {
  endpoint  = "https://${local.site.lan.proxmox}:8006/api2/json"
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = var.proxmox_insecure

  ssh {
    # provider imports new vm disks over ssh
    agent    = var.proxmox_ssh_password == null || var.proxmox_ssh_password == ""
    username = var.proxmox_ssh_user
    password = var.proxmox_ssh_password == "" ? null : var.proxmox_ssh_password
    node {
      name    = local.site.node
      address = local.site.lan.proxmox
      port    = var.proxmox_ssh_port
    }
  }
}
