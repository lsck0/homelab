# TeamSpeak 6 server, the official image; ServerQuery (ssh, http) stays off as the image ships it
# the first start prints the serveradmin privilege key to the container log (skill.md); it is never in the repo
{ catalog, ... }:
let
  container = "teamspeak";
  # beta13.1, the index digest pinned: a retagged beta never slips in
  image = "docker.io/teamspeaksystems/teamspeak6-server:6.0.0-beta13.1@sha256:d845f803aecf842c2df034c959c23ff2462357bacafb3807500885c5ec170fa1";
  # the image's WORKDIR and VOLUME: config, sqlite db, files/, logs/
  dataDir = "/var/tsserver";
  stateDir = "/var/lib/teamspeak";
  # the image's teamspeak user and group
  uid = "9987";
  voicePort = toString catalog.l4.teamspeak.port;
  filesPort = toString catalog.l4.teamspeak-files.port;
in {
  homelab.localState.teamspeak = {
    path = stateDir;
    unit = "podman-${container}";
    sqlite = [ "*.sqlitedb" ];
    # the logs hold the privilege key: they stay on the guest, out of the nas and its snapshots
    exclude = [ "logs" "crashdumps" ];
  };

  virtualisation.oci-containers.containers.${container} = {
    inherit image;
    ports = [ "${voicePort}:${voicePort}/udp" "${filesPort}:${filesPort}/tcp" ];
    volumes = [ "${stateDir}:${dataDir}" ];
    environment = {
      TSSERVER_LICENSE_ACCEPTED = "accept";
      TSSERVER_DEFAULT_PORT = voicePort;
      TSSERVER_FILE_TRANSFER_PORT = filesPort;
    };
  };

  systemd.tmpfiles.rules = [ "d ${stateDir} 0750 ${uid} ${uid} -" ];
}
