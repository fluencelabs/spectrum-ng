#!/usr/bin/env bash
# unpin-pv.sh — replace a node-pinned LINSTOR RWX Block PV with an unpinned one
# (same name, same volumeHandle, remote-access-policy "true", no nodeAffinity)
# while the PVC stays bound and the consumer keeps running.
# (граф `@cloudless/fluence`, узел #4193)
#
# Usage: unpin-pv.sh <pv-name> [--apply] [--backup-dir DIR]
#   default is a dry run: preconditions + planned manifest + diff, no writes anywhere.
#   --backup-dir  where --apply saves the original/new PV (default ./storage-backup)
# Env:   KUBECTL  kubectl command (may be a wrapper; must pass stdin through)
#        LINSTOR  linstor command (default: $KUBECTL -n storage exec deploy/linstor-controller -- linstor)
#        UNPIN_FAULT_CREATE=1  test only: corrupt the manifest at the real create step
# Exit:  0 ok / nothing to do, 1 precondition refused, 2 PV deleted but not recreated, 3 post-check failed
set -euo pipefail

POLICY_KEY=linstor.csi.linbit.com/remote-access-policy
PV="" APPLY=0 BACKUP_DIR=./storage-backup
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --backup-dir) BACKUP_DIR="${2:?--backup-dir needs a value}"; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 1 ;;
    *) [[ -z "$PV" ]] || { echo "only one PV per run" >&2; exit 1; }; PV="$1" ;;
  esac
  shift
done
[[ -n "$PV" ]] || { echo "usage: $0 <pv-name> [--apply] [--backup-dir DIR]" >&2; exit 1; }
: "${KUBECTL:?set KUBECTL to the kubectl command}"
read -ra KC <<<"$KUBECTL"
read -ra LC <<<"${LINSTOR:-$KUBECTL -n storage exec deploy/linstor-controller -- linstor}"

k() { "${KC[@]}" "$@"; }
lin() { "${LC[@]}" "$@"; }
log() { echo "[$(date -u +%T)] $*"; }
die() { echo "REFUSED: $*" >&2; exit 1; }
now() { date +%s.%N; }
secs() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1fs", b-a}'; }

# ---------- preconditions (read-only) ----------
T_START_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PV_JSON=$(k get pv "$PV" -o json 2>/dev/null) || die "PV $PV not found"
pv() { jq -r "$@" <<<"$PV_JSON"; }

[[ $(pv '.spec.csi.driver // ""') == linstor.csi.linbit.com ]] || die "driver is '$(pv '.spec.csi.driver // "none"')', not linstor.csi.linbit.com"
[[ $(pv '.spec.volumeMode // "Filesystem"') == Block ]] || die "volumeMode is $(pv '.spec.volumeMode // "Filesystem"'), not Block"
[[ $(pv '.spec.accessModes | index("ReadWriteMany") != null') == true ]] || die "accessModes $(pv -c '.spec.accessModes') lack ReadWriteMany"
[[ $(pv '.metadata.deletionTimestamp // ""') == "" ]] || die "PV is already Terminating"
[[ $(pv '.status.phase') == Bound ]] || die "PV phase is $(pv '.status.phase'), not Bound"
NS=$(pv '.spec.claimRef.namespace // ""') CLAIM=$(pv '.spec.claimRef.name // ""') CLAIM_UID=$(pv '.spec.claimRef.uid // ""')
[[ -n "$NS" && -n "$CLAIM" && -n "$CLAIM_UID" ]] || die "claimRef incomplete (ns='$NS' name='$CLAIM' uid='$CLAIM_UID')"
PVC_JSON=$(k -n "$NS" get pvc "$CLAIM" -o json 2>/dev/null) || die "PVC $NS/$CLAIM not found"
[[ $(jq -r '.status.phase' <<<"$PVC_JSON") == Bound ]] || die "PVC $NS/$CLAIM is not Bound"
[[ $(jq -r '.spec.volumeName' <<<"$PVC_JSON") == "$PV" ]] || die "PVC $NS/$CLAIM is bound to $(jq -r '.spec.volumeName' <<<"$PVC_JSON"), not $PV"
[[ $(jq -r '.metadata.uid' <<<"$PVC_JSON") == "$CLAIM_UID" ]] || die "PVC uid differs from PV claimRef uid"

HAS_AFF=$(pv '.spec.nodeAffinity != null')
# shellcheck disable=SC2016  # $k is a jq variable
POLICY=$(pv --arg k "$POLICY_KEY" '.spec.csi.volumeAttributes[$k] // "<unset>"')
if [[ $HAS_AFF == false && $POLICY == true ]]; then
  log "nothing to do: $PV has no nodeAffinity and $POLICY_KEY=true"; exit 0
fi

