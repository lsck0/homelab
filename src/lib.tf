# vm plumbing: local.instances -> proxmox vms

locals {
  # scripts/pve-install.sh names the lvm-thin storage on the bulk disk
  bulk_datastore = "bulk"

  # first-boot root keys; nixos (modules/base.nix) reads the same files from then on
  authorized_keys = [for f in sort(fileset("${path.module}/keys", "*.pub")) : trimspace(file("${path.module}/keys/${f}"))]

  defaults = {
    enabled = true
    # "vm" or "lxc"; lxc has no balloon, gpu or extra disks
    kind = "vm"
    # lxc only: root in a privileged container is root on the host, use it only for nfs mounts
    privileged = false
    # lxc only, proxmox feature string; sync.sh sets it as root, the api token may not
    features = "nesting=1"
    cooldown = "30m"
    # plain vm working set measured 445-600 MiB
    memory = 768
    # balloon floor as a fraction of memory
    balloon_ratio = 0.5
    cores         = 2
    # proxmox cpu weight, 100 is its default
    cpu_units = 100
    disk      = 8
    machine   = null
    hostpci   = []
    # [{ size, datastore }]
    extra_disks = []
  }

  # host boot starts the lab phase by phase: storage first, the public side last
  boot_phases = ["nas", "network", "dev", "apps", "media", "public"]
  # a phase starts all its guests at once; the next one waits so their boots do not stack up in ram
  boot_phase_wait = 60
  # proxmox starts guests by order, then id, waiting up_delay after each: only a phase's last autostarted guest waits
  boot_phase_last = {
    for phase in local.boot_phases : phase => max(concat([0], [
      for id, i in local.instances : tonumber(id) if i.boot_phase == phase && tostring(try(i.enabled, true)) == "true"
    ])...)
  }

  vms = {
    for id, i in local.instances : id => {
      name = i.name
      type = i.type
      # string, the for-expression unifies bool and string anyway
      enabled    = tostring(try(i.enabled, local.defaults.enabled))
      kind       = try(i.kind, local.defaults.kind)
      privileged = try(i.privileged, local.defaults.privileged)
      features   = try(i.features, local.defaults.features)
      cooldown   = try(i.cooldown, local.defaults.cooldown)
      memory     = try(i.memory, local.defaults.memory)
      # floor 512: at 384 a vm drops ssh
      balloon     = try(i.balloon, max(512, floor(try(i.memory, local.defaults.memory) * try(i.balloon_ratio, local.defaults.balloon_ratio))))
      cores       = try(i.cores, local.defaults.cores)
      cpu_units   = try(i.cpu_units, local.defaults.cpu_units)
      disk        = try(i.disk, local.defaults.disk)
      machine     = try(i.machine, local.defaults.machine)
      hostpci     = try(i.hostpci, local.defaults.hostpci)
      extra_disks = try(i.extra_disks, local.defaults.extra_disks)
      boot_order  = index(local.boot_phases, i.boot_phase) + 1
      boot_wait   = local.boot_phase_last[i.boot_phase] == tonumber(id) ? local.boot_phase_wait : 0

      bridge        = i.type == "router" ? var.wan_bridge : var.zones[i.type].bridge
      extra_bridges = i.type == "router" ? [for z in var.router_zones : var.zones[z].bridge] : []

      ip      = i.type == "router" ? local.site.lan.router : cidrhost(var.zones[i.type].subnet, tonumber(id))
      prefix  = i.type == "router" ? split("/", local.site.lan.subnet)[1] : split("/", var.zones[i.type].subnet)[1]
      gateway = i.type == "router" ? local.site.lan.gateway : var.zones[i.type].router_ip
    }
  }
}

check "instance_fields" {
  assert {
    condition     = alltrue([for id, i in local.instances : i.type == "router" || contains(keys(var.zones), i.type)])
    error_message = "type must be \"router\" or a zone: ${join(", ", keys(var.zones))}."
  }
  assert {
    condition     = alltrue([for id, v in local.vms : contains(["true", "false", "onDemand"], v.enabled)])
    error_message = "enabled must be true, false or \"onDemand\"."
  }
  assert {
    condition     = alltrue([for id, v in local.vms : contains(["vm", "lxc"], v.kind)])
    error_message = "kind must be \"vm\" or \"lxc\"."
  }
  assert {
    condition     = alltrue([for id, v in local.vms : v.kind == "vm" || (length(v.hostpci) == 0 && length(v.extra_disks) == 0 && v.type != "router")])
    error_message = "lxc instances take no gpu, extra disks or router role."
  }
  assert {
    condition     = alltrue([for id, v in local.vms : !v.privileged || (v.kind == "lxc" && v.type == "internal")])
    error_message = "privileged is lxc only, and never in the dmz."
  }
  assert {
    condition     = alltrue([for id, v in local.vms : startswith(v.name, "${id}-") || v.type == "router"])
    error_message = "Instance name must start with its id (\"<id>-<type>-<service>\")."
  }
}

