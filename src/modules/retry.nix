{ pkgs, ... }: {
  # `${retry} <attempts> <interval seconds> <command...>`: runs the command
  # until it succeeds. Gives up loudly after the last attempt, so a unit that
  # waits for its app fails instead of carrying on against a service that
  # never came up. Output of the attempts is discarded.
  _module.args.retry = pkgs.writeShellScript "retry" ''
    if [ "$#" -lt 3 ] || ! [ "$1" -gt 0 ] 2>/dev/null || ! [ "$2" -ge 0 ] 2>/dev/null; then
      echo "usage: retry <attempts> <interval seconds> <command...>" >&2
      exit 2
    fi
    attempts=$1 interval=$2; shift 2
    for ((i = 1; i <= attempts; i++)); do
      "$@" >/dev/null 2>&1 && exit 0
      (( i < attempts )) && ${pkgs.coreutils}/bin/sleep "$interval"
    done
    echo "retry: gave up after $attempts attempts: $*" >&2
    exit 1
  '';
}