HANDLE=$(pv '.spec.csi.volumeHandle')
lin_state() {  # one line per replica: node diskful|diskless diskstate
  lin -m resource list -r "$HANDLE" | jq -r '.[0][] | "\(.node_name) \(if ((.flags // []) | index("DISKLESS")) then "diskless" else "diskful" end) \(.volumes[0].state.disk_state // "?")"' | sort
}
lin -m resource-definition list -r "$HANDLE" | jq -e --arg h "$HANDLE" '.[0] | map(select(.name | ascii_downcase == ($h | ascii_downcase))) | length == 1' >/dev/null \
  || die "LINSTOR resource-definition $HANDLE not found"
LIN_BEFORE=$(lin_state)
grep -q ' diskful UpToDate$' <<<"$LIN_BEFORE" || die "no diskful UpToDate replica for $HANDLE: $LIN_BEFORE"

va_state() { k get volumeattachment -o json | jq -r --arg pv "$PV" '.items[] | select(.spec.source.persistentVolumeName == $pv) | "\(.metadata.name) \(.spec.nodeName) attached=\(.status.attached)"' | sort; }
VA_BEFORE=$(va_state)
VMI=$(k -n "$NS" get vmi -o json | jq -r --arg c "$CLAIM" '[.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $c or .dataVolume.name == $c)) | .metadata.name] | join(" ")')
PODS=$(k -n "$NS" get pod -o json | jq -r --arg c "$CLAIM" '[.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $c)) | "\(.metadata.name)@\(.spec.nodeName // "-")"] | join(" ")')

echo "PV        $PV  (claim $NS/$CLAIM, reclaim $(pv '.spec.persistentVolumeReclaimPolicy'))"
echo "pinning   nodeAffinity=$(pv -c '.spec.nodeAffinity.required.nodeSelectorTerms // "none"')  $POLICY_KEY=$POLICY"
echo "LINSTOR   ${LIN_BEFORE//$'\n'/; }"
echo "VA        ${VA_BEFORE:-none}"
echo "consumers vmi=[${VMI:-none}] pods=[${PODS:-none}]"

