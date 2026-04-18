with open('src/instances/300-router.nix', 'r') as f:
    config = f.read()

config = config.replace('networking.interfaces.ens18.useDHCP = true;', '# networking.interfaces.ens18.useDHCP = true;  # Handled by cloud-init static IP')

with open('src/instances/300-router.nix', 'w') as f:
    f.write(config)
