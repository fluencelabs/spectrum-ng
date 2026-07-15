# Egress network — ownership split & per-cluster parameterization

Status: **design approved** (2026-07-15). Implementation: spectrum-ng (GitOps) + cluster-vars; no beam/lightmare code change required for the reuse-subnet-temp path.

## Context

- Custom-VPC egress = per-VPC `VpcEgressGateway`, reconciled by lightmare from `Subnet.egress` (shipped, lightmare PR #660 / NKS lightmare #246). Mechanism empirically confirmed on kabat-stage (NKS fluence #1095/#1157).
- Gate on the cluster: kube-ovn controller flag **`--enable-external-vpc`** (helm value `features.enableExternalVpcs`, default `false`). Without it `OvnEip`/`enableExternal` don't work.
- Two clusters behind "stage": the DO **management** cluster (`talos.stage.cloudless.dev`, runs beam/argo/flux) and the **workload** cluster **`kabat-stage`** = "spectrum" (KubeOVN + lightmare + tenant VPCs, behind `crd-api-open.stage-cloudless`). Egress lives on the workload cluster.

## Who creates what (current, verified)

| Object | Creator | Source of truth |
|---|---|---|
| `Vlan`, `ProviderNetwork`, underlay `Subnet`s (incl. public `subnet-temp`) | **beam-agent** (`apply_config`/`add_subnet`) | **beam DB** (sent via gRPC `ApplyConfigRequest.vlan` etc.) |
| NAD `public`, `Vpc underlay`, storage `Subnet linstor` (`vlan: ${STORAGE_VLAN}`) | **spectrum-ng GitOps** (`fluence-network/`, piraeus overlays) | spectrum-vars |
| lightmare `PublicNetworkConfig.subnets` | lightmare, fed by spectrum | `LTM_CRD_CTRL__PUBLIC_NETWORK__SUBNETS=${PUBLIC_SUBNET_LIST}` |

Note the existing split: the storage `Subnet` in spectrum references `${STORAGE_VLAN}`, but the `Vlan` object is beam-created from beam DB — so `STORAGE_VLAN` must be kept in sync with beam DB by hand (a known double-source; unifying it is out of scope here — see "Deferred").

## Decision: egress follows the existing pattern — **beam creates the network, spectrum passes config**

No new ownership. For egress we do NOT move network creation into GitOps (that would be a beam-role refactor — deferred). Instead:

- **beam** owns the external gateway subnet the same way it owns the public one:
  - **Reuse `subnet-temp`** (public `/29`, vlan 121) as the external gateway subnet if KubeOVN accepts it — then beam creates **nothing new**.
  - Otherwise beam creates a dedicated `external` underlay subnet exactly like the public one (VLAN from beam DB). No beam code change either way — it's data.
- **spectrum-ng** only *passes config / references* (no network objects for egress):
  1. kube-ovn helm value — the controller gate.
  2. lightmare egress config via `crd-operator` env — the external subnet **name** + gateway namespace + replicas + enable toggle.
- **lightmare** reconciles `Subnet.egress → VpcEgressGateway` (already shipped, #660) using the passed external-subnet name.

## Per-cluster variables (set in `spectrum-vars` / `spectrum-manual-vars`, like `PUBLIC_SUBNET_LIST`)

| Var | Meaning | stage | mainnet |
|---|---|---|---|
| `ENABLE_EXTERNAL_VPCS` | kube-ovn `--enable-external-vpc` | `true` | unset → `false` |
| `EGRESS_EXTERNAL_SUBNET` | KubeOVN external subnet name for the gateway EIP | `subnet-temp` (or `external`) | — |
| `EGRESS_GW_NAMESPACE` | privileged-PSA namespace for gateway pods | e.g. `networking` | — |
| `EGRESS_REPLICAS` | gateway replicas | `1` | — |
| `EXTERNAL_NETWORK_ENABLED` | lightmare `ExternalNetworkConfig` toggle (#1023) | `true` | unset |

Same code on every cluster; egress turns on where these vars are set.

## GitOps changes (spectrum-ng)

1. `flux/apps/kube-system/kube-ovn/app/release.yml` — under `values.features`:
   ```yaml
   enableExternalVpcs: ${ENABLE_EXTERNAL_VPCS}
   ```
2. `flux/apps/kube-system/kube-ovn/ks.yml` — add `postBuild.substituteFrom` (`spectrum-vars` + `spectrum-manual-vars`), mirroring `crd-operator/ks.yml`.
3. `flux/apps/fluence/crd-operator/app/.../release.yml` — add env:
   ```yaml
   LTM_CRD_CTRL__EGRESS__EXTERNAL_SUBNET: ${EGRESS_EXTERNAL_SUBNET}
   LTM_CRD_CTRL__EGRESS__GATEWAY_NAMESPACE: ${EGRESS_GW_NAMESPACE}
   LTM_CRD_CTRL__EGRESS__REPLICAS: ${EGRESS_REPLICAS}
   LTM_CRD_CTRL__EXTERNAL_NETWORK__ENABLED: ${EXTERNAL_NETWORK_ENABLED}
   ```
   (matches `EgressConfig{external_subnet, gateway_namespace, replicas}` + `ExternalNetworkConfig`.)
4. Only if a **dedicated** `external` subnet is chosen over reusing `subnet-temp`: either beam creates it (preferred, its domain), or add it to `fluence-network/` overlay with `vlan: ${EGRESS_VLAN}`.

## Open / to confirm

- **Reuse `subnet-temp` vs dedicated `external`**: verify on kabat-stage whether KubeOVN accepts `subnet-temp` (the public NAD subnet) as the external-gateway/OvnEip subnet, or requires a dedicated one. This is the one empirical check before wiring vars.
- Public IP economy: `subnet-temp` is a `/29` (~5 IPs). Hub-and-spoke (1 shared public IP) vs per-VPC EIP is a separate lightmare-reconciler question (NKS fluence #1157 vs shipped per-VPC #660) — not blocked by this parameterization.

## Deferred

- **2b — unify VLAN as a single spectrum source of truth** (beam reads VLAN from spectrum, or network creation moves fully to GitOps). Removes the beam-DB/spectrum-vars double-source, but is a beam ownership refactor. Out of scope; revisit if the double-source causes drift.
