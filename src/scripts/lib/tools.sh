# shellcheck shell=bash
# sourced by the repo's scripts: the tools they need, checked once at startup
#
# Every tool comes from the flake's dev shell (`nix develop ./src`), pinned by src/flake.lock; a script names what
# it needs before it does any work, so a missing tool stops it with the fix instead of failing three steps in.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/tools.sh"
#   tools_require sops jq age-keygen

# tools_require <tool>...: exits 1 naming every missing tool
tools_require() {
  local tool absent=()
  for tool in "$@"; do
    command -v "$tool" >/dev/null || absent+=("$tool")
  done
  [ "${#absent[@]}" = 0 ] && return 0
  echo "ERROR: missing ${absent[*]}: run inside the dev shell, \`nix develop ./src\` from the repo root." >&2
  exit 1
}
