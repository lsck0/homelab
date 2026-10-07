# vm plumbing: the lab's guests (nix, modules/lab) -> proxmox vms and containers

# -----------------------------------------------------------------------------
# GUESTS: src/instances/*/instance.nix and the swarm nodes of src/apps/swarm.nix, collected and checked by nix
#
# One direction, no generated file: nix computes every guest's shape, defaults and address (modules/lab, typed by
# modules/instance-schema.nix) and fails on any broken invariant (zones, privileges, dhcp pools), so a plan never
# starts past one; terraform turns the result into proxmox resources. The external program's protocol allows string
# values only, hence the one json string.
data "external" "lab" {
  program     = ["nix", "eval", "--json", "--no-warn-dirty", ".#lab.terraform"]
  working_dir = local.src
}

locals {
  instances = jsondecode(data.external.lab.result.json)

  # scripts/pve-install.sh names the lvm-thin storage on the bulk disk
  bulk_datastore = "bulk"
  # an instance's extra disk names its store, terraform knows where each one lives
  datastores = { guest = var.proxmox_datastore, bulk = local.bulk_datastore }

  # first-boot root keys; nixos (modules/base) reads the same files from then on
  authorized_keys = [for f in sort(fileset("${local.src}/lab/keys", "*.pub")) : trimspace(file("${local.src}/lab/keys/${f}"))]

  # the router's legs after the wan, in proxmox nic order: net1 is the zone with router_nic 1, and so on
  router_zones = [for nic in range(1, length(local.zones) + 1) : one([for name, z in local.zones : name if z.router_nic == nic])]

  vms = {
    for id, i in local.instances : id => {
      name        = i.name
      type        = i.type
      enabled     = i.enabled
      kind        = i.kind
      privileged  = i.privileged
      features    = i.features
      memory      = i.memory
      balloon     = i.balloon
      cores       = i.cores
      cpu_units   = i.cpu_units
      cpu_limit   = i.cpu_limit
      disk_limits = i.disk_limits
      nic_rate    = i.nic_rate
      disk        = i.disk
      machine     = i.machine
      hostpci     = i.hostpci
      extra_disks = [for d in i.extra_disks : { size = d.size, datastore = local.datastores[d.store] }]
      boot_order  = i.boot_order
      boot_wait   = i.boot_wait

      bridge        = i.type == "router" ? var.wan_bridge : local.zones[i.type].bridge
      extra_bridges = i.type == "router" ? [for z in local.router_zones : local.zones[z].bridge] : []

      ip      = i.ip
      prefix  = tostring(i.prefix)
      gateway = i.gateway

      # the zone's ingress wakes its onDemand guests as this proxmox user (scripts/pve-install.sh creates it)
      wake_user = i.enabled == "onDemand" ? "wake-${i.type}@pve" : null
    }
  }
}

# a wake user and its privsep token may power exactly their zone's onDemand guests: one acl per guest, not a pool,
# since the provider recreates a container whose pool changes
locals {
  wake_acls = merge([for id, v in local.vms : v.wake_user == null ? {} : {
    "${id}-user"  = { path = "/vms/${id}", user_id = v.wake_user, token_id = null }
    "${id}-token" = { path = "/vms/${id}", user_id = null, token_id = "${v.wake_user}!ondemand" }
  }]...)
}

