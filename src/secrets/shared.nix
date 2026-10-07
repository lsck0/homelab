# the secrets two or more hosts read, and the lab's own that only scripts and the owner use: name -> its kind
#
# A secret only one guest reads is declared in that guest's instance.nix `secrets`, an app's in its app.nix; every
# oidc client's secret is derived from its service (modules/secrets.nix). The values of these live in
# src/secrets/shared.sops.json (`sops src/secrets/shared.sops.json`); src/scripts/secrets-sync.sh adds a missing one by its kind:
#   "hex:<bytes>"          that many random bytes as hex
#   "wireguard"            a wireguard private key: 32 random bytes as base64, clamped by wireguard
#   "ntfy-token"           tk_ and 29 of [a-z0-9], the only shape ntfy accepts
#   "garage-key-id"        GK and 12 random bytes as hex (apps)
#   "guardsData:<kind>"    a key that data or logins depend on (a backup repository, an encrypted db, an app login
#                          set once): generated as <kind> only on secrets-sync.sh --generate-guarded, a missing one
#                          stops every other run, since a fresh value would lock the data out
#   "manual"               a human or src/scripts/init.sh sets it; added empty
#   "public"               set like manual, but no secret (an id or account name): the plaintext guard
#                          (src/scripts/secrets-check.sh) skips it, since it legitimately appears in code
#   "dotfiles:<file>"      copied from that file of the dotfiles' secrets on every run
{
  attic-pull-token = "manual"; # atticadm make-token, read-only: every guest substitutes from the cache with it
  cloudflare-token = "manual";
  crowdsec-bouncer-key = "hex:24";
  github-mirror-token = "manual";
  ntfy-grafana-password = "hex:24";
  ntfy-hermes-password = "hex:24";
  # the webui login beyond its whitelist (112's setup sets it on every run): the arrs' download client, the dashboard
  qbittorrent-pass = "hex:16";
  # an *arr's api key, set through its environment (130's lib/servarr.nix); the arrs, janitorr, hermes and the
  # dashboard call the apis with it, so a lost one is restored, never regenerated
  lidarr-key = "guardsData:hex:16";
  prowlarr-key = "guardsData:hex:16";
  radarr-key = "guardsData:hex:16";
  sonarr-key = "guardsData:hex:16";
  # jellyfin's local admin, set once by 134's setup; jellyseerr imports jellyfin with it (130's arr-wire)
  jellyfin-admin-pass = "guardsData:hex:16";
  registry-builder-password = "hex:24"; # registry user builder: the app builder on vm-140
  registry-push-password = "hex:24"; # registry user ci: REGISTRY_PASSWORD of the repos that push images
  registry-pull-password = "hex:24"; # registry user puller: read-only pulls
  sccache-redis-pass = "hex:24";
  telegram-bot-token = "manual"; # hermes-secrets.sh
  telegram-chat-id = "public"; # hermes-secrets.sh: the owner's telegram user id

  # read by no guest
  proxmox-root-pass = "hex:24"; # proxmox root@pam, set by sync.sh; its own, shared with no guest
  # the proton account: restoring the off-site backup signs in with it (README, Recovery)
  proton-username = "public";
  proton-password = "manual";
  proton-totp-secret = "manual";
}
