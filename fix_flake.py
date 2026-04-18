import re
with open('src/flake.nix', 'r') as f:
    flake = f.read()

# Replace luca user with nothing
flake = re.sub(r'users\.users\.luca\s*=\s*\{\s*isNormalUser\s*=\s*true;\s*extraGroups\s*=\s*\[\s*"wheel"\s*\];\s*\};\n\n', '', flake)

# Also check for homelab.acmeEmail = "luca.sandrock@proton.me" maybe? Let's leave that.
with open('src/flake.nix', 'w') as f:
    f.write(flake)
