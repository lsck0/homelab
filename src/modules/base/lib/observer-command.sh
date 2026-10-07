#!/usr/bin/env bash
# the forced command of every key in src/lab/keys/observer: read-only inspection, never a shell
#
# ssh hands the requested command over as one string; it is split on whitespace (no quoting, no globbing) and runs
# only when its first words are on the list below. systemctl and journalctl run as the unprivileged observer, so
# polkit refuses any change even past this list; the pager is off, so no `!sh` escape exists either.
set -euo pipefail -f

deny() {
  echo "observer: '$SSH_ORIGINAL_COMMAND' is not read-only; allowed: systemctl status|show|cat|is-active|is-failed|is-enabled|list-units|list-timers|list-unit-files, journalctl, df, free, uptime" >&2
  exit 126
}

read -r -a argv <<< "${SSH_ORIGINAL_COMMAND:-}"
[ "${#argv[@]}" -gt 0 ] || deny

case "${argv[0]}" in
  systemctl)
    case "${argv[1]:-}" in
      status | show | cat | is-active | is-failed | is-enabled | list-units | list-timers | list-unit-files) ;;
      *) deny ;;
    esac
    ;;
  journalctl)
    for arg in "${argv[@]:1}"; do
      case "$arg" in
        --vacuum* | --rotate | --flush | --sync | --relinquish-var | --smart-relinquish-var | --setup-keys | --update-catalog) deny ;;
        -D* | --directory* | --file* | --root* | --image* | -M* | --machine* | --merge) deny ;;
      esac
    done
    ;;
  df | free | uptime) ;;
  *) deny ;;
esac

export SYSTEMD_PAGER="" SYSTEMD_PAGERSECURE=1
exec "${argv[@]}"
