#!/usr/bin/env bash
# swap-rwo.sh — turn a crd-operator disk (DataVolume owns PVC, a running KubeVirt
# VM mounts the PVC) from RWO + node-pinned PV into RWX + unpinned PV, keeping
# the same PVC/DV names and the same LINSTOR volume, while the VM keeps running.
# (граф `@cloudless/fluence`, узел #4309)
#
# Usage: swap-rwo.sh <namespace> <pvc-name> [--apply] [--backup-dir DIR] </dev/null
#   default is a dry run: preconditions, current objects, planned PVC/PV/DV
#   manifests, diffs and client-side validation; nothing is written.
#   --backup-dir  where --apply saves objects, planned manifests and recover.sh
#                 (default ./storage-backup)
#   Feed stdin from /dev/null: a `kubectl exec -i` KUBECTL wrapper eats it.
# Env:   KUBECTL  kubectl command (may be a wrapper; must pass stdin through)
#        LINSTOR  linstor command (default: $KUBECTL -n storage exec deploy/linstor-controller -- linstor)
#        SWAP_FAULT_CREATE=1  test only: corrupt the new PVC manifest at step 4
# Exit:  0 ok / nothing to do, 1 precondition refused (nothing changed),
#        2 failed mid-way (recovery block printed, also saved as recover.sh),
#        3 swap done but a post-check failed
set -euo pipefail

POLICY_KEY=linstor.csi.linbit.com/remote-access-policy
FIN=cloudless.dev/lightmare
NS="" N="" APPLY=0 BACKUP_DIR=./storage-backup
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --backup-dir) BACKUP_DIR="${2:?--backup-dir needs a value}"; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 1 ;;
    *) if [[ -z "$NS" ]]; then NS="$1"; elif [[ -z "$N" ]]; then N="$1"; else echo "unexpected argument: $1" >&2; exit 1; fi ;;
  esac
  shift
done
[[ -n "$NS" && -n "$N" ]] || { echo "usage: $0 <namespace> <pvc-name> [--apply] [--backup-dir DIR]" >&2; exit 1; }
: "${KUBECTL:?set KUBECTL to the kubectl command}"
read -ra KC <<<"$KUBECTL"
read -ra LC <<<"${LINSTOR:-$KUBECTL -n storage exec deploy/linstor-controller -- linstor}"

