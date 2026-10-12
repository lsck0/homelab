# TeamSpeak 6 voice server for the owner and friends, at ts.lsck0.dev
{ config, profiles, ... }: {
  vm = {
    bootPhase = "public";
    # the official image; its sqlite db and uploads mirrored to the nas (localState)
    needs = [ "containers" "nfs" ];
    # the vm's own ~600 MiB plus the server's 100-200 MiB
    memoryMiB = 1024;
  };

  services = {
    # voice: what a client dials at ts.lsck0.dev, the protocol's default port, so no srv record is needed to reach it
    teamspeak = {
      host = "ts";
      protocol = "udp";
      port = 9987;
      publicPort = config.services.teamspeak.port;
      srv = "_ts3._udp";
      # the router caps and logs its forward; udp has no generic probe, the file transfer route carries it
      on = [ "inflightLimit" "accessLog" ] ++ profiles.observed;
    };
    # file transfer: channel uploads and avatars; the voice route's board and alerts cover the server
    teamspeak-files = {
      host = "ts";
      protocol = "tcp";
      port = 30033;
      publicPort = config.services.teamspeak-files.port;
      on = [ "inflightLimit" "accessLog" "probe" ];
    };
  };

  shares = {
    "data/teamspeak".localState = true;
  };
}
