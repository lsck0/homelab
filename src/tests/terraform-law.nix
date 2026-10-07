# lab-wide: the proxmox firewall as terraform declares it (terraform/lib.tf FIREWALL)
# lib.tf parsed by hcl2json, held to the law below: the datacenter firewall on with the host's input policy DROP,
# every guest bound to its address and mac (the router's nics alone exempt), the api open to the workstation and the
# router only, and no host rule accepting from everyone. Each mutation in `controls` must break the law.
{ pkgs, ... }:
let
  apiPort = "\${tostring(local.proxmox_api_port)}";
  apiSources = "\${local.site.lan.workstation},\${local.site.lan.router}";

  law = pkgs.writeText "proxmox-firewall-law.jq" ''
    .resource as $r
    | ($r.proxmox_virtual_environment_cluster_firewall.datacenter[0]) as $dc
    | ($r.proxmox_virtual_environment_firewall_options.guest[0]) as $guest
    | ($r.proxmox_virtual_environment_firewall_rules.host[0].rule) as $rules
    | [
        (if $dc.enabled != true then "the datacenter firewall is off: no guest's ip and mac filter applies" else empty end),
        (if $dc.input_policy != "DROP" then "the host's input policy is \($dc.input_policy), not DROP" else empty end),
        (if $dc.ebtables != true then "ebtables is off: no arp or mac filtering" else empty end),
        (if [$guest.enabled, $guest.ipfilter, $guest.macfilter] != [true, true, true]
          then "the guests' firewall options do not bind each to its address and mac" else empty end),
        (if $r.proxmox_virtual_environment_container.ct[0].network_interface[0].firewall != true
          then "a container's nic bypasses the firewall" else empty end),
        (if $r.proxmox_virtual_environment_vm.vm[0].network_device[0].firewall != "''${each.value.type != \"router\"}"
          then "a vm's nic other than the router's bypasses the firewall" else empty end),
        (if ($rules | map(select(.dport == "${apiPort}")) | map({action, source}))
            != [{action: "ACCEPT", source: "${apiSources}"}, {action: "DROP", source: null}]
          then "the api is not open to the workstation and the router alone, then dropped" else empty end),
        ($rules[] | select(.action == "ACCEPT" and .source == null) | "a host rule accepts \(.proto) \(.dport) from everyone")
      ]
  '';

  controls = [
    ''.resource.proxmox_virtual_environment_cluster_firewall.datacenter[0].enabled = false''
    ''.resource.proxmox_virtual_environment_cluster_firewall.datacenter[0].input_policy = "ACCEPT"''
    ''.resource.proxmox_virtual_environment_firewall_options.guest[0].ipfilter = false''
    ''.resource.proxmox_virtual_environment_container.ct[0].network_interface[0].firewall = false''
    ''.resource.proxmox_virtual_environment_vm.vm[0].network_device[0].firewall = true''
    ''(.resource.proxmox_virtual_environment_firewall_rules.host[0].rule[] | select(.dport == "${apiPort}" and .action == "ACCEPT") | .source) = "''${local.site.lan.subnet}"''
    ''.resource.proxmox_virtual_environment_firewall_rules.host[0].rule |= map(select(.action != "DROP"))''
    ''del(.resource.proxmox_virtual_environment_firewall_rules.host[0].rule[0].source)''
  ];
in
pkgs.runCommand "proxmox-firewall" { nativeBuildInputs = [ pkgs.hcl2json pkgs.jq ]; } ''
  hcl2json ${../terraform/lib.tf} > lib.json
  violations=$(jq -c -f ${law} lib.json)
  [ "$violations" = "[]" ] || { echo "terraform/lib.tf breaks the firewall law:"; jq -r '.[]' <<<"$violations"; exit 1; }
  ${pkgs.lib.concatImapStrings (i: mutation: ''
    [[ "$(jq '${mutation}' lib.json | jq -c -f ${law})" == '["'* ]] || { echo "control ${toString i} passed the law"; exit 1; }
  '') controls}
  touch $out
''
