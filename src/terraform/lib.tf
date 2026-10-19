# vm plumbing: the lab's guests (nix, modules/lab) -> proxmox vms and containers

# nix computes every guest (modules/lab) and fails on a broken invariant, so a plan never starts past one; the external
# program's protocol allows string values only, hence the one json string
data "external" "lab" {
  program     = ["nix", "eval", "--json", "--no-warn-dirty", ".#lab.terraform"]
  working_dir = local.src
}

locals {
  lab       = jsondecode(data.external.lab.result.json)
  instances = local.lab.guests

  # scripts/pve-install.nu names the lvm-thin storage on the bulk disk
  bulk_datastore = "bulk"
  # an instance's extra disk names its store, terraform knows where each one lives
  datastores = { guest = var.proxmox_datastore, bulk = local.bulk_datastore }

  # first-boot root keys; nixos (modules/base) reads the same files from then on
  authorized_keys = [for f in sort(fileset("${local.src}/secrets/keys", "*.pub")) : trimspace(file("${local.src}/secrets/keys/${f}"))]

  # the router's legs after the wan, in proxmox nic order: net1 is the zone with router_nic 1, and so on
  router_zones = [for nic in range(1, length(local.zones) + 1) : one([for name, z in local.zones : name if z.router_nic == nic])]

  vms = {
    for id, i in local.instances : id => {
      name        = i.name
      type        = i.type
      powered     = i.powered
      idle        = i.idle
      kind        = i.kind
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
      recovery    = i.recovery

      bridge        = i.type == "router" ? var.wan_bridge : local.zones[i.type].bridge
      extra_bridges = i.type == "router" ? [for z in local.router_zones : local.zones[z].bridge] : []

      ip      = i.ip
      prefix  = tostring(i.prefix)
      gateway = i.gateway

      # the zone's ingress wakes its onDemand guests as this proxmox user (scripts/pve-install.nu creates it)
      wake_user = i.powered && i.idle != null ? "wake-${i.type}@pve" : null
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

  # the gpu mapping must exist before a vm references it; a guest turned from lxc into a vm keeps its vmid, so its
  # container must be destroyed before the vm is created ("VM <id> already exists" otherwise)
  depends_on = [proxmox_virtual_environment_hardware_mapping_pci.gpu, proxmox_virtual_environment_container.ct]

  name      = each.value.name
  node_name = local.site.node
  vm_id     = tonumber(each.key)
  # at creation only (ignore_changes below): afterwards sync.nu wakes every powered guest for its deploy and the
  # ingresses' reaper sleeps the idling ones, so terraform starting them each run would only fight the reaper
  started = each.value.powered
  # idling vms stay off at host boot
  on_boot = each.value.powered && each.value.idle == null
  machine = each.value.machine

  startup {
    order    = each.value.boot_order
    up_delay = each.value.boot_wait
  }

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
      started,
      initialization[0].user_account,
      mac_addresses,
      disk[0].file_id,
      # scripts/pve-install.nu sets it as root (the nas's bulk storage); the api token may not
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

  # a guest's nic carries the proxmox firewall's ip and mac filter (`ipfilter` below); the router forwards every
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

  node_name = local.site.node
  vm_id     = tonumber(each.key)
  # root in a container is root on the host otherwise (tests/policy/guests.nix)
  unprivileged  = true
  started       = each.value.powered
  start_on_boot = each.value.powered && each.value.idle == null

  startup {
    order    = each.value.boot_order
    up_delay = each.value.boot_wait
  }

  operating_system {
    template_file_id = var.nixos_lxc_template
    type             = "nixos"
  }

  lifecycle {
    # the template only seeds a new container, never replace; sync.nu sets features as root
    # started as for the vms above
    ignore_changes = [started, operating_system[0].template_file_id, initialization[0].user_account, features]
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

# proxmox binds every guest to its own address and mac, and the host takes only its own traffic. Zones are shared
# bridges, and the router, the nas exports and every ingress guard authorize by source address. A root guest could
# take any address of its subnet (a static change, a gratuitous arp) and inherit that host's rights: the edge's api
# access, a nas client's export. ipfilter drops every arp reply a guest's nic sends for another address, the spoofed
# rule every packet from one, macfilter every frame from another mac. Filtering itself stays with the router and the
# guests: both guest policies are ACCEPT, so a service a guest opens needs no rule here. Its recovery path (ssh, the
# node exporter) proxmox holds to the guest's own sources (modules/flows.nix `recovery`) too, so a guest that drops
# its own firewall still opens it to no neighbour; a refusal logs to the host's firewall log.
#
# The host drops what its rules do not name. The router leaves lab traffic to the host unmasqueraded
# (instances/core/300-router) and the host routes the lab's subnets back through it (scripts/pve-install.nu), so the
# rules name each guest that talks to the host by its own address, never the router's, which would stand for every
# guest. The datacenter switch comes last: no guest is filtered before its ipsets and rules exist, and the host rules
# exist before the DROP policy does. sync.nu fails while the firewall is not running or a guest's spoofed rule is
# not loaded.
locals {
  # the router forwards every source it routes, no address filter fits it (its nics carry firewall = false)
  firewalled = { for id, v in local.vms : id => v if v.type != "router" }
  # the owner's machines, dhcp-reserved in the fritzbox; sync.nu refuses to run from any other address
  operators = [local.site.lan.workstation, local.site.lan.notebook]
  # and the owner's devices over wireguard, which the host routes back through the router too
  operator_sources = concat(local.operators, [local.lab.wireguard])

  dashboard_id = "102"
  collector_id = "103"
  hermes_id    = "113"
  # the guests that talk to the host, by what they reach on it
  host_clients = {
    # the ingresses wake their zones' onDemand guests and serve the web ui, the dashboard reads its widget
    api = concat([for z in local.zones : tostring(z.ingress) if z.ingress != null], [local.dashboard_id])
    # hermes administers the host over ssh (instances/preconfigured/113-internal-hermes)
    ssh     = [local.hermes_id]
    metrics = [local.collector_id]
    ping    = [local.dashboard_id]
  }
  host_client_ips = { for reach, ids in local.host_clients : reach => [for id in ids : local.instances[id].ip] }
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

# ipfilter alone drops no packet from another ipv4 address: proxmox-firewall 1.1.1 ands its drop with the empty
# nomatch set. Every address but the guest's own, in halves (an ipset of the iptables backend takes no /0); a guest
# speaks ipv4 alone, so no ipv6 source is its own. Proxmox reads a set back sorted by its cidr text: declared in any
# other order, every apply deletes and recreates the set, and the guest sends unfiltered meanwhile.
locals {
  spoofed_halves = ["0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"]
  spoofed_cidrs  = { for id, v in local.firewalled : id => sort(concat(local.spoofed_halves, [v.ip])) }
}

resource "proxmox_virtual_environment_firewall_ipset" "spoofed" {
  for_each   = local.firewalled
  depends_on = [proxmox_virtual_environment_vm.vm, proxmox_virtual_environment_container.ct]

  node_name    = local.site.node
  vm_id        = each.value.kind == "vm" ? tonumber(each.key) : null
  container_id = each.value.kind == "lxc" ? tonumber(each.key) : null
  name         = "spoofed"
  comment      = "every source ${each.value.name} may not send from"
  dynamic "cidr" {
    for_each = local.spoofed_cidrs[each.key]
    content {
      name    = cidr.value
      nomatch = cidr.value == each.value.ip ? true : null
    }
  }
}

moved {
  from = proxmox_virtual_environment_firewall_rules.spoofed
  to   = proxmox_virtual_environment_firewall_rules.guest
}

resource "proxmox_virtual_environment_firewall_rules" "guest" {
  for_each   = local.firewalled
  depends_on = [proxmox_virtual_environment_firewall_ipset.spoofed]

  node_name    = local.site.node
  vm_id        = each.value.kind == "vm" ? tonumber(each.key) : null
  container_id = each.value.kind == "lxc" ? tonumber(each.key) : null
  rule {
    type    = "out"
    action  = "DROP"
    source  = "+guest/spoofed"
    comment = "what ${each.value.name} sends from another address"
  }
  dynamic "rule" {
    for_each = each.value.recovery
    content {
      type    = "in"
      action  = "ACCEPT"
      proto   = "tcp"
      dport   = tostring(rule.value.port)
      source  = join(",", rule.value.sources)
      comment = "the recovery path's sources"
    }
  }
  dynamic "rule" {
    for_each = each.value.recovery
    content {
      type    = "in"
      action  = "DROP"
      proto   = "tcp"
      dport   = tostring(rule.value.port)
      log     = "info"
      comment = "the recovery path from anyone else"
    }
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

# proxmox fills its `management` ipset with the host's local network and admits ssh and the api from it ahead of the
# host rules (the nftables backend does so before them); a nomatch of the lan leaves both to the rules below
resource "proxmox_virtual_environment_firewall_ipset" "management" {
  name    = "management"
  comment = "no implicit management sources: ssh and the api follow the host rules"
  cidr {
    name    = local.site.lan.subnet
    nomatch = true
  }
}

resource "proxmox_virtual_environment_cluster_firewall" "datacenter" {
  depends_on = [
    proxmox_virtual_environment_firewall_options.guest,
    proxmox_virtual_environment_firewall_rules.guest,
    proxmox_virtual_environment_firewall_rules.host,
    proxmox_virtual_environment_firewall_ipset.management,
  ]

  enabled = true
  # arp and mac filtering run in ebtables
  ebtables      = true
  input_policy  = "DROP"
  output_policy = "ACCEPT"
}

# in order; proxmox's implicit management sources are emptied above (ipset management)
resource "proxmox_virtual_environment_firewall_rules" "host" {
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "22"
    source  = join(",", concat(local.operator_sources, local.host_client_ips.ssh))
    comment = "ssh from the owner's machines (sync.nu, init.nu), their wireguard and hermes; keys only"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = tostring(local.proxmox_api_port)
    source  = join(",", concat(local.operator_sources, local.host_client_ips.api))
    comment = "api and web ui: the owner's machines and their wireguard, the ingresses and the dashboard"
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
    source  = join(",", local.host_client_ips.metrics)
    comment = "node exporter, scraped by vm-103"
  }
  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "icmp"
    source  = join(",", concat([local.site.lan.subnet], local.host_client_ips.ping))
    comment = "ping: the house, and the dashboard's reachability check"
  }
}
