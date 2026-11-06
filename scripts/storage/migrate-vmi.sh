#!/usr/bin/env bash
# migrate-vmi.sh — live-migrate one VMI via a VirtualMachineInstanceMigration and
# wait for the result (up to 10 min). (граф `@cloudless/fluence`, узел #4321)
#
# Usage: migrate-vmi.sh <namespace> <vmi>
# Env:   KUBECTL, or INFRA_KUBECONFIG + BEAM_NS + CTX for kubectl-via-beam-agent.sh
# Exit:  0 migration Succeeded, 1 otherwise (create failed, Failed, or timed out)
set -uo pipefail
case "${1:-}" in -h|--help) sed -n '2,7p' "$0"; exit 0 ;; esac
NS=${1:?usage: migrate-vmi.sh <namespace> <vmi>} VMI=${2:?usage: migrate-vmi.sh <namespace> <vmi>}
if [[ -z "${KUBECTL:-}" ]]; then
  K=$("$(dirname "$0")/kubectl-via-beam-agent.sh") || exit 1
  eval "$K"
fi
read -ra KC <<<"$KUBECTL"
k() { "${KC[@]}" "$@"; }
M="mig-$(date -u +%H%M%S)"
before=$(k -n "$NS" get vmi "$VMI" -o jsonpath='{.metadata.uid} {.status.nodeName}')
echo "before: uid/node $before"
printf 'apiVersion: kubevirt.io/v1\nkind: VirtualMachineInstanceMigration\nmetadata:\n  name: %s\n  namespace: %s\nspec:\n  vmiName: %s\n' "$M" "$NS" "$VMI" | k create -f - || exit 1
p=""
for _ in $(seq 1 120); do
  p=$(k -n "$NS" get vmim "$M" -o jsonpath='{.status.phase}' 2>/dev/null)
  case $p in Succeeded|Failed) break ;; esac
  sleep 5
done
echo "migration $M phase=$p"
k -n "$NS" get vmi "$VMI" -o jsonpath='after: uid={.metadata.uid} node={.status.nodeName} phase={.status.phase} mode={.status.migrationState.mode} {.status.migrationState.sourceNode}->{.status.migrationState.targetNode} {.status.migrationState.startTimestamp}..{.status.migrationState.endTimestamp} failed={.status.migrationState.failed}{"\n"}'
[[ $p == Succeeded ]]
