# shellcheck shell=bash
# sourced by sync.sh: terraform's state between the workstation and the nas
#
# The nas holds the authoritative state (/srv/nas/terraform/terraform.tfstate, which kopia snapshots); a sync works
# on a local copy. A sync holds the nas lock from before its pull to its exit, so the pulls, applies and pushes of two
# deployers never interleave. A push can still fail (the nas went away mid-run), which leaves the local copy ahead
# for the next run, and another deployer may have applied in between. So each side remembers the nas content it last
# agreed with ($TFSTATE_LOCAL.synced, a sha256), and:
#   pull: the nas is unchanged since the last agreement: keep the local copy (it holds our unpushed apply, if any).
#         The nas changed and the local copy did not: take the nas copy. Both changed: stop, two applies diverged and
#         only a human can tell which one Proxmox matches. Another lineage always stops.
#   push: only a nas copy equal to the last agreement may be replaced, and only by a newer serial of its lineage.
# Rejected: comparing serials alone. Two deployers that both pulled serial 10 and applied both hold 11, and the
# second push was dropped; with one push failed, the ahead copy later overwrote the other deployer's apply.
#
# The caller defines the transport, so tests run all of this on local files:
#   tfstate_remote_read <out>   copy the nas state to <out>; 0 done, 1 nas unreachable, 2 no state on the nas yet
#   tfstate_remote_write <in>   replace the nas state with <in> atomically; non-zero on failure
#   tfstate_remote_lock         hold the nas lock: print "locked" once held (or "busy"), keep it until stdin closes
# and sets TFSTATE_LOCAL (the working copy). Every function prints why it stops and returns 1; none exits.
#
#   tfstate_lock_acquire && tfstate_pull && terraform apply ... && tfstate_push; tfstate_lock_release

# how long the nas may take to answer the lock request
TFSTATE_LOCK_TIMEOUT_S=30

# "<lineage> <serial>" of a state file
tfstate_meta() { jq -r '"\(.lineage) \(.serial)"' "$1"; }
tfstate_hash() { sha256sum "$1" | cut -d' ' -f1; }
# the hash of the nas content this copy last agreed with, empty before the first agreement
tfstate_synced_get() { cat "$TFSTATE_LOCAL.synced" 2>/dev/null || true; }
tfstate_synced_set() { tfstate_hash "$1" > "$TFSTATE_LOCAL.synced"; }

# -----------------------------------------------------------------------------
# LOCK
# -----------------------------------------------------------------------------

tfstate_lock_acquire() {
  local answer=""
  # fifos, not a coproc: bash drops a coproc's fds the moment it exits, racing the read of its "busy"
  TFSTATE_LOCK_DIR=$(mktemp -d)
  mkfifo "$TFSTATE_LOCK_DIR/in" "$TFSTATE_LOCK_DIR/out"
  tfstate_remote_lock < "$TFSTATE_LOCK_DIR/in" > "$TFSTATE_LOCK_DIR/out" &
  TFSTATE_LOCK_PID=$!
  # in this order: the holder opens its stdin first, then its stdout
  exec {TFSTATE_LOCK_IN}> "$TFSTATE_LOCK_DIR/in"
  exec {TFSTATE_LOCK_OUT}< "$TFSTATE_LOCK_DIR/out"
  read -r -t "$TFSTATE_LOCK_TIMEOUT_S" answer <&"$TFSTATE_LOCK_OUT" || true
  case "$answer" in
    locked) return 0 ;;
    busy) echo "ERROR: another sync holds the terraform state lock on the nas; wait for it to finish." ;;
    *) echo "ERROR: could not take the terraform state lock: the nas does not answer." \
         "Rerun with TF_STATE_OFFLINE=1 to apply from the local copy, which may be behind the nas." ;;
  esac
  tfstate_lock_release
  return 1
}

# closing the holder's stdin ends it on the nas, which drops the lock; safe to call when nothing is held
tfstate_lock_release() {
  [ -n "${TFSTATE_LOCK_PID:-}" ] || return 0
  exec {TFSTATE_LOCK_IN}>&-
  wait "$TFSTATE_LOCK_PID" 2>/dev/null || true
  exec {TFSTATE_LOCK_OUT}<&-
  rm -rf "$TFSTATE_LOCK_DIR"
  TFSTATE_LOCK_PID=""
}

# -----------------------------------------------------------------------------
# PULL AND PUSH
# -----------------------------------------------------------------------------

