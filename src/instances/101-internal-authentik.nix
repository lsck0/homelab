{ config, ... }: {
  networking.hostName = "vm-101";

  sops.secrets.authentik-secret-key = {};
  sops.templates."authentik.env".content = ''
    AUTHENTIK_SECRET_KEY=${config.sops.placeholder.authentik-secret-key}
    AUTHENTIK_ERROR_REPORTING__ENABLED=true
    AUTHENTIK_REDIS__HOST=redis
    AUTHENTIK_POSTGRESQL__HOST=postgresql
    AUTHENTIK_POSTGRESQL__USER=authentik
    AUTHENTIK_POSTGRESQL__NAME=authentik
    AUTHENTIK_POSTGRESQL__PASSWORD=authentik
  '';

  homelab.dockerStack = {
    enable = true;
    stackName = "authentik";
    composeFile = ''
      version: "3.4"
      services:
        postgresql:
          image: docker.io/library/postgres:16-alpine
          restart: unless-stopped
          healthcheck:
            test: ["CMD-SHELL", "pg_isready -d $${POSTGRES_DB} -U $${POSTGRES_USER}"]
            start_period: 20s
            interval: 30s
            retries: 5
            timeout: 5s
          volumes:
            - /var/lib/authentik/db:/var/lib/postgresql/data
          environment:
            POSTGRES_PASSWORD: authentik
            POSTGRES_USER: authentik
            POSTGRES_DB: authentik
        redis:
          image: docker.io/library/redis:alpine
          command: --save 60 1 --loglevel warning
          restart: unless-stopped
          healthcheck:
            test: ["CMD-SHELL", "redis-cli ping | grep PONG"]
            start_period: 20s
            interval: 30s
            retries: 5
            timeout: 3s
          volumes:
            - /var/lib/authentik/redis:/data
        server:
          image: ghcr.io/goauthentik/server:2024.2.2
          restart: unless-stopped
          command: server
          environment:
            AUTHENTIK_REDIS__HOST: redis
            AUTHENTIK_POSTGRESQL__HOST: postgresql
            AUTHENTIK_POSTGRESQL__USER: authentik
            AUTHENTIK_POSTGRESQL__NAME: authentik
            AUTHENTIK_POSTGRESQL__PASSWORD: authentik
          env_file:
            - ${config.sops.templates."authentik.env".path}
          volumes:
            - /var/lib/authentik/media:/media
            - /var/lib/authentik/custom-templates:/templates
          ports:
            - "80:9000"
            - "443:9443"
          depends_on:
            - postgresql
            - redis
        worker:
          image: ghcr.io/goauthentik/server:2024.2.2
          restart: unless-stopped
          command: worker
          environment:
            AUTHENTIK_REDIS__HOST: redis
            AUTHENTIK_POSTGRESQL__HOST: postgresql
            AUTHENTIK_POSTGRESQL__USER: authentik
            AUTHENTIK_POSTGRESQL__NAME: authentik
            AUTHENTIK_POSTGRESQL__PASSWORD: authentik
          env_file:
            - ${config.sops.templates."authentik.env".path}
          user: root
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock
            - /var/lib/authentik/media:/media
            - /var/lib/authentik/certs:/certs
            - /var/lib/authentik/custom-templates:/templates
          depends_on:
            - postgresql
            - redis
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/authentik/db 0750 70 70 -"
    "d /var/lib/authentik/redis 0750 999 999 -"
    "d /var/lib/authentik/media 0750 1000 1000 -"
    "d /var/lib/authentik/custom-templates 0750 1000 1000 -"
    "d /var/lib/authentik/certs 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
