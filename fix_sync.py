with open('sync.sh', 'r') as f:
    sync_content = f.read()

# The regex accidentally deleted the closing bracket `}` of the `setup_ssh_transport()` function because the matching was too greedy or matched the wrong thing.
# Let's restore the closing bracket.
sync_content = sync_content.replace('export NIX_SSHOPTS="-F $SSH_CONFIG"\n', 'export NIX_SSHOPTS="-F $SSH_CONFIG"\n}\n')

with open('sync.sh', 'w') as f:
    f.write(sync_content)