# tfstate_pull: makes $TFSTATE_LOCAL current. TF_STATE_FRESH=1 allows starting without any state (first deploy)
tfstate_pull() {
  local remote rc=0 l_lin l_ser r_lin r_ser synced
  remote=$(mktemp --suffix=.tfstate)
  tfstate_remote_read "$remote" || rc=$?
  case "$rc" in
    0) ;;
    1) rm -f "$remote"; echo "ERROR: the nas does not answer; terraform state not pulled."; return 1 ;;
    2) rm -f "$remote"
       if [ -f "$TFSTATE_LOCAL" ]; then echo ">>> Terraform state: none on the nas yet, the local copy goes up after the apply."; return 0; fi
       if [ "${TF_STATE_FRESH:-0}" = 1 ]; then echo ">>> Terraform state: starting empty (TF_STATE_FRESH=1)."; return 0; fi
       echo "ERROR: no terraform state, neither on the nas nor in $TFSTATE_LOCAL."
       echo "       First deploy of an empty lab: rerun with TF_STATE_FRESH=1."
       return 1 ;;
    *) rm -f "$remote"; echo "ERROR: reading the nas state failed ($rc)."; return 1 ;;
  esac
  jq -e '(.lineage | type == "string") and (.serial | type == "number")' "$remote" >/dev/null 2>&1 \
    || { rm -f "$remote"; echo "ERROR: the nas terraform state is not a terraform state."; return 1; }
  read -r r_lin r_ser < <(tfstate_meta "$remote")
  if [ -f "$TFSTATE_LOCAL" ]; then
    read -r l_lin l_ser < <(tfstate_meta "$TFSTATE_LOCAL")
    synced=$(tfstate_synced_get)
    if [ "$l_lin" != "$r_lin" ]; then
      rm -f "$remote"
      echo "ERROR: terraform state lineage differs: nas $r_lin (serial $r_ser), local $l_lin (serial $l_ser)."
      echo "       Keep the right one, delete the other, and rerun."
      return 1
    fi
    if cmp -s "$remote" "$TFSTATE_LOCAL"; then
      rm -f "$remote"; tfstate_synced_set "$TFSTATE_LOCAL"
      echo ">>> Terraform state: local copy matches the nas (serial $r_ser)."
      return 0
    fi
    # the nas is as we left it: the local copy is ours, a push that failed last run
    if [ -n "$synced" ] && [ "$(tfstate_hash "$remote")" = "$synced" ] && [ "$l_ser" -ge "$r_ser" ]; then
      rm -f "$remote"
      echo ">>> Terraform state: local serial $l_ser is ahead of the nas ($r_ser), a push failed last run; keeping it."
      return 0
    fi
    # the nas moved on; the local copy may only follow when it holds nothing of its own
    if [ "$(tfstate_hash "$TFSTATE_LOCAL")" != "$synced" ] && { [ -n "$synced" ] || [ "$l_ser" -ge "$r_ser" ]; }; then
      rm -f "$remote"
      echo "ERROR: the nas state (serial $r_ser) and $TFSTATE_LOCAL (serial $l_ser) both changed since they last agreed:"
      echo "       two applies diverged. Compare them (terraform show), keep the one Proxmox matches, delete the other, rerun."
      return 1
    fi
  fi
  mv "$remote" "$TFSTATE_LOCAL"
  chmod 600 "$TFSTATE_LOCAL"
  tfstate_synced_set "$TFSTATE_LOCAL"
  echo ">>> Terraform state: pulled from the nas (serial $r_ser)."
}

# tfstate_push: after an apply, under the lock; the local copy stays ahead when the nas is gone, the next run pushes it
tfstate_push() {
  local remote rc=0 l_lin l_ser r_lin r_ser synced
  [ -f "$TFSTATE_LOCAL" ] || return 0
  read -r l_lin l_ser < <(tfstate_meta "$TFSTATE_LOCAL")
  synced=$(tfstate_synced_get)
  remote=$(mktemp --suffix=.tfstate)
  tfstate_remote_read "$remote" || rc=$?
  case "$rc" in
    0)
      if cmp -s "$remote" "$TFSTATE_LOCAL"; then rm -f "$remote"; tfstate_synced_set "$TFSTATE_LOCAL"; return 0; fi
      read -r r_lin r_ser < <(tfstate_meta "$remote")
      if [ "$(tfstate_hash "$remote")" != "$synced" ] || [ "$l_lin" != "$r_lin" ] || [ "$l_ser" -le "$r_ser" ]; then
        rm -f "$remote"
        echo "ERROR: the nas state ($r_lin, serial $r_ser) is not the one this run started from; local is $l_lin, serial $l_ser."
        echo "       Not pushed: compare them, keep the one Proxmox matches, delete the other, rerun."
        return 1
      fi
      rm -f "$remote" ;;
    1) rm -f "$remote"; echo "WARNING: the nas does not answer; terraform state not pushed, the next sync pushes it."; return 0 ;;
    2) rm -f "$remote" ;;
    *) rm -f "$remote"; echo "ERROR: reading the nas state failed ($rc)."; return 1 ;;
  esac
  tfstate_remote_write "$TFSTATE_LOCAL" || { echo "WARNING: terraform state push failed; the next sync pushes it."; return 0; }
  tfstate_synced_set "$TFSTATE_LOCAL"
  echo ">>> Terraform state: pushed to the nas (serial $l_ser)."
}
