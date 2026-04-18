with open('src/instances/105-internal-sccache.nix', 'r') as f:
    config = f.read()

config = config.replace("""
  services.redis.servers.sccache = {
    enable = true;
    port = 6379;
    extraConfig = ''
      protected-mode no
      maxmemory 2gb
      maxmemory-policy allkeys-lru
      appendonly yes
    '';
  };
""", """
  services.redis.servers.sccache = {
    enable = true;
    port = 6379;
    appendOnly = true;
  };
""")

with open('src/instances/105-internal-sccache.nix', 'w') as f:
    f.write(config)
