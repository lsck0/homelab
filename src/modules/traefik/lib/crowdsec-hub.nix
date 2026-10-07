# crowdsec's rules: the hub as of one commit and the collections the ingresses install from it, offline
# (tests/crowdsec-hub.nix installs them without a network)
{ pkgs }:
{
  hub = pkgs.fetchFromGitHub {
    owner = "crowdsecurity";
    repo = "hub";
    rev = "f5cd0975d0bd69ebad09c5e6992d4f1a1ef594b0";
    hash = "sha256-CT3Fah8RSuKkL4MmeJP2aEiUFs/fG7oXQOuZFJUxaks=";
  };
  collections = [
    "crowdsecurity/traefik"
    "crowdsecurity/http-cve"
    "crowdsecurity/appsec-virtual-patching"
    "crowdsecurity/appsec-generic-rules"
    "crowdsecurity/appsec-crs-inband"
  ];
}
