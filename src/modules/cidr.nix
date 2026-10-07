# ipv4 address arithmetic: pure functions, no lab facts, so the collector (modules/lab) and modules/net.nix share
# one implementation of terraform's cidrhost
#
#   cidr = import ./cidr.nix { inherit lib; };
#   cidr.host "10.100.0.0/24" 134        # "10.100.0.134"
#   cidr.prefix "10.100.0.0/24"          # 24
#   cidr.contains "10.100.0.0/24" "10.100.0.7"
{ lib }:
let
  # -------------------------------------------------------------------------------------------------------------
  # CONSTANTS
  # -------------------------------------------------------------------------------------------------------------

  octetCount = 4;
  octetValues = 256;
  addressBits = 32;

  # -------------------------------------------------------------------------------------------------------------
  # INTERNAL
  # -------------------------------------------------------------------------------------------------------------

  pow = base: exponent: lib.foldl' (acc: _: acc * base) 1 (lib.range 1 exponent);

  ipToInt = ip:
    let octets = map lib.toInt (lib.splitString "." ip); in
    assert lib.assertMsg (lib.length octets == octetCount && lib.all (o: o >= 0 && o < octetValues) octets)
      "cidr.nix: ${ip} is no ipv4 address";
    lib.foldl' (acc: o: acc * octetValues + o) 0 octets;

  intToIp = n: lib.concatMapStringsSep "." (i: toString (lib.mod (n / pow octetValues (octetCount - 1 - i)) octetValues))
    (lib.range 0 (octetCount - 1));

  parse = cidr:
    let parts = lib.splitString "/" cidr; prefix = lib.toInt (lib.last parts); in
    assert lib.assertMsg (lib.length parts == 2 && prefix >= 0 && prefix <= addressBits) "cidr.nix: ${cidr} is no cidr";
    { network = ipToInt (lib.head parts); inherit prefix; size = pow 2 (addressBits - prefix); };
in {
  inherit ipToInt;

  prefix = cidr: (parse cidr).prefix;

  # host n of a subnet, asserted inside it (neither the network nor the broadcast address)
  host = cidr: n:
    let c = parse cidr; in
    assert lib.assertMsg (n > 0 && n < c.size - 1) "cidr.nix: host ${toString n} lies outside ${cidr}";
    intToIp (c.network + n);

  contains = cidr: ip:
    let c = parse cidr; i = ipToInt ip; in i >= c.network && i < c.network + c.size;

  # two subnets share an address
  overlaps = a: b:
    let x = parse a; y = parse b; in x.network < y.network + y.size && y.network < x.network + x.size;
}
