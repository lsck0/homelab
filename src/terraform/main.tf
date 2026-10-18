terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.70.0"
    }
    # lib.tf reads the guests from nix through it
    external = {
      source  = "hashicorp/external"
      version = "2.3.5"
    }
  }
  # the working copy sync.nu pulls from and pushes to the nas (scripts/lib/tfstate.nu); its path, outside the flake
  # tree, comes from sync.nu's `terraform init -backend-config`
  backend "local" {}
}

# the lab's source tree: the flake, the facts init.nu writes (generated/) and the ssh keys (secrets/keys)
locals {
  src = "${path.module}/.."
}

# the machine and the house network, written by scripts/init.nu
locals {
  site             = jsondecode(file("${local.src}/generated/site.json"))
  proxmox_api_port = 8006
}

# -----------------------------------------------------------------------------
# PROXMOX CONNECTION
# -----------------------------------------------------------------------------

variable "proxmox_api_token_id" { type = string }
variable "proxmox_api_token_secret" {
  type      = string
  sensitive = true
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

# -----------------------------------------------------------------------------
# VM DEFAULTS
# -----------------------------------------------------------------------------

variable "nixos_lxc_template" {
  description = "NixOS container template (sync.nu uploads packages.lxc-template)."
  type        = string
  default     = "local:vztmpl/nixos-homelab.tar.xz"
}

variable "nixos_image_id" {
  type    = string
  default = "local:iso/nixos.img"
}

variable "wan_bridge" {
  type    = string
  default = "vmbr0"
}

# read by nix too (modules/net.nix): an instance's type picks its zone's bridge; router_nic is the router's proxmox nic
# in the zone (net0 is the wan)
locals {
  zones = jsondecode(file("${local.src}/generated/zones.json"))
}

# tls verified against the cluster CA: sync.nu points SSL_CERT_FILE at site.json's proxmoxCa, and the node
# certificate names the host's address (scripts/pve-install.nu)
provider "proxmox" {
  endpoint  = "https://${local.site.lan.proxmox}:${local.proxmox_api_port}/api2/json"
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"

  ssh {
    # provider imports new vm disks over ssh, with the deploy key sync.nu loads into the agent: a password would be
    # a second copy of root's, which scripts/pve-install.nu sets (proxmox-root-pass)
    agent    = true
    username = var.proxmox_ssh_user
    node {
      name    = local.site.node
      address = local.site.lan.proxmox
      port    = var.proxmox_ssh_port
    }
  }
}
