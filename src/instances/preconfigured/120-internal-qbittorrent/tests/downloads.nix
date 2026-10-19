# vm-120's declared qbittorrent preferences keep runnable files off the media share: the excluded file names, as
# qbittorrent matches them (a wildcard on the file's own name, case-insensitive), against a table of release files
{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  prefs =
    inputs.self.nixosConfigurations."120-internal-qbittorrent".config.systemd.services.qbittorrent-settings.environment.QBITTORRENT_PREFS;
  # <file in a torrent> <excluded: yes|no>
  cases = [
    [
      "Lanterns.2026.S01E08.Dirt.and.Stars.1080p.WEB.H264-RAWR.exe"
      "yes"
    ]
    [
      "Lanterns 2026 S01E08/Setup.EXE"
      "yes"
    ]
    [
      "Movie.2024/codec-installer.msi"
      "yes"
    ]
    [
      "Show.S01/play.lnk"
      "yes"
    ]
    [
      "Show.S01/readme.txt.js"
      "yes"
    ]
    [
      "Show.S01/run.ps1"
      "yes"
    ]
    [
      "Lanterns.2026.S01E08.1080p.WEB.H264-RAWR.mkv"
      "no"
    ]
    [
      "Movie.2024/Subs/English.srt"
      "no"
    ]
    [
      "Album/01 - Track.flac"
      "no"
    ]
    [
      "Book/book.epub"
      "no"
    ]
    [
      "Movie.exe.2024/Movie.2024.mkv"
      "no"
    ]
  ];
in
pkgs.runCommand "downloads" { nativeBuildInputs = [ pkgs.jq ]; } ''
  set -euo pipefail
  fail() { echo "FAIL: $*" >&2; exit 1; }
  pass() { echo "PASS: $*"; }
  jq -e '.excluded_file_names_enabled == true' ${prefs} >/dev/null || fail "excluded file names are off"
  mapfile -t patterns < <(jq -r '.excluded_file_names | split("\n")[]' ${prefs})
  (( ''${#patterns[@]} > 0 )) || fail "no excluded file names"
  shopt -s nocasematch
  excluded() {
    local name=''${1##*/} pattern
    for pattern in "''${patterns[@]}"; do
      # shellcheck disable=SC2053 # the pattern is a glob
      [[ $name == $pattern ]] && return 0
    done
    return 1
  }
  ${lib.concatMapStrings (c: ''
    got=no
    if excluded ${lib.escapeShellArg (lib.elemAt c 0)}; then got=yes; fi
    [ "$got" = ${lib.elemAt c 1} ] || fail ${lib.escapeShellArg "${lib.elemAt c 0}: excluded $got, want ${lib.elemAt c 1}"}
    pass ${lib.escapeShellArg "${lib.elemAt c 0}: excluded ${lib.elemAt c 1}"}
  '') cases}
  touch $out
''
