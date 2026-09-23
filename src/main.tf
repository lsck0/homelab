terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.70.0"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# PROXMOX CONNECTION
# ─────────────────────────────────────────────────────────────────────────────
variable "proxmox_api_url" { type = string }
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
variable "target_node" {
  type    = string
  default = "pve"
}
variable "proxmox_ssh_host" { type = string }
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

# ─────────────────────────────────────────────────────────────────────────────
# VM DEFAULTS
# ─────────────────────────────────────────────────────────────────────────────
variable "ssh_public_key" { type = string }
variable "nixos_image_id" {
  type    = string
  default = "local:iso/nixos.img"
}

# ─────────────────────────────────────────────────────────────────────────────
# NETWORK BRIDGES
# ─────────────────────────────────────────────────────────────────────────────
variable "wan_bridge" {
  type    = string
  default = "vmbr0"
}
variable "internal_bridge" {
  type    = string
  default = "vmbr100"
}
variable "external_bridge" {
  type    = string
  default = "vmbr200"
}

# ─────────────────────────────────────────────────────────────────────────────
# SUBNETS
# ─────────────────────────────────────────────────────────────────────────────
variable "internal_subnet" {
  type    = string
  default = "10.100.0.0/24"
}
variable "external_subnet" {
  type    = string
  default = "10.200.0.0/24"
}

# ─────────────────────────────────────────────────────────────────────────────
# ROUTER VM (VM-300)
# ─────────────────────────────────────────────────────────────────────────────
variable "router_internal_ip" {
  type    = string
  default = "10.100.0.1"
}
variable "router_external_ip" {
  type    = string
  default = "10.200.0.1"
}

provider "proxmox" {
  endpoint  = var.proxmox_api_url
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = var.proxmox_insecure

  ssh {
    # The provider imports every new VM's disk over SSH. Password auth is the
    # fallback, not the default: sync.sh rotates the host's root password, so a
    # password in tfvars goes stale on the run that rotates it and disk imports
    # start failing. With no password it uses the ssh-agent, which sync.sh
    # populates with the deploy key.
    #
    # "" has to become null rather than being passed through: the provider
    # validates the field as "not an empty string" and fails to configure at all.
    agent    = var.proxmox_ssh_password == null || var.proxmox_ssh_password == ""
    username = var.proxmox_ssh_user
    password = var.proxmox_ssh_password == "" ? null : var.proxmox_ssh_password
    node {
      name    = var.target_node
      address = var.proxmox_ssh_host
      port    = var.proxmox_ssh_port
    }
  }
}

# Proxmox storage holding bulk media, on the 2 TB spinning disk. Empty means
# the disk has not been handed over yet and vm-109 gets no second disk; set it
# to "bulk" once src/scripts/pve-install.sh has created the volume group.
variable "bulk_datastore" {
  type    = string
  default = ""
}
