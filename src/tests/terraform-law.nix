# lab-wide: terraform's declared state (terraform/main.tf, lib.tf's firewall)
# both files parsed by hcl2json and held to the law below: tls to the api verified (no `insecure`), the state's working
# copy outside the flake tree (no backend path), the datacenter firewall on with the host's input policy DROP and
# switched on only after the guests' filters and the host rules, every container unprivileged and destroyed before a vm
# takes its vmid, every guest bound to its address and mac (the router's nics alone exempt) and dropping what it sends
# from any other address, its recovery path (ssh, the node exporter) open to its own sources and dropped from anyone
# else, logged, ssh open to the owner's machines (the rollback path, FEATURES.md "Proxmox host"), the api open to the
# owner's machines and the named guests, then dropped, and no host rule accepting from everyone, from the whole house
# lan beyond ping, or from the router, whose address would stand for every guest it masquerades. Each mutation in
# `controls` must break the law.
{ pkgs, lib, ... }:
let
  sshPort = "22";
  sshSources = "\${join(\",\", concat(local.operator_sources, local.host_client_ips.ssh))}";
  apiPort = "\${tostring(local.proxmox_api_port)}";
  lanSubnet = "\${local.site.lan.subnet}";
  apiSources = "\${join(\",\", concat(local.operator_sources, local.host_client_ips.api))}";
  router = "local.site.lan.router";
  firewalled = "\${local.firewalled}";
  # one entry per cidr in sort order, the guest's own nomatch where it sorts: any other order is a perpetual diff
  spoofedCidrs = [
    {
      for_each = "\${local.spoofed_cidrs[each.key]}";
      content = [
        {
          name = "\${cidr.value}";
          nomatch = "\${cidr.value == each.value.ip ? true : null}";
        }
      ];
    }
  ];
  spoofedOrder = "\${{ for id, v in local.firewalled : id => sort(concat(local.spoofed_halves, [v.ip])) }}";
  spoofedRule = {
    type = "out";
    action = "DROP";
    source = "+guest/spoofed";
  };
  recoveryRules = [
    {
      action = "ACCEPT";
      source = "\${join(\",\", rule.value.sources)}";
      log = null;
    }
    {
      action = "DROP";
      source = null;
      log = "info";
    }
  ];
  operators = [
    "\${local.site.lan.workstation}"
    "\${local.site.lan.notebook}"
  ];
  datacenterAfter = [
    "\${proxmox_virtual_environment_firewall_options.guest}"
    "\${proxmox_virtual_environment_firewall_rules.guest}"
    "\${proxmox_virtual_environment_firewall_rules.host}"
    "\${proxmox_virtual_environment_firewall_ipset.management}"
  ];

  law = pkgs.writeText "terraform-law.jq" ''
    .resource as $r
    | ($r.proxmox_virtual_environment_cluster_firewall.datacenter[0]) as $dc
    | ($r.proxmox_virtual_environment_firewall_options.guest[0]) as $guest
    | ($r.proxmox_virtual_environment_firewall_ipset.spoofed[0]) as $spoofed
    | ($r.proxmox_virtual_environment_firewall_rules.guest[0]) as $guestRules
    | ($r.proxmox_virtual_environment_firewall_rules.host[0].rule) as $rules
    | ([.locals[] | select(has("operators")) | .operators][0]) as $operators
    | ([$r.proxmox_virtual_environment_firewall_ipset.management[0].cidr[]? | select(.nomatch == true) | .name]) as $unmanaged
    | [
        (if .provider.proxmox[0] | has("insecure") then "the provider skips tls verification of the api" else empty end),
        (if .terraform[0].backend.local[0] != {} then "the backend names a path: the state belongs outside the flake tree" else empty end),
        (if $dc.enabled != true then "the datacenter firewall is off: no guest's ip and mac filter applies" else empty end),
        (if $dc.input_policy != "DROP" then "the host's input policy is \($dc.input_policy), not DROP" else empty end),
        (if $dc.ebtables != true then "ebtables is off: no arp or mac filtering" else empty end),
        (if ($dc.depends_on | sort) != (${builtins.toJSON datacenterAfter} | sort)
          then "the datacenter switch does not wait for the guests' filters and the host rules" else empty end),
        (if [$guest.enabled, $guest.ipfilter, $guest.macfilter] != [true, true, true]
          then "the guests' firewall options do not bind each to its address and mac" else empty end),
        (if $r.proxmox_virtual_environment_container.ct[0].unprivileged != true
          then "a container may be privileged: its root is root on the host" else empty end),
        (if $r.proxmox_virtual_environment_container.ct[0].network_interface[0].firewall != true
          then "a container's nic bypasses the firewall" else empty end),
        (if ($r.proxmox_virtual_environment_vm.vm[0].depends_on | index("''${proxmox_virtual_environment_container.ct}")) == null
          then "a vm may be created before the container of its vmid is destroyed" else empty end),
        (if $r.proxmox_virtual_environment_vm.vm[0].network_device[0].firewall != "''${each.value.type != \"router\"}"
          then "a vm's nic other than the router's bypasses the firewall" else empty end),
        (if [$spoofed.for_each, $guestRules.for_each] != ["${firewalled}", "${firewalled}"]
          then "a firewalled guest has no spoofed set or rule" else empty end),
        (if [$spoofed.cidr, $spoofed.dynamic.cidr] != [null, ${builtins.toJSON spoofedCidrs}]
          then "the spoofed set does not leave out the guest's own address alone" else empty end),
        (if [.locals[] | select(has("spoofed_cidrs")) | .spoofed_cidrs] != [${builtins.toJSON spoofedOrder}]
          then "the spoofed set is not declared in the sorted order proxmox reads it back in" else empty end),
        (if ($guestRules.rule // [] | map({type, action, source})) != [${builtins.toJSON spoofedRule}]
          then "a guest's other source addresses are not dropped on the way out" else empty end),
        (if ($guestRules.dynamic.rule // [] | map(select(.for_each == "''${each.value.recovery}") | .content[0] | {action, source, log}))
            != ${builtins.toJSON recoveryRules}
          then "a guest's recovery path is not open to its own sources alone, then dropped and logged" else empty end),
        (if [$rules[] | select(.dport == "${sshPort}" and .action == "ACCEPT" and .source == ${builtins.toJSON sshSources})] == []
          then "ssh is not open to the operators: a firewall that locks out the api has no way back" else empty end),
        (if $operators != ${builtins.toJSON operators} then "the operators are not the workstation and the notebook" else empty end),
        (if ($rules | map(select(.dport == "${apiPort}")) | map({action, source}))
            != [{action: "ACCEPT", source: ${builtins.toJSON apiSources}}, {action: "DROP", source: null}]
          then "the api is not open to the operators and the named guests alone, then dropped" else empty end),
        (if $unmanaged != ["${lanSubnet}"]
          then "proxmox's implicit management set still admits ssh and the api from the whole lan" else empty end),
        ($rules[] | select(.action == "ACCEPT" and .source == null) | "a host rule accepts \(.proto) \(.dport) from everyone"),
        ($rules[] | select(.action == "ACCEPT" and .proto != "icmp" and (.source // "" | contains("${lanSubnet}")))
          | "a host rule accepts \(.proto) \(.dport) from the whole house lan"),
        ($rules[] | select(.source // "" | contains("${router}"))
          | "a host rule names the router, which stands for every guest it masquerades")
      ]
  '';

  controls = [
    ".provider.proxmox[0].insecure = true"
    ''.terraform[0].backend.local[0].path = "../generated/terraform/terraform.tfstate"''
    ".resource.proxmox_virtual_environment_cluster_firewall.datacenter[0].enabled = false"
    ''.resource.proxmox_virtual_environment_cluster_firewall.datacenter[0].input_policy = "ACCEPT"''
    ".resource.proxmox_virtual_environment_cluster_firewall.datacenter[0].depends_on = []"
    "del(.resource.proxmox_virtual_environment_firewall_ipset.management)"
    ".resource.proxmox_virtual_environment_firewall_options.guest[0].ipfilter = false"
    "del(.resource.proxmox_virtual_environment_firewall_rules.guest)"
    ".resource.proxmox_virtual_environment_firewall_ipset.spoofed[0].dynamic.cidr[0].content[0].nomatch = true"
    ''(.locals[] | select(has("spoofed_cidrs")) | .spoofed_cidrs) |= sub("sort\\((?<x>.*)\\) }"; "\(.x) }")''
    ''.resource.proxmox_virtual_environment_firewall_rules.guest[0].rule[0].action = "ACCEPT"''
    ".resource.proxmox_virtual_environment_firewall_rules.guest[0].dynamic.rule |= .[:1]"
    ''.resource.proxmox_virtual_environment_firewall_rules.guest[0].dynamic.rule[0].content[0].source = "${lanSubnet}"''
    ".resource.proxmox_virtual_environment_container.ct[0].unprivileged = false"
    ".resource.proxmox_virtual_environment_container.ct[0].network_interface[0].firewall = false"
    ".resource.proxmox_virtual_environment_vm.vm[0].network_device[0].firewall = true"
    ".resource.proxmox_virtual_environment_vm.vm[0].depends_on |= map(select(contains(\"container\") | not))"
    ''.resource.proxmox_virtual_environment_firewall_rules.host[0].rule |= map(select(.dport != "${sshPort}"))''
    ''(.locals[] | select(has("operators")) | .operators) = ["''${local.site.lan.notebook}"]''
    ''(.resource.proxmox_virtual_environment_firewall_rules.host[0].rule[] | select(.dport == "${apiPort}" and .action == "ACCEPT") | .source) = "${lanSubnet}"''
    ''(.resource.proxmox_virtual_environment_firewall_rules.host[0].rule[] | select(.dport == "9100") | .source) = "''${local.site.lan.router}"''
    ''(.resource.proxmox_virtual_environment_firewall_rules.host[0].rule[] | select(.dport == "9100") | .source) = "${lanSubnet}"''
    ''.resource.proxmox_virtual_environment_firewall_rules.host[0].rule |= map(select(.action != "DROP"))''
    "del(.resource.proxmox_virtual_environment_firewall_rules.host[0].rule[0].source)"
  ];
in
pkgs.runCommand "terraform-law"
  {
    nativeBuildInputs = [
      pkgs.hcl2json
      pkgs.jq
    ];
  }
  ''
    hcl2json ${../terraform/main.tf} > main.json
    hcl2json ${../terraform/lib.tf} > lib.json
    jq -s '(.[0].locals + .[1].locals) as $locals | .[0] * .[1] | .locals = $locals' main.json lib.json > terraform.json
    violations=$(jq -c -f ${law} terraform.json)
    [ "$violations" = "[]" ] || { echo "terraform breaks the law:"; jq -r '.[]' <<<"$violations"; exit 1; }
    ${lib.concatImapStrings (i: mutation: ''
      [[ "$(jq '${mutation}' terraform.json | jq -c -f ${law})" == '["'* ]] || { echo "control ${toString i} passed the law"; exit 1; }
    '') controls}
    touch $out
  ''