k() { "${KC[@]}" "$@"; }
kn() { "${KC[@]}" -n "$NS" "$@"; }
lin() { "${LC[@]}" "$@"; }
log() { echo "[$(date -u +%T.%3N)] $*"; }
die() { echo "REFUSED: $*" >&2; exit 1; }
now() { date +%s.%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1fs", b-a}'; }
# wait_for <seconds> <cmd...>: poll every 0.5s until cmd succeeds
wait_for() { local end=$(( $(date +%s) + $1 )); shift; until "$@"; do (( $(date +%s) < end )) || return 1; sleep 0.5; done; }
gone() { ! "$@" >/dev/null 2>&1; }

# ---------- read current state ----------
T_START_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PVC_JSON=$(kn get pvc "$N" -o json 2>/dev/null) || die "PVC $NS/$N not found"
pvc() { jq -r "$@" <<<"$PVC_JSON"; }
PV=$(pvc '.spec.volumeName // ""')
[[ -n "$PV" ]] || die "PVC $NS/$N has no volumeName"
PV_JSON=$(k get pv "$PV" -o json 2>/dev/null) || die "PV $PV not found"
pv() { jq -r "$@" <<<"$PV_JSON"; }

PVC_AM=$(pvc -c '.spec.accessModes')
PV_AFF=$(pv '.spec.nodeAffinity != null')
# shellcheck disable=SC2016  # $k is a jq variable
POLICY=$(pv --arg k "$POLICY_KEY" '.spec.csi.volumeAttributes[$k] // "<unset>"')
if [[ $PVC_AM == '["ReadWriteMany"]' && $(pv -c '.spec.accessModes') == '["ReadWriteMany"]' ]]; then
  [[ $PV_AFF == false && $POLICY == true ]] && { log "nothing to do: $NS/$N is RWX and $PV is unpinned ($POLICY_KEY=true)"; exit 0; }
  die "$NS/$N is already RWX but $PV is pinned (nodeAffinity=$PV_AFF, $POLICY_KEY=$POLICY): use unpin-pv.sh"
fi

# ---------- preconditions (read-only) ----------
[[ $(pvc '.metadata.deletionTimestamp // ""') == "" ]] || die "PVC is Terminating"
[[ $(pvc '.status.phase') == Bound ]] || die "PVC phase is $(pvc '.status.phase'), not Bound"
[[ $PVC_AM == '["ReadWriteOnce"]' ]] || die "PVC accessModes $PVC_AM, expected [\"ReadWriteOnce\"]"
[[ $(pvc '.spec.volumeMode // "Filesystem"') == Block ]] || die "PVC volumeMode is $(pvc '.spec.volumeMode // "Filesystem"'), not Block"
[[ $(pvc '[.metadata.ownerReferences // [] | .[] | select(.kind == "DataVolume" and .name == "'"$N"'" and .controller == true)] | length') == 1 \
   && $(pvc '.metadata.ownerReferences | length') == 1 ]] || die "PVC is not owned by exactly one DataVolume named $N (owners: $(pvc -c '[.metadata.ownerReferences // [] | .[] | "\(.kind)/\(.name)"]'))"
PVC_UID=$(pvc '.metadata.uid') DV_OWNER_UID=$(pvc '.metadata.ownerReferences[0].uid')

DV_JSON=$(kn get dv "$N" -o json 2>/dev/null) || die "DataVolume $NS/$N not found"
dv() { jq -r "$@" <<<"$DV_JSON"; }
DV_UID=$(dv '.metadata.uid')
[[ $DV_UID == "$DV_OWNER_UID" ]] || die "DataVolume uid $DV_UID differs from the PVC owner uid $DV_OWNER_UID"
[[ $(dv '.metadata.deletionTimestamp // ""') == "" ]] || die "DataVolume is Terminating"
[[ $(dv '.status.phase') == Succeeded ]] || die "DataVolume phase is $(dv '.status.phase'), not Succeeded"
[[ $(dv '.metadata.ownerReferences // [] | length') == 0 ]] || die "DataVolume has owners $(dv -c '[.metadata.ownerReferences[] | "\(.kind)/\(.name)"]') (dataVolumeTemplate?)"
# shellcheck disable=SC2016  # $f is a jq variable
[[ $(dv --arg f "$FIN" '.metadata.finalizers // [] | index($f) != null') == true ]] || die "DataVolume lacks finalizer $FIN"
[[ $(dv '.spec.storage != null and .spec.pvc == null') == true ]] || die "DataVolume uses spec.pvc, expected spec.storage"
STORAGE_ID=$(dv '.metadata.annotations["storage.cloudless.dev/id"] // ""')
[[ -n "$STORAGE_ID" ]] || die "DataVolume has no storage.cloudless.dev/id annotation"

[[ $(pv '.spec.csi.driver // ""') == linstor.csi.linbit.com ]] || die "PV driver is '$(pv '.spec.csi.driver // "none"')', not linstor.csi.linbit.com"
[[ $(pv '.metadata.deletionTimestamp // ""') == "" ]] || die "PV is Terminating"
[[ $(pv '.status.phase') == Bound ]] || die "PV phase is $(pv '.status.phase'), not Bound"
[[ $(pv '.spec.claimRef.uid // ""') == "$PVC_UID" && $(pv '.spec.claimRef.name // ""') == "$N" && $(pv '.spec.claimRef.namespace // ""') == "$NS" ]] \
  || die "PV claimRef $(pv -c '.spec.claimRef | {namespace, name, uid}') does not match PVC $NS/$N uid $PVC_UID"
[[ $(pv '.spec.volumeMode // "Filesystem"') == Block ]] || die "PV volumeMode is not Block"
ORIG_RECLAIM=$(pv '.spec.persistentVolumeReclaimPolicy')

HANDLE=$(pv '.spec.csi.volumeHandle')
lin_state() {  # one line per replica: node diskful|diskless diskstate
  lin -m resource list -r "$HANDLE" | jq -r '.[0][] | "\(.node_name) \(if ((.flags // []) | index("DISKLESS")) or ((.flags // []) | index("TIE_BREAKER")) then "diskless" else "diskful" end) \(.volumes[0].state.disk_state // "?")"' | sort
}
lin -m resource-definition list -r "$HANDLE" | jq -e --arg h "$HANDLE" '.[0] | map(select(.name | ascii_downcase == ($h | ascii_downcase))) | length == 1' >/dev/null \
  || die "LINSTOR resource-definition $HANDLE not found"
LIN_BEFORE=$(lin_state)
grep -q ' diskful UpToDate$' <<<"$LIN_BEFORE" || die "no diskful UpToDate replica for $HANDLE: ${LIN_BEFORE//$'\n'/; }"

va_state() { k get volumeattachment -o json | jq -r --arg pv "$PV" '.items[] | select(.spec.source.persistentVolumeName == $pv) | "\(.metadata.name) \(.spec.nodeName) attached=\(.status.attached)"' | sort; }
VA_BEFORE=$(va_state)

VMIS=$(kn get vmi -o json | jq -c --arg c "$N" '[.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $c or .dataVolume.name == $c))]')
[[ $(jq length <<<"$VMIS") == 1 ]] || die "expected exactly one VMI using $N, found $(jq -c 'map(.metadata.name)' <<<"$VMIS")"
VMI_JSON=$(jq '.[0]' <<<"$VMIS")
VMI=$(jq -r '.metadata.name' <<<"$VMI_JSON") VMI_UID=$(jq -r '.metadata.uid' <<<"$VMI_JSON") VMI_NODE=$(jq -r '.status.nodeName // ""' <<<"$VMI_JSON")
[[ $(jq -r '.status.phase' <<<"$VMI_JSON") == Running ]] || die "VMI $VMI phase is $(jq -r '.status.phase' <<<"$VMI_JSON"), not Running"
[[ $(jq -r '.status.migrationState | (. != null and .endTimestamp == null)' <<<"$VMI_JSON") == false ]] || die "VMI $VMI is migrating"
VM=$(jq -r '[.metadata.ownerReferences // [] | .[] | select(.kind == "VirtualMachine") | .name][0] // ""' <<<"$VMI_JSON")
[[ -n "$VM" ]] || die "VMI $VMI has no owning VirtualMachine"
VM_JSON=$(kn get vm "$VM" -o json 2>/dev/null) || die "VirtualMachine $NS/$VM not found"
[[ $(jq '.spec.dataVolumeTemplates // [] | length' <<<"$VM_JSON") == 0 ]] || die "VirtualMachine $VM has dataVolumeTemplates (CDI would own the DV)"
[[ $(jq --arg c "$N" '[.spec.template.spec.volumes[]? | select(.persistentVolumeClaim.claimName == $c)] | length' <<<"$VM_JSON") == 1 ]] \
  || die "VirtualMachine $VM does not reference $N via persistentVolumeClaim"
[[ $(jq --arg c "$N" '[.spec.template.spec.volumes[]? | select(.dataVolume.name == $c)] | length' <<<"$VM_JSON") == 0 ]] \
  || die "VirtualMachine $VM references $N via dataVolume"
INFLIGHT=$(kn get vmim -o json | jq -r --arg v "$VMI" '[.items[] | select(.spec.vmiName == $v and (.status.phase // "") != "Succeeded" and (.status.phase // "") != "Failed") | .metadata.name] | join(" ")')
[[ -z "$INFLIGHT" ]] || die "migration in flight for $VMI: $INFLIGHT"

cdi_pods() {  # importer/populator/upload/clone pods or prime PVCs for this disk (old or new PVC uid)
  { kn get pod -o json | jq -r --arg n "$N" --arg u "$1" '.items[] | .metadata.name | select(test("^(importer|cdi-upload|cdi-clone|.*-source-pod)") and (contains($n) or contains($u))) | "pod/" + .'
    kn get pvc -o json | jq -r --arg u "$1" '.items[] | .metadata.name | select(startswith("prime-" + $u)) | "pvc/" + .'; } | sort
}
CDI_BEFORE=$(cdi_pods "$PVC_UID")
[[ -z "$CDI_BEFORE" ]] || die "CDI populator objects exist for $N: ${CDI_BEFORE//$'\n'/ }"

ST_JSON=$(k get storages.cloudless.dev "$STORAGE_ID" -o json 2>/dev/null) || die "Storage $STORAGE_ID not found"
st() { jq -r "$@" <<<"$ST_JSON"; }
[[ $(st '.metadata.deletionTimestamp // ""') == "" ]] || die "Storage $STORAGE_ID is Terminating"
[[ $(st '[.status.conditions[]? | select(.type == "Ready")][0].status // ""') == True ]] || die "Storage $STORAGE_ID is not Ready: $(st -c '[.status.conditions[]? | "\(.type)=\(.status)/\(.reason)"]')"
[[ -n $(st '.status.reconciliationFinishedAt // ""') ]] || die "Storage $STORAGE_ID has no reconciliationFinishedAt (the operator could re-create the DV mid-swap)"
[[ $(st '.status.subresourceName // ""') == "$N" ]] || die "Storage $STORAGE_ID subresourceName is '$(st '.status.subresourceName // ""')', not $N"

lm() { kn get vmi "$VMI" -o json | jq -r '[.status.conditions[]? | select(.type == "LiveMigratable")][0] | "\(.status // "?")/\(.reason // "")"'; }
other_rwo() {  # other disks of the VMI whose PVC is still RWO
  local c
  for c in $(jq -r --arg c "$N" '.spec.volumes[]? | (.persistentVolumeClaim.claimName // .dataVolume.name // empty) | select(. != $c)' <<<"$VMI_JSON"); do
    [[ $(kn get pvc "$c" -o jsonpath='{.spec.accessModes}' 2>/dev/null) == *ReadWriteOnce* ]] && echo "$c"
  done; return 0
}
OTHER_RWO=$(other_rwo | tr '\n' ' ')

echo "PVC       $NS/$N uid=$PVC_UID $PVC_AM $(pvc '.spec.volumeMode') $(pvc '.spec.storageClassName') $(pvc -c '.spec.resources.requests')"
echo "DV        uid=$DV_UID $(dv '.status.phase') $(dv -c '.spec.storage.accessModes') finalizers=$(dv -c '.metadata.finalizers')"
echo "PV        $PV uid=$(pv '.metadata.uid') reclaim=$ORIG_RECLAIM $(pv -c '.spec.accessModes') nodeAffinity=$(pv -c '.spec.nodeAffinity.required.nodeSelectorTerms // "none"') $POLICY_KEY=$POLICY"
echo "LINSTOR   $HANDLE: ${LIN_BEFORE//$'\n'/; }"
echo "VA        ${VA_BEFORE:-none}"
echo "VMI       $VMI uid=$VMI_UID node=$VMI_NODE LiveMigratable=$(lm) (VM $VM)"
echo "Storage   $STORAGE_ID Ready=True reconciliationFinishedAt=$(st '.status.reconciliationFinishedAt')"
echo "other RWO disks of this VM: ${OTHER_RWO:-none}"

# ---------- planned manifests ----------
PVC_NEW=$(jq --arg pv "$PV" '{apiVersion: "v1", kind: "PersistentVolumeClaim",
  metadata: ({name: .metadata.name, namespace: .metadata.namespace}
    + (if .metadata.labels then {labels: .metadata.labels} else {} end)
    + {annotations: ((.metadata.annotations // {} | with_entries(select(.key | test("^(storage|workspace)\\.cloudless\\.dev/|^cdi\\.kubevirt\\.io/storage\\.(contentType|pod\\.phase|condition\\.running.*|preallocation\\.requested)$"))))
                     + {"cdi.kubevirt.io/storage.populatedFor": .metadata.name})}),
  spec: {accessModes: ["ReadWriteMany"], volumeMode: .spec.volumeMode, storageClassName: .spec.storageClassName, resources: .spec.resources, volumeName: $pv}}' <<<"$PVC_JSON")
pv_new() {  # $1 = claimRef uid
  jq --arg uid "$1" --arg k "$POLICY_KEY" '{apiVersion: "v1", kind: "PersistentVolume",
  metadata: ({name: .metadata.name}
    + (if .metadata.labels then {labels: .metadata.labels} else {} end)
    + {annotations: ((.metadata.annotations // {}) | del(.["kubectl.kubernetes.io/last-applied-configuration"]))}),
  spec: ({accessModes: ["ReadWriteMany"], capacity: .spec.capacity, volumeMode: .spec.volumeMode, persistentVolumeReclaimPolicy: "Retain",
    claimRef: (.spec.claimRef | {apiVersion: "v1", kind: "PersistentVolumeClaim", namespace, name, uid: $uid}),
    csi: (.spec.csi | .volumeAttributes = ((.volumeAttributes // {}) + {($k): "true"}))}
    + (if .spec.storageClassName then {storageClassName: .spec.storageClassName} else {} end))}' <<<"$PV_JSON"
}
PV_NEW=$(pv_new "<new-pvc-uid>")
DV_NEW=$(jq --arg f "$FIN" '{apiVersion: "cdi.kubevirt.io/v1beta1", kind: "DataVolume",
  metadata: ({name: .metadata.name, namespace: .metadata.namespace, finalizers: [$f]}
    + (if .metadata.labels then {labels: .metadata.labels} else {} end)
    + {annotations: (.metadata.annotations // {} | with_entries(select(.key | test("cloudless\\.dev/"))))}),
  spec: (.spec | .storage.accessModes = ["ReadWriteMany"])}' <<<"$DV_JSON")

norm() { jq -S '{metadata: (.metadata | {name, namespace, finalizers, labels, annotations, ownerReferences: (.ownerReferences // null | if . then map({kind, name}) else . end)}), spec: (.spec | del(.claimRef.resourceVersion))} | del(..|nulls)'; }
show() {  # $1 kind, $2 current json, $3 planned json
  echo "--- planned $1 ---"; jq . <<<"$3"
  echo "--- diff $1 (current -> planned) ---"
  diff -u --label current --label planned <(norm <<<"$2") <(norm <<<"$3") || true
  k create --dry-run=client -o name -f - <<<"$3" >/dev/null || die "planned $1 fails client-side validation"
  echo "(client-side validation ok)"
}
show PVC "$PVC_JSON" "$PVC_NEW"
show PV "$PV_JSON" "$PV_NEW"
show DataVolume "$DV_JSON" "$DV_NEW"

if [[ $APPLY -eq 0 ]]; then log "dry run: all preconditions pass, nothing written. Re-run with --apply."; exit 0; fi

# ---------- apply ----------
mkdir -p "$BACKUP_DIR"; BACKUP_DIR=$(cd "$BACKUP_DIR" && pwd)
B="$BACKUP_DIR/$N.$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$B"
printf '%s\n' "$DV_JSON" >"$B/dv.json"; printf '%s\n' "$PVC_JSON" >"$B/pvc.json"; printf '%s\n' "$PV_JSON" >"$B/pv.json"
printf '%s\n' "$VM_JSON" >"$B/vm.json"; printf '%s\n' "$ST_JSON" >"$B/storage.json"
jq . <<<"$PVC_NEW" >"$B/pvc-new.json"; jq . <<<"$PV_NEW" >"$B/pv-new.json"; jq . <<<"$DV_NEW" >"$B/dv-new.json"
log "backup + planned manifests in $B"

STAGE=0
# recovery: finish the swap forward from the step that failed; every command is idempotent
recover() {
  local rc=$? R="$B/recover.sh"
  [[ $STAGE -gt 0 ]] || exit "$rc"
  {
    echo "#!/usr/bin/env bash"
    echo "# recovery for $NS/$N (failed at step $STAGE); run with the same KUBECTL. Volume $HANDLE is safe: PV reclaim Retain."
    echo "set -x; K=(\$KUBECTL)"
    if [[ $STAGE -le 2 ]]; then
      echo "# nothing deleted yet: roll back (DV and PVC untouched apart from these two fields)"
      echo "\"\${K[@]}\" -n $NS get pvc $N -o json | jq -e '.metadata.ownerReferences' >/dev/null || \"\${K[@]}\" -n $NS patch pvc $N --type merge -p '$(jq -c '{metadata: {ownerReferences: .metadata.ownerReferences}}' <<<"$PVC_JSON")'"
      echo "\"\${K[@]}\" patch pv $PV -p '{\"spec\":{\"persistentVolumeReclaimPolicy\":\"$ORIG_RECLAIM\"}}'"
      echo "# then re-run: swap-rwo.sh $NS $N   (dry run must pass all preconditions again)"
    else
    if [[ $STAGE -le 3 ]]; then
      echo "\"\${K[@]}\" -n $NS delete dv $N --cascade=orphan --wait=false --ignore-not-found"
      echo "sleep 3; IDX=\$(\"\${K[@]}\" -n $NS get dv $N -o json 2>/dev/null | jq '.metadata.finalizers // [] | index(\"$FIN\")')"
      echo "[ -n \"\$IDX\" ] && [ \"\$IDX\" != null ] && \"\${K[@]}\" -n $NS patch dv $N --type json -p \"[{\\\"op\\\":\\\"test\\\",\\\"path\\\":\\\"/metadata/finalizers/\$IDX\\\",\\\"value\\\":\\\"$FIN\\\"},{\\\"op\\\":\\\"remove\\\",\\\"path\\\":\\\"/metadata/finalizers/\$IDX\\\"}]\""
      echo "until ! \"\${K[@]}\" -n $NS get dv $N >/dev/null 2>&1; do sleep 1; done"
      echo "\"\${K[@]}\" -n $NS get pvc $N -o jsonpath='{.metadata.uid}' | grep -qx $PVC_UID && { \"\${K[@]}\" -n $NS delete pvc $N --wait=false; \"\${K[@]}\" -n $NS patch pvc $N --type merge -p '{\"metadata\":{\"finalizers\":null}}'; }"
    fi
    if [[ $STAGE -le 4 ]]; then
      echo "until ! \"\${K[@]}\" -n $NS get pvc $N -o jsonpath='{.metadata.uid}' | grep -qx $PVC_UID; do sleep 1; done"
      echo "\"\${K[@]}\" -n $NS get pvc $N >/dev/null 2>&1 || \"\${K[@]}\" create -f - < $B/pvc-new.json"
    fi
    if [[ $STAGE -le 5 ]]; then
      echo "NEWUID=\$(\"\${K[@]}\" -n $NS get pvc $N -o jsonpath='{.metadata.uid}')"
      echo "if [ \"\$(\"\${K[@]}\" get pv $PV -o jsonpath='{.spec.claimRef.uid}' 2>/dev/null)\" != \"\$NEWUID\" ]; then"
      echo "  \"\${K[@]}\" delete pv $PV --wait=false --ignore-not-found; \"\${K[@]}\" patch pv $PV --type merge -p '{\"metadata\":{\"finalizers\":null}}' 2>/dev/null"
      echo "  until ! \"\${K[@]}\" get pv $PV >/dev/null 2>&1; do sleep 1; done"
      echo "  jq --arg uid \"\$NEWUID\" '.spec.claimRef.uid = \$uid' $B/pv-new.json | \"\${K[@]}\" create -f -"
      echo "fi"
      echo "until [ \"\$(\"\${K[@]}\" -n $NS get pvc $N -o jsonpath='{.status.phase}')\" = Bound ]; do sleep 1; done"
    fi
    if [[ $STAGE -le 6 ]]; then
      echo "\"\${K[@]}\" -n $NS get dv $N >/dev/null 2>&1 || \"\${K[@]}\" create -f - < $B/dv-new.json"
      echo "until [ \"\$(\"\${K[@]}\" -n $NS get dv $N -o jsonpath='{.status.phase}')\" = Succeeded ]; do sleep 1; done"
    fi
    echo "\"\${K[@]}\" patch pv $PV -p '{\"spec\":{\"persistentVolumeReclaimPolicy\":\"$ORIG_RECLAIM\"}}'"
    echo "# then re-run: swap-rwo.sh $NS $N   (dry run must say 'nothing to do')"
    fi
  } >"$R"; chmod +x "$R"
  {
    echo; echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!! swap of $NS/$N FAILED at step $STAGE. The LINSTOR volume $HANDLE is intact"
    echo "!!! (PV reclaim Retain) and the running VMI $VMI keeps its attachment."
    echo "!!! Backups: $B/{dv,pvc,pv}.json   planned: $B/{pvc,pv,dv}-new.json"
    echo "!!! Finish the swap forward with these commands (saved as $R):"
    sed 's/^/!!!   /' "$R"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  } >&2
  exit 2
}
trap recover ERR
set -E
fail() { echo "!!! step $STAGE: $*" >&2; false; }

T0=$(now)
STAGE=1; k patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
log "1  PV $PV reclaim Retain (was $ORIG_RECLAIM)"

STAGE=2
kn patch pvc "$N" --type json -p "[{\"op\":\"test\",\"path\":\"/metadata/ownerReferences/0/uid\",\"value\":\"$DV_UID\"},{\"op\":\"remove\",\"path\":\"/metadata/ownerReferences\"}]" >/dev/null
log "2a PVC ownerReferences removed"
STAGE=3   # from here on the DV is going away: recovery = finish forward
kn delete dv "$N" --cascade=orphan --wait=false >/dev/null
log "2b DV delete (orphan) issued"
dv_fins() { kn get dv "$N" -o jsonpath='{.metadata.finalizers}' 2>/dev/null || echo gone; }
orphan_done() { [[ $(dv_fins) != *orphan* ]]; }
wait_for 15 orphan_done || fail "DV still carries the orphan finalizer after 15s"
F=$(dv_fins); log "2c DV finalizers now: $F"
if [[ $F != gone ]]; then
  IDX=$(kn get dv "$N" -o json | jq --arg f "$FIN" '.metadata.finalizers // [] | index($f)')
  if [[ $IDX != null ]]; then
    kn patch dv "$N" --type json -p "[{\"op\":\"test\",\"path\":\"/metadata/finalizers/$IDX\",\"value\":\"$FIN\"},{\"op\":\"remove\",\"path\":\"/metadata/finalizers/$IDX\"}]" >/dev/null
  fi
fi
wait_for 30 gone kn get dv "$N" || fail "DV $N not gone after 30s"
CUR_PVC_UID=$(kn get pvc "$N" -o jsonpath='{.metadata.uid}/{.status.phase}' 2>/dev/null || echo gone)
log "2d DV gone; PVC $CUR_PVC_UID"
[[ $CUR_PVC_UID == "$PVC_UID/Bound" ]] || fail "PVC did not survive the orphan delete ($CUR_PVC_UID)"

kn delete pvc "$N" --wait=false >/dev/null
kn patch pvc "$N" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
old_pvc_gone() { [[ $(kn get pvc "$N" -o jsonpath='{.metadata.uid}' 2>/dev/null) != "$PVC_UID" ]]; }
wait_for 30 old_pvc_gone || fail "old PVC not gone after 30s"
log "3  old PVC gone; PV $(k get pv "$PV" -o jsonpath='{.status.phase}')"

STAGE=4
CREATE_SRC="$B/pvc-new.json"
if [[ "${SWAP_FAULT_CREATE:-}" == 1 ]]; then
  CREATE_SRC="$B/pvc-new.FAULT.json"; jq '.spec.resources.requests.storage = "not-a-quantity"' "$B/pvc-new.json" >"$CREATE_SRC"
  log "FAULT INJECTION: creating the PVC from corrupted $CREATE_SRC"
fi
k create -f - <"$CREATE_SRC" >/dev/null
NEW_PVC_UID=$(kn get pvc "$N" -o jsonpath='{.metadata.uid}')
log "4  new PVC uid=$NEW_PVC_UID (RWX, volumeName=$PV, populatedFor=$N)"

STAGE=5
pv_new "$NEW_PVC_UID" >"$B/pv-new.json"
k delete pv "$PV" --wait=false >/dev/null
# pv-protection and external-attacher hold a bound/attached PV forever; the
# volume is untouched (Retain; attachment lives in VolumeAttachment/DRBD).
k patch pv "$PV" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
wait_for 30 gone k get pv "$PV" || fail "old PV object not gone after 30s"
T_PVDEL=$(now); log "5a old PV object gone"
k create -f - <"$B/pv-new.json" >/dev/null
log "5b new PV created (RWX, no nodeAffinity, $POLICY_KEY=true, Retain) after $(secs "$T_PVDEL" "$(now)")"
pvc_bound() { [[ $(kn get pvc "$N" -o jsonpath='{.status.phase}/{.spec.volumeName}' 2>/dev/null) == "Bound/$PV" ]]; }
wait_for 90 pvc_bound || fail "PVC not Bound to $PV after 90s"
log "5c PVC Bound"

STAGE=6
k create -f - <"$B/dv-new.json" >/dev/null
NEW_DV_UID=$(kn get dv "$N" -o jsonpath='{.metadata.uid}')
log "6a new DV created uid=$NEW_DV_UID"
CDI_SEEN=""
dv_ok() { local c; c=$(cdi_pods "$NEW_PVC_UID"); [[ -z "$c" ]] || CDI_SEEN+="$c "; [[ $(kn get dv "$N" -o jsonpath='{.status.phase}') == Succeeded ]]; }
wait_for 90 dv_ok || fail "DV not Succeeded after 90s (phase $(kn get dv "$N" -o jsonpath='{.status.phase}'))"
log "6b DV Succeeded"

STAGE=7
k patch pv "$PV" -p "{\"spec\":{\"persistentVolumeReclaimPolicy\":\"$ORIG_RECLAIM\"}}" >/dev/null
log "7  PV reclaim $ORIG_RECLAIM restored; swap took $(secs "$T0" "$(now)")"
trap - ERR; set +E

# ---------- post-checks ----------
fail=0
check() { local d=$1; shift; if "$@"; then echo "  ok   $d"; else echo "  FAIL $d"; fail=1; fi; }
eq() { [[ "$1" == "$2" ]]; }
owned() { [[ $(kn get pvc "$N" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].uid}') == "DataVolume/$NEW_DV_UID" ]]; }
wait_for 30 owned || true
NPVC=$(kn get pvc "$N" -o json); NPV=$(k get pv "$PV" -o json); NDV=$(kn get dv "$N" -o json); NVMI=$(kn get vmi "$VMI" -o json)
echo "post-checks:"
check "PVC Bound RWX to $PV" eq "$(jq -r '"\(.status.phase) \(.spec.accessModes|join(",")) \(.spec.volumeName)"' <<<"$NPVC")" "Bound ReadWriteMany $PV"
check "PV no nodeAffinity" eq "$(jq '.spec.nodeAffinity == null' <<<"$NPV")" true
check "PV $POLICY_KEY=true" eq "$(jq -r --arg k "$POLICY_KEY" '.spec.csi.volumeAttributes[$k]' <<<"$NPV")" true
check "PV reclaimPolicy $ORIG_RECLAIM" eq "$(jq -r '.spec.persistentVolumeReclaimPolicy' <<<"$NPV")" "$ORIG_RECLAIM"
check "PV claimRef uid = new PVC uid" eq "$(jq -r '.spec.claimRef.uid' <<<"$NPV")" "$NEW_PVC_UID"
check "DV Succeeded" eq "$(jq -r '.status.phase' <<<"$NDV")" Succeeded
check "DV owns PVC" owned
CDI_AFTER=$(cdi_pods "$NEW_PVC_UID")
check "no importer/populator appeared" eq "$CDI_SEEN$CDI_AFTER" ""
LIN_AFTER=$(lin_state)
check "LINSTOR replicas unchanged (${LIN_BEFORE//$'\n'/; })" eq "$LIN_AFTER" "$LIN_BEFORE"
VA_AFTER=$(va_state)
check "VolumeAttachment unchanged (${VA_BEFORE:-none})" eq "$VA_AFTER" "$VA_BEFORE"
check "VMI uid unchanged ($VMI_UID)" eq "$(jq -r '.metadata.uid' <<<"$NVMI")" "$VMI_UID"
check "VMI Running on $VMI_NODE" eq "$(jq -r '"\(.status.phase) \(.status.nodeName)"' <<<"$NVMI")" "Running $VMI_NODE"
WARN=$(kn get events -o json | jq -r --arg v "$VMI" --arg t "$T_START_ISO" '.items[] | select(.type == "Warning" and .involvedObject.name == $v and .involvedObject.kind == "VirtualMachineInstance" and ((.lastTimestamp // .eventTime // .metadata.creationTimestamp) >= $t)) | "       " + .reason + ": " + .message')
check "no new Warning events on VMI" eq "$WARN" ""
st_ready() { [[ $(k get storages.cloudless.dev "$STORAGE_ID" -o json | jq -r '[.status.conditions[]? | select(.type == "Ready")][0].status') == True ]]; }
wait_for 120 st_ready || true
check "Storage $STORAGE_ID Ready=True" st_ready
OTHER_RWO=$(other_rwo | tr '\n' ' ')
if [[ -z "$OTHER_RWO" ]]; then
  lm_true() { [[ $(lm) == True/* ]]; }
  wait_for 60 lm_true || true
  check "VMI LiveMigratable=True (all disks RWX)" lm_true
else
  echo "  info LiveMigratable=$(lm): VM $VM still has RWO disks: $OTHER_RWO"
fi
[[ -z "$WARN" ]] || echo "$WARN"
[[ "$LIN_AFTER" == "$LIN_BEFORE" ]] || echo -e "       LINSTOR before: ${LIN_BEFORE//$'\n'/; }\n       LINSTOR after:  ${LIN_AFTER//$'\n'/; }"
[[ "$VA_AFTER" == "$VA_BEFORE" ]] || echo -e "       VA before: $VA_BEFORE\n       VA after:  $VA_AFTER"
[[ -z "$CDI_SEEN$CDI_AFTER" ]] || echo "       CDI objects: $CDI_SEEN$CDI_AFTER"

echo "summary: $NS/$N RWO->RWX, $PV unpinned; pvc $PVC_UID->$NEW_PVC_UID dv $DV_UID->$NEW_DV_UID; VMI $VMI $VMI_UID on $VMI_NODE LiveMigratable=$(lm); other RWO disks: ${OTHER_RWO:-none}; backup $B"
[[ $fail -eq 0 ]] || { echo "POST-CHECK FAILED (backup: $B)" >&2; exit 3; }
