#!/usr/bin/env bash
# kubectl-via-beam-agent.sh — build a KUBECTL command that runs kubectl inside a
# Running beam-agent pod of the infra cluster against a spectrum cluster context.
#
# Usage (bash):  . kubectl-via-beam-agent.sh [INFRA_KUBECONFIG [BEAM_NS [CTX]]]   # exports KUBECTL
#                eval "$(kubectl-via-beam-agent.sh [INFRA_KUBECONFIG [BEAM_NS [CTX]]])"
#   (sourced without args inside a script, it sees that script's "$@": execute it there)
# Env (args win): INFRA_KUBECONFIG  kubeconfig of the infra cluster that hosts beam-agent
#                 BEAM_NS           namespace of the beam-agent pod
#                 CTX               context in the pod's kubeconfig (the target cluster)
#                 BEAM_KUBECONFIG   kubeconfig path inside the pod (default /root/kubeconfig)
#                 REQUEST_TIMEOUT   --request-timeout for the inner kubectl (default 30s)
# Pairs:  stage    BEAM_NS=beam-cloudless CTX=kabat-stage
#         testnet  BEAM_NS=beam-cloudless CTX=kabat
#         mainnet  BEAM_NS=beam-kabat     CTX=fra-flix-01 | poz-bey-c01
# The pod is only used to run kubectl; never run /usr/bin/agent in it.

_bka_main() {
  local kc="${1:-${INFRA_KUBECONFIG:-}}" ns="${2:-${BEAM_NS:-}}" ctx="${3:-${CTX:-}}" pod
  [[ -n "$kc" && -n "$ns" && -n "$ctx" ]] || {
    echo "kubectl-via-beam-agent.sh: need INFRA_KUBECONFIG, BEAM_NS and CTX (env or args)" >&2; return 1; }
  [[ -r "$kc" ]] || { echo "kubectl-via-beam-agent.sh: cannot read $kc" >&2; return 1; }
  kc="$(cd "$(dirname "$kc")" && pwd)/$(basename "$kc")"  # KUBECTL must work from any cwd
  [[ "$kc" != *[[:space:]]* ]] || { echo "kubectl-via-beam-agent.sh: kubeconfig path must not contain spaces (KUBECTL is word-split)" >&2; return 1; }
  pod=$(kubectl --kubeconfig "$kc" -n "$ns" get pod --field-selector=status.phase=Running -o name | grep beam-agent | head -1)
  [[ -n "$pod" ]] || { echo "kubectl-via-beam-agent.sh: no Running beam-agent pod in $ns" >&2; return 1; }
  KUBECTL="kubectl --kubeconfig $kc -n $ns exec -i $pod -- kubectl --kubeconfig ${BEAM_KUBECONFIG:-/root/kubeconfig} --context $ctx --request-timeout=${REQUEST_TIMEOUT:-30s}"
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,17p' "${BASH_SOURCE[0]}"
elif [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _bka_main "$@" || exit 1
  printf 'export KUBECTL=%q\n' "$KUBECTL"
else
  _bka_main "$@" && export KUBECTL
fi
