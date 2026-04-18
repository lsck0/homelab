with open('sync.sh', 'r') as f:
    sync_content = f.read()

# Make sure we don't use 'root' in sync.sh if it expects 'luca'.
# sync.sh: `ssh ... "root@${ip}"` -> it already uses root!
# But the user says "change the usernames on the vms to root".
# Wait, look at the output of terraform from earlier:
# "ssh-ed25519 AAAAC... homelab-deploy@luca-pc" -> that's the key.

# Wait, maybe they mean in the Nix config?
# `users.users.luca` -> they want to remove `luca` and just use `root`?
# Okay, let's remove `luca` user from flake.nix.