# the passthrough gpu from site.json, if the machine has one
resource "proxmox_virtual_environment_hardware_mapping_pci" "gpu" {
  count = local.site.gpu == null ? 0 : 1
  name  = "gpu"
  map = [{
    node = local.site.node
    id   = local.site.gpu.id
    path = local.site.gpu.path
    # vm start fails without these two
    iommu_group  = local.site.gpu.iommuGroup
    subsystem_id = local.site.gpu.subsystemId
  }]
}

# the mapping became optional; keeps the existing one instead of recreating it under vm-134
moved {
  from = proxmox_virtual_environment_hardware_mapping_pci.gpu
  to   = proxmox_virtual_environment_hardware_mapping_pci.gpu[0]
}

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = { for id, v in local.vms : id => v if v.kind == "vm" }

  # mapping must exist before a vm references it
  depends_on = [proxmox_virtual_environment_hardware_mapping_pci.gpu]

  name      = each.value.name
  node_name = local.site.node
  vm_id     = tonumber(each.key)
  # ondemand vms start once so the first deploy reaches them
  started = each.value.enabled != "false"
  # ondemand vms stay off at host boot
  on_boot = each.value.enabled == "true"
  machine = each.value.machine

  startup {
    order    = each.value.boot_order
    up_delay = each.value.boot_wait
  }

  # one hostpciN per mapping
  dynamic "hostpci" {
    for_each = each.value.hostpci
    content {
      device  = "hostpci${hostpci.key}"
      mapping = hostpci.value
      pcie    = true
    }
  }

  lifecycle {
    # file_id only seeds a new disk, never replace
    ignore_changes = [
      initialization[0].user_account,
      mac_addresses,
      disk[0].file_id,
      # sync.sh sets it as root (vm-109 bulk storage); the api token may not
      hook_script_file_id,
    ]
  }

  agent {
    enabled = true
  }
  cpu {
    cores = each.value.cores
    type  = "host"
    units = each.value.cpu_units
  }
  memory {
    dedicated = each.value.memory
    # floating enables ballooning, dedicated stays the ceiling
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

  # scsi1 onward
  dynamic "disk" {
    for_each = each.value.extra_disks
    content {
      datastore_id = disk.value.datastore
      file_format  = "raw"
      interface    = "scsi${disk.key + 1}"
      size         = disk.value.size
      # the bulk pool is a 5400 rpm hdd, the guest schedules for rotation there
      ssd     = disk.value.datastore != local.bulk_datastore
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
      keys     = local.authorized_keys
      username = "root"
    }
  }
}

resource "proxmox_virtual_environment_container" "ct" {
  for_each = { for id, v in local.vms : id => v if v.kind == "lxc" }

  node_name     = local.site.node
  vm_id         = tonumber(each.key)
  unprivileged  = !each.value.privileged
  started       = each.value.enabled != "false"
  start_on_boot = each.value.enabled == "true"

  startup {
    order    = each.value.boot_order
    up_delay = each.value.boot_wait
  }

  operating_system {
    template_file_id = var.nixos_lxc_template
    type             = "nixos"
  }

  lifecycle {
    # the template only seeds a new container, never replace; sync.sh sets features as root
    ignore_changes = [operating_system[0].template_file_id, initialization[0].user_account, features]
  }

  cpu {
    cores = each.value.cores
    units = each.value.cpu_units
  }
  # no balloon in a container: the limit is only a ceiling, unused ram stays with the host
  memory {
    dedicated = each.value.memory
    swap      = 0
  }

  disk {
    datastore_id = var.proxmox_datastore
    size         = each.value.disk
  }

  network_interface {
    name   = "eth0"
    bridge = each.value.bridge
  }

  initialization {
    hostname = each.value.name
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${each.value.prefix}"
        gateway = each.value.gateway
      }
    }
    user_account {
      keys = local.authorized_keys
    }
  }
}

# sync.sh writes this to src/inventory.json for nix

locals {
  inventory = {
    for id, v in local.vms : id => {
      name       = v.name
      type       = v.type
      kind       = v.kind
      privileged = v.privileged
      features   = v.features
      ip         = v.ip
      prefix     = tonumber(v.prefix)
      gateway    = v.gateway
      enabled    = v.enabled
      cooldown   = v.cooldown
    }
  }
}

output "inventory" {
  value = local.inventory
}
