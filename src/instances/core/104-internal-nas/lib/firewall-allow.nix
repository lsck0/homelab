# iptables accepts for ports only the named sources reach (networking.firewall.extraCommands); nixos-fw is flushed
# and rebuilt on every firewall start, so the rules need no teardown
{ lib, net }:
{
  # the owner's machines: the pc and notebook by their fritzbox dhcp reservations, wireguard and tailnet clients
  ownerSources = [
    net.wan.workstation
    net.wan.notebook
    net.wireguard.subnet
    net.tailnet
  ];

  allowFrom =
    {
      sources,
      tcp ? [ ],
      udp ? [ ],
    }:
    let
      rule =
        protocol: ports: source:
        lib.optionalString (ports != [ ]) ''
          iptables -A nixos-fw -s ${source} -p ${protocol} -m multiport --dports ${
            lib.concatMapStringsSep "," toString ports
          } -j nixos-fw-accept
        '';
    in
    lib.concatMapStrings (source: rule "tcp" tcp source + rule "udp" udp source) (lib.unique sources);
}
