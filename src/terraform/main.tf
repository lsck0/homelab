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
  # the working copy sync.sh pulls from and pushes to the nas (scripts/lib/tfstate.sh); relative to src/terraform
  backend "local" {
    path = "../generated/terraform/terraform.tfstate"
  }
}

# the lab's source tree: the flake, the facts init.sh writes (generated/) and the ssh keys (lab/keys)
locals {
  src = "${path.module}/.."
}

# -----------------------------------------------------------------------------
# SITE: the machine and the house network, written by scripts/init.sh to src/generated/site.json
locals {
  site = jsondecode(file("${local.src}/generated/site.json"))
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

# -----------------------------------------------------------------------------
# PROXMOX FIREWALL: anti-spoofing, see lib.tf FIREWALL and the README for the activation order
variable "proxmox_firewall" {
  description = "Turn the datacenter firewall on, which activates the per-guest ip and mac filters terraform keeps in place."
  type        = bool
  default     = false
}
variable "proxmox_host_input_policy" {
  description = "Policy for traffic to the proxmox host itself once the firewall is on; the host rules in lib.tf keep ssh, the api and the scrape open."
  type        = string
  default     = "ACCEPT"
  validation {
    condition     = contains(["ACCEPT", "DROP"], var.proxmox_host_input_policy)
    error_message = "proxmox_host_input_policy must be ACCEPT or DROP."
  }
}

provider "proxmox" {
  endpoint  = "https://${local.site.lan.proxmox}:8006/api2/json"
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = var.proxmox_insecure

  ssh {
    # provider imports new vm disks over ssh, with the deploy key sync.sh loads into the agent: a password would be
    # a second copy of root's, which sync.sh rotates (proxmox-root-pass)
    agent    = true
    username = var.proxmox_ssh_user
    node {
      name    = local.site.node
      address = local.site.lan.proxmox
      port    = var.proxmox_ssh_port
    }
  }
}
