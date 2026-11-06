#!/usr/bin/env bash
# run-batch.sh — run unpin-pv.sh for each PV in a list, one at a time; stop on the
# first non-zero exit. (граф `@cloudless/fluence`, узел #4193)
#
# Usage: run-batch.sh <pv-list-file> [--apply] [--backup-dir DIR]
#   list: one PV name per line (first field; '#' lines ignored).
#   Without --apply every PV gets a dry run (no writes).
#   Log: <list>.<ctx>.<stamp>[.apply].log next to the list.
#   --backup-dir  passed to unpin-pv.sh (default ./storage-backup)
# Env:   KUBECTL, or INFRA_KUBECONFIG + BEAM_NS + CTX for kubectl-via-beam-agent.sh
# Exit:  0 all ok, otherwise the exit code of the first failing unpin-pv.sh (1 = bad usage)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LIST="" MODE="" BACKUP_DIR=./storage-backup
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) MODE=--apply ;;
    --backup-dir) BACKUP_DIR="${2:?--backup-dir needs a value}"; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    -*) echo "unknown flag $1" >&2; exit 1 ;;
    *) [[ -z "$LIST" ]] || { echo "only one list" >&2; exit 1; }; LIST="$1" ;;
  esac
  shift
done
[[ -n "$LIST" ]] || { echo "usage: $0 <pv-list-file> [--apply] [--backup-dir DIR]" >&2; exit 1; }
[[ -r "$LIST" ]] || { echo "cannot read $LIST" >&2; exit 1; }
if [[ -z "${KUBECTL:-}" ]]; then
  K=$("$HERE/kubectl-via-beam-agent.sh") || exit 1
  eval "$K"
fi
export KUBECTL
LOG="$LIST.${CTX:-kubectl}.$(date -u +%Y%m%dT%H%M%SZ)${MODE:+.apply}.log"
mapfile -t PVS < <(grep -v '^\s*#' "$LIST" | awk 'NF{print $1}')
echo "context ${CTX:-from KUBECTL}, ${#PVS[@]} PVs, mode ${MODE:-dry-run}, log $LOG" | tee "$LOG"
n=0
for pv in "${PVS[@]}"; do
  n=$((n+1)); echo "===== [$n/${#PVS[@]}] $pv" | tee -a "$LOG"
  "$HERE/unpin-pv.sh" "$pv" ${MODE:+"$MODE"} --backup-dir "$BACKUP_DIR" </dev/null >>"$LOG" 2>&1
  rc=$?
  tail -n 3 "$LOG" | sed 's/^/    /'
  if [[ $rc -ne 0 ]]; then echo "STOP: $pv exit $rc — see $LOG" | tee -a "$LOG"; exit $rc; fi
  [[ -n "$MODE" ]] && sleep 3
done
echo "all ${#PVS[@]} ok" | tee -a "$LOG"
