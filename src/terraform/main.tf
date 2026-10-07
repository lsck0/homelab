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
  # the working copy sync.sh pulls from and pushes to the nas (scripts/lib/tfstate.sh); its path, outside the flake
  # tree, comes from sync.sh's `terraform init -backend-config`
  backend "local" {}
}

# the lab's source tree: the flake, the facts init.sh writes (generated/) and the ssh keys (lab/keys)
locals {
  src = "${path.module}/.."
}

# -----------------------------------------------------------------------------
# SITE: the machine and the house network, written by scripts/init.sh to src/generated/site.json
locals {
  site             = jsondecode(file("${local.src}/generated/site.json"))
  proxmox_api_port = 8006
}

# -----------------------------------------------------------------------------
# PROXMOX CONNECTION
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
# ZONES: src/generated/zones.json, read by nix too (modules/net.nix): an instance's type picks its zone's bridge.
# internal: sso apps behind authelia (vm-100). external: public apps behind the edge (vm-200). apps: the swarm
# workers, a dmz of their own, reached only through the two ingresses and never reaching inward.
# router_nic: the router's proxmox nic in the zone (net0 is the wan).
locals {
  zones = jsondecode(file("${local.src}/generated/zones.json"))
}

# tls verified against the cluster CA: sync.sh points SSL_CERT_FILE at site.json's proxmoxCa, and the node
# certificate names the host's address (scripts/pve-install.sh)
provider "proxmox" {
  endpoint  = "https://${local.site.lan.proxmox}:${local.proxmox_api_port}/api2/json"
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"

  ssh {
    # provider imports new vm disks over ssh, with the deploy key sync.sh loads into the agent: a password would be
    # a second copy of root's, which scripts/pve-install.sh sets (proxmox-root-pass)
    agent    = true
    username = var.proxmox_ssh_user
    node {
      name    = local.site.node
      address = local.site.lan.proxmox
      port    = var.proxmox_ssh_port
    }
  }
}