resource "proxmox_virtual_environment_acl" "wake" {
  for_each  = local.wake_acls
  path      = each.value.path
  role_id   = "HomelabWake"
  user_id   = each.value.user_id
  token_id  = each.value.token_id
  propagate = false
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

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = { for id, v in local.vms : id => v if v.kind == "vm" }

  # the gpu mapping must exist before a vm references it
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
      # scripts/pve-install.sh sets it as root (the nas's bulk storage); the api token may not
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
    limit = each.value.cpu_limit
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
    dynamic "speed" {
      for_each = each.value.disk_limits == null ? [] : [each.value.disk_limits]
      content {
        read       = speed.value.readMBps
        write      = speed.value.writeMBps
        iops_read  = speed.value.readIops
        iops_write = speed.value.writeIops
      }
    }
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

  # a guest's nic carries the proxmox firewall's ip and mac filter (FIREWALL below); the router forwards every
  # source it routes, so no address filter can describe its nics
  network_device {
    bridge     = each.value.bridge
    firewall   = each.value.type != "router"
    rate_limit = each.value.nic_rate
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
    name     = "eth0"
    bridge   = each.value.bridge
    firewall = true
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

# -----------------------------------------------------------------------------
# FIREWALL: proxmox binds every guest to its own address and mac, and the host takes only its own traffic
#
# Zones are shared bridges, and the router, the nas exports and every ingress guard authorize by source address. A
# root guest could take any address of its subnet (a static change, a gratuitous arp) and inherit that host's
# rights: the edge's api access, a nas client's export. ipfilter drops every packet and arp reply a guest's nic sends
# from another address, macfilter every frame from another mac. Filtering itself stays with the router and the guests:
# both guest policies are ACCEPT, proxmox only checks who is speaking.
#
# The host drops what its rules do not name. Lab traffic reaches it masqueraded as the router's lan address
# (instances/300-router), so the router stands for the ingresses' wake and proxmox route, the homepage and grafana.
# The datacenter switch comes last: no guest is filtered before its ipset exists, and the host rules exist before
# the DROP policy does. sync.sh fails while the firewall is not running (README, "Proxmox firewall").
locals {
  # the router forwards every source it routes, no address filter fits it (its nics carry firewall = false)
  firewalled = { for id, v in local.vms : id => v if v.type != "router" }
  # the owner's machines, dhcp-reserved in the fritzbox; sync.sh refuses to run from any other address
  operators = [local.site.lan.workstation, local.site.lan.notebook]
}

resource "proxmox_virtual_environment_firewall_ipset" "ipfilter" {
  for_each   = local.firewalled
  depends_on = [proxmox_virtual_environment_vm.vm, proxmox_virtual_environment_container.ct]

  node_name    = local.site.node
  vm_id        = each.value.kind == "vm" ? tonumber(each.key) : null
  container_id = each.value.kind == "lxc" ? tonumber(each.key) : null
  # the name proxmox reads as the allowed sources of nic net0
  name    = "ipfilter-net0"
  comment = "the only source address ${each.value.name} may send from"
  cidr {
    name = each.value.ip
  }
}

resource "proxmox_virtual_environment_firewall_options" "guest" {
  for_each   = local.firewalled
  depends_on = [proxmox_virtual_environment_firewall_ipset.ipfilter]

  node_name     = local.site.node
  vm_id         = each.value.kind == "vm" ? tonumber(each.key) : null
  container_id  = each.value.kind == "lxc" ? tonumber(each.key) : null
  enabled       = true
  ipfilter      = true
  macfilter     = true
  input_policy  = "ACCEPT"
  output_policy = "ACCEPT"
  # static addresses and ipv4 only: no dhcp, neighbour discovery or router advertisements to allow
  dhcp = false
  ndp  = false
  radv = false
}

resource "proxmox_virtual_environment_cluster_firewall" "datacenter" {
  depends_on = [proxmox_virtual_environment_firewall_options.guest, proxmox_virtual_environment_firewall_rules.host]

  enabled = true
  # arp and mac filtering run in ebtables
  ebtables      = true
  input_policy  = "DROP"
  output_policy = "ACCEPT"
}

# in order: proxmox's own management rules, which follow these, would admit the api from the whole lan
resource "proxmox_virtual_environment_firewall_rules" "host" {
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "22"
    source  = local.site.lan.subnet
    comment = "ssh from the house lan: sync.sh, init.sh, hermes through the router; keys only"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = tostring(local.proxmox_api_port)
    source  = join(",", concat(local.operators, [local.site.lan.router]))
    comment = "api and web ui: the owner's machines (terraform, sync.sh) and the router (the ingresses, homepage)"
  }
  rule {
    type    = "in"
    action  = "DROP"
    proto   = "tcp"
    dport   = tostring(local.proxmox_api_port)
    comment = "the api from anywhere else"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "9100"
    source  = local.site.lan.router
    comment = "node exporter, scraped by vm-105 through the router"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "icmp"
    source  = local.site.lan.subnet
    comment = "ping: the homepage's and the prober's reachability checks"
  }
}
