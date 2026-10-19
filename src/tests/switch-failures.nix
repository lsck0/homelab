# lab-wide: scripts/lib/switch-failures.nu, how sync.nu judges a failed switch
# a declared unit that failed is named, a transient or collected one is not, and output naming no unit at all (the
# switch itself failed) gives its last lines; systemctl is a stub answering per unit. No network.
{ pkgs, ... }:
let
  # run-1 is transient, gone was collected, every other unit is declared and loaded
  systemctl = pkgs.writeShellScriptBin "systemctl" ''
    # systemctl show -P <property> -- <unit>
    case "$5:$3" in
      run-1.service:Transient) echo yes ;;
      gone.service:LoadState) echo not-found ;;
      *:Transient) echo no ;;
      *) echo loaded ;;
    esac
  '';
  script = ../scripts/lib/switch-failures.nu;
in
pkgs.runCommand "switch-failures"
  {
    nativeBuildInputs = [
      pkgs.nushell
      systemctl
    ];
  }
  ''
    export HOME=$TMPDIR
    judge() { printf '%b' "$1" | nu --no-config-file --stdin ${script}; }
    expect() {
      if [ "$2" != "$3" ]; then
        echo "FAIL: $1: '$2', not '$3'"
        exit 1
      fi
    }
    expect "a declared unit" "$(judge 'warning: the following units failed: nginx.service, run-1.service\n')" "nginx.service"
    expect "transient and collected units" "$(judge 'warning: the following units failed: run-1.service, gone.service\n')" ""
    expect "the switch itself" "$(judge 'one\ntwo\n\nerror: activation script failed\nthree\n')" \
      "two | error: activation script failed | three"
    expect "no output" "$(judge "")" "the switch printed nothing"
    touch $out
  ''
