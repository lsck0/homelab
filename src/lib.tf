# VM plumbing: turns each entry of local.instances (instances.tf) into a
# Proxmox VM. Nothing here is per-service; edit instances.tf instead.
#
# Instance fields:
#   enabled  = true | "onDemand" | false
#              true      always running
#              onDemand  booted by the Traefik socket proxy on first request,
#                        shut down after `cooldown` without connections
#              false     VM exists but is stopped and not deployed
#   cooldown = idle time before an onDemand VM is shut down (systemd time, "30m")
#   name     = "<id>-<type>-<service>", must match src/instances/<name>.nix
#   type     = "internal" (10.100.0.0/24) | "external" (10.200.0.0/24 DMZ) | "router"
#   memory   = MiB ceiling (default 768). With ballooning on this is a cap, not
#              a reservation, so it only has to cover the service's peak.
#   balloon  = MiB floor the host may squeeze to (default: half of memory)
#   cores    = vCPUs (default 2)
#   disk     = GiB for the root disk on the NVMe pool (default 8)
#   extra_disks = [{ size, datastore }] extra blank disks, scsi1 onward.
#              Used for bulk storage on the spinning disk, which is a separate
#              datastore and deliberately not part of the `pve` group.
#   machine  = "q35" for PCIe passthrough (default bpg/i440fx)
#   hostpci  = Proxmox hardware-mapping names to pass through, e.g. ["gpu"]
#   boot_order = start order when the Proxmox host boots (default 3). Every VM
#                needs the router and most mount the NAS, so those two go first.

locals {
  defaults = {
    enabled  = true
    cooldown = "30m"
    # measured working set of a plain VM: 445-600 MiB
    memory = 768
    # Balloon floor as a fraction of memory. Without it the provider sets
    # balloon: 0 and a VM never gives memory back; the lab is overcommitted.
    balloon_ratio = 0.5
    cores         = 2
    disk          = 8
    machine       = null
    hostpci       = []
    # [{ size, datastore }]. Bulk media lives on the spinning disk, which is
    # a separate datastore from the NVMe pool.
    extra_disks = []
    boot_order  = 3
  }

  # pause after each VM that boots before the default group, so the router and
  # the NAS are serving before their clients start.
  boot_wait_seconds = 30

  vms = {
    for id, i in local.instances : id => {
      name = i.name
      type = i.type
      # as a string, the for-expression would unify bool and string anyway
      enabled  = tostring(try(i.enabled, local.defaults.enabled))
      cooldown = try(i.cooldown, local.defaults.cooldown)
      memory   = try(i.memory, local.defaults.memory)
      # never below 512: squeezed to 384 a VM stops answering ssh
      balloon     = try(i.balloon, max(512, floor(try(i.memory, local.defaults.memory) * try(i.balloon_ratio, local.defaults.balloon_ratio))))
      cores       = try(i.cores, local.defaults.cores)
      disk        = try(i.disk, local.defaults.disk)
      machine     = try(i.machine, local.defaults.machine)
      hostpci     = try(i.hostpci, local.defaults.hostpci)
      extra_disks = try(i.extra_disks, local.defaults.extra_disks)
      boot_order  = try(i.boot_order, local.defaults.boot_order)

      bridge        = i.type == "router" ? var.wan_bridge : i.type == "external" ? var.external_bridge : var.internal_bridge
      extra_bridges = i.type == "router" ? [var.internal_bridge, var.external_bridge] : []

      ip = (
        i.type == "router" ? "192.168.178.29" :
        i.type == "external" ? cidrhost(var.external_subnet, tonumber(id)) :
        cidrhost(var.internal_subnet, tonumber(id))
      )
      prefix = (
        i.type == "router" ? "24" :
        i.type == "external" ? split("/", var.external_subnet)[1] :
        split("/", var.internal_subnet)[1]
      )
      gateway = (
        i.type == "router" ? "192.168.178.1" :
        i.type == "external" ? var.router_external_ip :
        var.router_internal_ip
      )
    }
  }
}

