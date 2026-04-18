terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

variable "vm_id" { type = number }
variable "name" { type = string }
variable "target_node" { type = string }
variable "datastore_id" { type = string }
variable "cores" {
  type    = number
  default = 2
}
variable "memory" {
  type    = number
  default = 1024
}
variable "disk" {
  type    = number
  default = 8
}
variable "image_id" { type = string }
variable "bridge" { type = string }
variable "extra_bridges" {
  type    = list(string)
  default = []
}
variable "ip_cidr" { type = string }
variable "gw" {
  type    = string
  default = null
}
variable "ssh_key" { type = string }

resource "proxmox_virtual_environment_vm" "this" {
  name      = var.name
  node_name = var.target_node
  vm_id     = var.vm_id

  agent {
    enabled = true
  }
  cpu {
    cores = var.cores
    type  = "host"
  }
  memory {
    dedicated = var.memory
  }

  disk {
    datastore_id = var.datastore_id
    file_id      = var.image_id
    file_format  = "raw"
    interface    = "scsi0"
    size         = var.disk
    ssd          = true
    discard      = "on"
  }

  network_device {
    bridge = var.bridge
  }
  dynamic "network_device" {
    for_each = var.extra_bridges
    content {
      bridge = network_device.value
    }
  }

  initialization {
    datastore_id = var.datastore_id
    ip_config {
      ipv4 {
        address = var.ip_cidr
        gateway = var.gw
      }
    }
    user_account {
      keys     = [var.ssh_key]
      username = "root"
    }
  }
}

output "ipv4_address" {
  value = split("/", var.ip_cidr)[0]
}
