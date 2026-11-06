#!/usr/bin/env bash
# run-rwo-batch.sh — run swap-rwo.sh for each disk in a list, one at a time.
# (граф `@cloudless/fluence`, узел #4309)
#
# Usage: run-rwo-batch.sh <list-file> [--apply] [--backup-dir DIR]
#   list: "namespace pvc [# comment]" per line.
#   Dry run: every disk, reports refusals and continues. --apply: stops on the first non-zero exit.
#   Log: <list>.<stamp>[.apply].log next to the list.
#   --backup-dir  passed to swap-rwo.sh (default ./storage-backup)
#   swap-rwo.sh gets stdin from /dev/null (a `kubectl exec -i` KUBECTL eats it).
# Env:   KUBECTL, or INFRA_KUBECONFIG + BEAM_NS + CTX for kubectl-via-beam-agent.sh
# Exit:  0 all ok; dry run 1 if any disk was non-zero; --apply the first failing exit code
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LIST="" MODE="" BACKUP_DIR=./storage-backup
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) MODE=--apply ;;
    --backup-dir) BACKUP_DIR="${2:?--backup-dir needs a value}"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) echo "unknown flag $1" >&2; exit 1 ;;
    *) [[ -z "$LIST" ]] || { echo "only one list" >&2; exit 1; }; LIST="$1" ;;
  esac
  shift
done
[[ -n "$LIST" ]] || { echo "usage: $0 <list-file> [--apply] [--backup-dir DIR]" >&2; exit 1; }
[[ -r "$LIST" ]] || { echo "cannot read $LIST" >&2; exit 1; }
if [[ -z "${KUBECTL:-}" ]]; then
  K=$("$HERE/kubectl-via-beam-agent.sh") || exit 1
  eval "$K"
fi
export KUBECTL
LOG="$LIST.$(date -u +%Y%m%dT%H%M%SZ)${MODE:+.apply}.log"
mapfile -t ROWS < <(sed 's/#.*//' "$LIST" | awk 'NF>=2{print $1" "$2}')
echo "context ${CTX:-from KUBECTL}, ${#ROWS[@]} disks, mode ${MODE:-dry-run}, log $LOG" | tee "$LOG"
n=0 bad=0
for row in "${ROWS[@]}"; do
  read -r ns pvc <<<"$row"; n=$((n+1))
  echo "===== [$n/${#ROWS[@]}] $ns $pvc" | tee -a "$LOG"
  "$HERE/swap-rwo.sh" "$ns" "$pvc" ${MODE:+"$MODE"} --backup-dir "$BACKUP_DIR" </dev/null >>"$LOG" 2>&1
  rc=$?
  grep -E '^(REFUSED|summary|nothing to do|  FAIL)' "$LOG" | tail -n 2 | sed 's/^/    /'
  echo "    exit $rc" | tee -a "$LOG"
  if [[ $rc -ne 0 ]]; then
    bad=$((bad+1))
    [[ -n "$MODE" ]] && { echo "STOP: $ns/$pvc exit $rc — see $LOG" | tee -a "$LOG"; exit "$rc"; }
  fi
  [[ -n "$MODE" ]] && sleep 3
done
echo "done: ${#ROWS[@]} disks, $bad non-zero" | tee -a "$LOG"
[[ $bad -eq 0 ]]