# ---------- planned manifest ----------
NEW_JSON=$(jq --arg k "$POLICY_KEY" '{
  apiVersion: "v1", kind: "PersistentVolume",
  metadata: ({name: .metadata.name}
    + (if .metadata.labels then {labels: .metadata.labels} else {} end)
    + {annotations: ((.metadata.annotations // {}) | del(.["kubectl.kubernetes.io/last-applied-configuration"]))}),
  spec: ({
    accessModes: ["ReadWriteMany"],
    capacity: .spec.capacity,
    volumeMode: .spec.volumeMode,
    persistentVolumeReclaimPolicy: "Retain",
    claimRef: (.spec.claimRef | {apiVersion: (.apiVersion // "v1"), kind: (.kind // "PersistentVolumeClaim"), namespace, name, uid}),
    csi: (.spec.csi | .volumeAttributes = ((.volumeAttributes // {}) + {($k): "true"}))
  } + (if .spec.storageClassName then {storageClassName: .spec.storageClassName} else {} end))
}' <<<"$PV_JSON")

echo "--- planned PV manifest ---"; jq . <<<"$NEW_JSON"
echo "--- diff (current -> planned) ---"
diff -u --label current --label planned \
  <(jq -S '{metadata: {name: .metadata.name, labels: .metadata.labels, annotations: .metadata.annotations}, spec: (.spec | del(.claimRef.resourceVersion))} | del(..|nulls)' <<<"$PV_JSON") \
  <(jq -S '{metadata, spec}' <<<"$NEW_JSON") || true

if [[ $APPLY -eq 0 ]]; then log "dry run: nothing written. Re-run with --apply."; exit 0; fi

# ---------- apply ----------
mkdir -p "$BACKUP_DIR"; BACKUP_DIR=$(cd "$BACKUP_DIR" && pwd)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
ORIG_FILE="$BACKUP_DIR/$PV.orig.$STAMP.yaml" NEW_FILE="$BACKUP_DIR/$PV.new.$STAMP.json"
k get pv "$PV" -o yaml >"$ORIG_FILE"
jq . <<<"$NEW_JSON" >"$NEW_FILE"
log "saved $ORIG_FILE and $NEW_FILE"
k create --dry-run=client -f - <"$NEW_FILE" >/dev/null || die "new manifest fails client-side validation"
ORIG_RECLAIM=$(pv '.spec.persistentVolumeReclaimPolicy')

k patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' >/dev/null
log "reclaimPolicy Retain (was $ORIG_RECLAIM)"
T_DEL=$(now)
k delete pv "$PV" --wait=false >/dev/null
# pv-protection and external-attacher hold a bound, attached PV forever; the
# volume itself is untouched (Retain, attachment lives in VolumeAttachment/DRBD).
k patch pv "$PV" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do k get pv "$PV" >/dev/null 2>&1 || break; sleep 0.5; done
k get pv "$PV" >/dev/null 2>&1 && { echo "!!! PV $PV still Terminating after 10s (reclaim Retain, volume safe). Check its finalizers; once gone run: \$KUBECTL create -f - < $NEW_FILE" >&2; exit 2; }
log "old PV object gone after $(secs "$T_DEL" "$(now)")"

CREATE_SRC="$NEW_FILE"
if [[ "${UNPIN_FAULT_CREATE:-}" == 1 ]]; then
  CREATE_SRC=$(mktemp); jq '.spec.capacity.storage = "not-a-quantity"' "$NEW_FILE" >"$CREATE_SRC"
  log "FAULT INJECTION: creating from corrupted $CREATE_SRC"
fi
created=0
for attempt in 1 2 3; do
  if k create -f - <"$CREATE_SRC"; then created=1; break; fi
  log "create attempt $attempt failed"; sleep 1
done
[[ "$CREATE_SRC" == "$NEW_FILE" ]] || rm -f "$CREATE_SRC"
if [[ $created -ne 1 ]]; then
  cat >&2 <<EOF

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!! PV $PV WAS DELETED AND COULD NOT BE RECREATED.
!!! The LINSTOR volume $HANDLE is intact (reclaim Retain); the running
!!! consumer keeps its attachment. PVC $NS/$CLAIM shows Lost until recreated.
!!! Recreate NOW:
!!!   \$KUBECTL create -f - < $NEW_FILE
!!! Then check:  \$KUBECTL -n $NS get pvc $CLAIM   (Bound, VOLUME $PV)
!!! Then restore: \$KUBECTL patch pv $PV -p '{"spec":{"persistentVolumeReclaimPolicy":"$ORIG_RECLAIM"}}'
!!! Original object: $ORIG_FILE
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
  exit 2
fi
T_CREATED=$(now)
log "new PV created; delete->create $(secs "$T_DEL" "$T_CREATED")"

bound=0
for _ in $(seq 1 45); do
  st=$(k -n "$NS" get pvc "$CLAIM" -o jsonpath='{.status.phase}/{.spec.volumeName}' 2>/dev/null || true)
  pst=$(k get pv "$PV" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ $st == "Bound/$PV" && $pst == Bound ]] && { bound=1; break; }
  sleep 2
done
T_BOUND=$(now)
[[ $bound -eq 1 ]] || { echo "!!! PVC $NS/$CLAIM not Bound to $PV within 90s (pvc=$st pv=$pst). Reclaim is Retain; investigate." >&2; exit 3; }
log "PVC Bound again after $(secs "$T_DEL" "$T_BOUND") from delete"
if [[ $ORIG_RECLAIM != Retain ]]; then
  k patch pv "$PV" -p "{\"spec\":{\"persistentVolumeReclaimPolicy\":\"$ORIG_RECLAIM\"}}" >/dev/null
  log "reclaimPolicy restored to $ORIG_RECLAIM"
fi

# ---------- post-checks ----------
fail=0
check() { local d=$1; shift; if "$@"; then echo "  ok   $d"; else echo "  FAIL $d"; fail=1; fi; }
NEW_PV=$(k get pv "$PV" -o json)
echo "post-checks:"
check "no nodeAffinity" test "$(jq '.spec.nodeAffinity == null' <<<"$NEW_PV")" = true
check "$POLICY_KEY=true" test "$(jq -r --arg k "$POLICY_KEY" '.spec.csi.volumeAttributes[$k]' <<<"$NEW_PV")" = true
check "reclaimPolicy $ORIG_RECLAIM" test "$(jq -r '.spec.persistentVolumeReclaimPolicy' <<<"$NEW_PV")" = "$ORIG_RECLAIM"
VA_AFTER=$(va_state)
check "VolumeAttachments unchanged (${VA_BEFORE:-none})" test "$VA_AFTER" = "$VA_BEFORE"
LIN_AFTER=$(lin_state)
check "LINSTOR replicas unchanged" test "$LIN_AFTER" = "$LIN_BEFORE"
for v in $VMI; do
  check "VMI $v Running" test "$(k -n "$NS" get vmi "$v" -o jsonpath='{.status.phase}')" = Running
  WARN=$(k -n "$NS" get events -o json | jq -r --arg v "$v" --arg t "$T_START_ISO" '.items[] | select(.type == "Warning" and .involvedObject.name == $v and .involvedObject.kind == "VirtualMachineInstance" and ((.lastTimestamp // .eventTime // .metadata.creationTimestamp) >= $t)) | "       " + .message')
  check "no new Warning events on VMI $v" test -z "$WARN"
  [[ -z "$WARN" ]] || echo "$WARN"
done
[[ "$VA_AFTER" == "$VA_BEFORE" ]] || echo -e "       VA before: $VA_BEFORE\n       VA after:  $VA_AFTER"
[[ "$LIN_AFTER" == "$LIN_BEFORE" ]] || echo -e "       LINSTOR before: $LIN_BEFORE\n       LINSTOR after:  $LIN_AFTER"

echo "summary: $PV unpinned; delete->create $(secs "$T_DEL" "$T_CREATED"), delete->Bound $(secs "$T_DEL" "$T_BOUND"), total $(secs "$T_DEL" "$(now)")"
[[ $fail -eq 0 ]] || { echo "POST-CHECK FAILED (backup: $ORIG_FILE)" >&2; exit 3; }
