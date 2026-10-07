# huginn: automation agents, logins through authelia's Remote-User header, postgres on the host
{ config, pkgs, catalog, nasMount, site, ... }:
let
  route = catalog.internal.huginn;
  stateDir = "/var/lib/huginn";
  seedEnv = "${stateDir}/seed.env";
  containerPort = 3000;
  # the container's user, which owns the state dir
  containerUid = 1000;
  postgresPort = config.services.postgresql.settings.port;
  database = "huginn";
  # the admin huginn seeds on a fresh database
  seedUser = "akadmin";
  # podman's default bridge: the container reaches the host's postgres at its gateway
  podmanBridge = { subnet = "10.88.0.0/16"; gateway = "10.88.0.1"; };
  # authelia Remote-User login; the first admin to log in takes over the seeded one
  remoteUser = pkgs.writeText "zz_remote_user.rb" ''
    Rails.application.config.to_prepare do
      ApplicationController.prepend_before_action do
        # REMOTE_USER is a cgi var, headers["Remote-User"] never sees the http header
        name = request.get_header("HTTP_REMOTE_USER")
        next if name.blank? || (user_signed_in? && current_user.username == name)
        email = request.get_header("HTTP_REMOTE_EMAIL").presence || "#{name}@${site.domain}"
        admin = request.get_header("HTTP_REMOTE_GROUPS").to_s.split(",").map(&:strip).include?("admins")
        user = User.find_by(username: name)
        user ||= User.find_by(username: "${seedUser}")&.tap { |u| u.update!(username: name, email: email) } if admin
        user ||= User.new(username: name, email: email, password: SecureRandom.hex(32), admin: admin).tap do |u|
          u.requires_no_invitation_code!
          u.save!
        end
        sign_in(user)
      end
    end
  '';
in {
  networking.hostName = "vm-126";

  homelab.nasMounts = nasMount stateDir "huginn"
    // nasMount "/var/lib/postgresql" "huginn-db";

  services.postgresql = {
    enable = true;
    enableTCPIP = true;
    ensureDatabases = [ database ];
    ensureUsers = [{
      name = database;
      ensureDBOwnership = true;
      ensureClauses.createdb = true;
    }];
    authentication = ''
      local all all trust
      host all all 127.0.0.1/32 trust
      host all all ::1/128 trust
      # all dbs: db:create connects to `postgres` first
      host all ${database} ${podmanBridge.subnet} trust
    '';
  };

  virtualisation.oci-containers.containers.huginn = {
    image = "ghcr.io/huginn/huginn:f2cc19148df9a4785d789d30f0b10d1d9c2dae10";
    ports = [ "${toString route.port}:${toString containerPort}" ];
    volumes = [
      "${stateDir}:${stateDir}"
      "${remoteUser}:/app/config/initializers/zz_remote_user.rb:ro"
    ];
    environmentFiles = [ seedEnv ];
    environment = {
      DOMAIN = "${route.host}.${site.domain}";
      DATABASE_ADAPTER = "postgresql";
      DATABASE_HOST = podmanBridge.gateway;
      DATABASE_PORT = toString postgresPort;
      DATABASE_NAME = database;
      DATABASE_USERNAME = database;
      SEED_USERNAME = seedUser;
      REQUIRE_CONFIRMED_EMAIL = "false";
    };
  };

  # SEED_PASSWORD for the first admin, generated once
  systemd.services.huginn-seed = {
    before = [ "podman-huginn.service" ];
    requiredBy = [ "podman-huginn.service" ];
    path = [ pkgs.openssl pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      [ -s ${seedEnv} ] || echo "SEED_PASSWORD=$(openssl rand -hex 16)" > ${seedEnv}
      chmod 600 ${seedEnv}
    '';
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 ${toString containerUid} ${toString containerUid} -"
  ];

  networking.firewall.allowedTCPPorts = [ route.port ];
  homelab.ingressOnly.ports = [ route.port ];
  # postgres for the podman bridge only
  networking.firewall.interfaces.podman0.allowedTCPPorts = [ postgresPort ];

  # a dump: a live data dir on nfs copies inconsistently
  homelab.dbBackup.databases.huginn = {
    command = "runuser -u postgres -- pg_dumpall --clean --if-exists";
    path = [ config.services.postgresql.package pkgs.util-linux ];
  };
  systemd.services.db-backup-huginn = {
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
  };
}