check "instance_fields" {
  assert {
    condition     = alltrue([for id, v in local.vms : contains(["true", "false", "onDemand"], v.enabled)])
    error_message = "enabled must be true, false or \"onDemand\"."
  }
  assert {
    condition     = alltrue([for id, v in local.vms : startswith(v.name, "${id}-") || v.type == "router"])
    error_message = "Instance name must start with its id (\"<id>-<type>-<service>\")."
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

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = local.vms

  # the GPU mapping must exist before a VM can reference it by name.
  depends_on = [proxmox_virtual_environment_hardware_mapping_pci.gpu]

  name      = each.value.name
  node_name = var.target_node
  vm_id     = tonumber(each.key)
  # onDemand VMs start once so the first deploy reaches them; the on-demand
  # proxy powers them off after the cooldown.
  started = each.value.enabled != "false"
  # onDemand VMs stay off at host boot until a request wakes them.
  on_boot = each.value.enabled == "true"
  machine = each.value.machine

  startup {
    order    = each.value.boot_order
    up_delay = each.value.boot_order < local.defaults.boot_order ? local.boot_wait_seconds : 0
  }

  # one hostpciN entry per passed-through mapping. Requires machine = "q35"
  # and the host bound to vfio-pci for the mapped devices.
  dynamic "hostpci" {
    for_each = each.value.hostpci
    content {
      device  = "hostpci${hostpci.key}"
      mapping = hostpci.value
      pcie    = true
    }
  }

  lifecycle {
    # file_id is only the image a disk was created from; imported VMs (see
    # src/scripts/renumber.sh) have none, and a diff there must never replace a VM.
    #
    # user_account only, not all of initialization: ignoring the whole block
    # also ignored ip_config, and 44 of 45 VMs silently kept another VM's
    # address. user_account must stay ignored - the provider cannot read back
    # a password, so it diffs every plan.
    ignore_changes = [
      initialization[0].user_account,
      mac_addresses,
      disk[0].file_id,
    ]
  }

  agent {
    enabled = true
  }
  cpu {
    cores = each.value.cores
    type  = "host"
  }
  memory {
    dedicated = each.value.memory
    # floating turns the balloon device on. dedicated stays the ceiling; the
    # host may reclaim down to this when it runs short. Proxmox only squeezes
    # under real pressure, so a VM that needs its full size keeps it.
    floating = each.value.balloon
  }

  disk {
    datastore_id = var.proxmox_datastore
    file_id      = var.nixos_image_id
    file_format  = "raw"
    interface    = "scsi0"
    size         = each.value.disk
    ssd          = true
    discard      = "on"
  }

  # scsi1 onward. No file_id: these are blank disks, not clones of the NixOS
  # image, and the VM formats them itself on first boot.
  dynamic "disk" {
    for_each = each.value.extra_disks
    content {
      datastore_id = disk.value.datastore
      file_format  = "raw"
      interface    = "scsi${disk.key + 1}"
      size         = disk.value.size
      # a 5400 rpm disk: ssd = false so the guest schedules for a rotating
      # device, discard = on so deleting a file still returns the blocks.
      ssd     = false
      discard = "on"
    }
  }

  network_device {
    bridge = each.value.bridge
  }
  dynamic "network_device" {
    for_each = each.value.extra_bridges
    content {
      bridge = network_device.value
    }
  }

  initialization {
    datastore_id = var.proxmox_datastore
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${each.value.prefix}"
        gateway = each.value.gateway
      }
    }
    user_account {
      keys     = [var.ssh_public_key]
      username = "root"
    }
  }
}

# sync.sh writes local.inventory to src/inventory.json; the Nix configs read it
# as the `inventory` module argument.

locals {
  inventory = {
    for id, v in local.vms : id => {
      name     = v.name
      type     = v.type
      ip       = v.ip
      prefix   = tonumber(v.prefix)
      gateway  = v.gateway
      enabled  = v.enabled
      cooldown = v.cooldown
    }
  }
}

output "inventory" {
  value = local.inventory
}
