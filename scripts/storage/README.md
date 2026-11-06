# Storage maintenance scripts

Operator scripts for live LINSTOR/KubeVirt disk maintenance on spectrum clusters.
They are not part of any Flux overlay. Why and how they work lives in the graph
`@cloudless/fluence`: unpinning RWX PVs — node #4193, RWO→RWX swap — node #4309,
live migration — node #4321.

| Script | Does |
|---|---|
| `unpin-pv.sh <pv>` | swaps a node-pinned LINSTOR RWX Block PV for an unpinned one under a bound PVC, consumer keeps running |
| `run-batch.sh <list>` | `unpin-pv.sh` for each PV name in a list file |
| `swap-rwo.sh <ns> <pvc>` | turns a crd-operator VM disk (DataVolume-owned RWO PVC + pinned PV) into RWX + unpinned, VM keeps running |
| `run-rwo-batch.sh <list>` | `swap-rwo.sh` for each `namespace pvc` line in a list file |
| `migrate-vmi.sh <ns> <vmi>` | one live migration via `VirtualMachineInstanceMigration`, waits for the result |
| `kubectl-via-beam-agent.sh` | builds `KUBECTL` that runs kubectl inside a Running beam-agent pod |

Every script prints its usage with `--help`.

## Rules

- **Run from bash, not zsh.** `$KUBECTL` is a multi-word command and relies on
  bash word splitting; in zsh `$KUBECTL get nodes` fails.
- **Dry run first, then `--apply`.** Without `--apply` nothing is written: the
  scripts check preconditions and print the planned manifests and diffs.
- **stdin from `/dev/null`** for `swap-rwo.sh` run by hand
  (`swap-rwo.sh ns pvc </dev/null`): a `kubectl exec -i` wrapper eats stdin. The
  batch wrappers already do this.
- **One at a time.** The batch wrappers run sequentially and, with `--apply`,
  stop on the first non-zero exit.
- **Never run `/usr/bin/agent` in the beam-agent pod.** The pod is used only for
  its `kubectl` and `/root/kubeconfig`.
- Backups go to `./storage-backup` (current directory) unless `--backup-dir` is
  given; keep them outside the repo, or rely on the `.gitignore` entry.
  Requires `jq`, `awk`, `diff` locally.

## Env contract

| Variable | Used by | Meaning |
|---|---|---|
| `KUBECTL` | all | kubectl command, may be a wrapper; must pass stdin through |
| `LINSTOR` | unpin-pv, swap-rwo | linstor command; default `$KUBECTL -n storage exec deploy/linstor-controller -- linstor` |
| `INFRA_KUBECONFIG`, `BEAM_NS`, `CTX` | kubectl-via-beam-agent; wrappers and migrate-vmi when `KUBECTL` is unset | infra cluster kubeconfig, beam-agent namespace, target context |
| `BEAM_KUBECONFIG`, `REQUEST_TIMEOUT` | kubectl-via-beam-agent | kubeconfig inside the pod (default `/root/kubeconfig`), inner `--request-timeout` (default `30s`) |

beam-agent namespace and context per cluster:

| Cluster | `BEAM_NS` | `CTX` |
|---|---|---|
| stage | `beam-cloudless` | `kabat-stage` |
| testnet | `beam-cloudless` | `kabat` |
| mainnet | `beam-kabat` | `fra-flix-01` or `poz-bey-c01` |

`INFRA_KUBECONFIG` is the Talos kubeconfig of that environment's infra cluster;
it is never committed here.

## Usage

```bash
# bash
. scripts/storage/kubectl-via-beam-agent.sh /path/to/infra-kubeconfig beam-cloudless kabat
$KUBECTL get nodes

scripts/storage/unpin-pv.sh pvc-0123…                 # dry run: plan + diff
scripts/storage/unpin-pv.sh pvc-0123… --apply --backup-dir ~/storage-backup

scripts/storage/swap-rwo.sh tenant-ns disk-0 </dev/null
scripts/storage/swap-rwo.sh tenant-ns disk-0 --apply --backup-dir ~/storage-backup </dev/null

# batches: dry run the whole list, read the log, then --apply
CTX=kabat scripts/storage/run-batch.sh pvs.txt
CTX=kabat scripts/storage/run-batch.sh pvs.txt --apply --backup-dir ~/storage-backup
scripts/storage/run-rwo-batch.sh disks.txt            # lines: "namespace pvc [# comment]"
scripts/storage/run-rwo-batch.sh disks.txt --apply --backup-dir ~/storage-backup

scripts/storage/migrate-vmi.sh tenant-ns vm-0
```

Logs of the batch wrappers land next to the list file.

## Exit codes

| Script | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| `unpin-pv.sh` | ok / nothing to do | precondition refused, nothing changed | PV deleted but not recreated — recovery block printed | done, a post-check failed |
| `swap-rwo.sh` | ok / nothing to do | precondition refused, nothing changed | failed mid-way — recovery block printed and saved as `recover.sh` in the backup dir | done, a post-check failed |
| `run-batch.sh` | all ok | first failing `unpin-pv.sh` exit code is passed through | | |
| `run-rwo-batch.sh` | all ok | dry run: some disk non-zero; `--apply`: first failing exit code is passed through | | |
| `migrate-vmi.sh` | migration Succeeded | create failed, Failed, or timed out (10 min) | | |
