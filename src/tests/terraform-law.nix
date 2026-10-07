# lab-wide: terraform's declared state (terraform/main.tf, lib.tf FIREWALL)
# both files parsed by hcl2json and held to the law below: tls to the api verified (no `insecure`), the state's
# working copy outside the flake tree (no backend path), the datacenter firewall on with the host's input policy DROP,
# every guest bound to its address and mac (the router's nics alone exempt), the api open to the workstation and the
# router only, and no host rule accepting from everyone. Each mutation in `controls` must break the law.
{ pkgs, lib, ... }:
let
  apiPort = "\${tostring(local.proxmox_api_port)}";
  apiSources = "\${local.site.lan.workstation},\${local.site.lan.router}";

  law = pkgs.writeText "terraform-law.jq" ''
    .resource as $r
    | ($r.proxmox_virtual_environment_cluster_firewall.datacenter[0]) as $dc
    | ($r.proxmox_virtual_environment_firewall_options.guest[0]) as $guest
    | ($r.proxmox_virtual_environment_firewall_rules.host[0].rule) as $rules
    | [
        (if .provider.proxmox[0] | has("insecure") then "the provider skips tls verification of the api" else empty end),
        (if .terraform[0].backend.local[0] != {} then "the backend names a path: the state belongs outside the flake tree" else empty end),
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
    ''.provider.proxmox[0].insecure = true''
    ''.terraform[0].backend.local[0].path = "../generated/terraform/terraform.tfstate"''
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
pkgs.runCommand "terraform-law" { nativeBuildInputs = [ pkgs.hcl2json pkgs.jq ]; } ''
  hcl2json ${../terraform/main.tf} > main.json
  hcl2json ${../terraform/lib.tf} > lib.json
  jq -s '.[0] * .[1]' main.json lib.json > terraform.json
  violations=$(jq -c -f ${law} terraform.json)
  [ "$violations" = "[]" ] || { echo "terraform breaks the law:"; jq -r '.[]' <<<"$violations"; exit 1; }
  ${lib.concatImapStrings (i: mutation: ''
    [[ "$(jq '${mutation}' terraform.json | jq -c -f ${law})" == '["'* ]] || { echo "control ${toString i} passed the law"; exit 1; }
  '') controls}
  touch $out
''
