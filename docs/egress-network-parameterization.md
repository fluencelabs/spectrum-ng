# Egress — ownership split & per-cluster parameterization

Status: **in production on kabat-stage**. Implementation: spectrum-ng (GitOps) +
per-cluster vars; the hub objects themselves are applied to the cluster.

Two clusters hide behind "stage": the DO **management** cluster
(`talos.stage.cloudless.dev`, running beam/argo/flux) and the **workload**
cluster `kabat-stage` — "spectrum", with kube-ovn, lightmare and the tenant VPCs.
Egress lives on the workload cluster.

## The shape: OVN-native hub-and-spoke

One public IP for the entire cluster. A tenant VPC attaches to a shared egress
fabric, gets its own **private** EIP there, and SNATs out of it; the hub then
second-SNATs the whole fabric out the cluster's single public EIP. SNAT happens
in the OVN router — there is no gateway pod, so no SPOF and no manual return
route. Cost in public addresses: **two fixed** (the hub's external LRP and the
public EIP), **zero per tenant**.

Tenants are isolated structurally: their logical routers hold no routes to one
another and each per-VPC EIP is SNAT-only, so tenant CIDRs may overlap freely.

> The earlier per-VPC `VpcEgressGateway` form (lightmare PR #660) and the
> `vpcPeerings` + `/30` transit-pool form are both **deprecated**. Peering was
> dropped because it could not carry overlapping tenant CIDRs — see the module
> doc at `crd-controller/src/controller/vpc/egress/mod.rs`. Attachment is by
> `Vpc.spec.extraExternalSubnets`, not by peering.

## Who creates what

| Object | Creator |
|---|---|
| `Vlan`, `ProviderNetwork`, underlay `Subnet`s (incl. the public one) | **beam-agent**, from the beam DB |
| Hub `Vpc`, `egress-fabric` `Subnet`, the public `OvnEip`, the hub `OvnSnatRule` | **applied to the cluster** (beam-owned in the long run) |
| Node label `ovn.kubernetes.io/external-gw=true` | **beam**, via Talos machine config (`nodeLabels`) — see the note below |
| kube-ovn controller gate, lightmare egress config | **spectrum-ng** (this repo), from the vars below |
| Per-VPC `OvnEip` on the fabric, per-subnet `OvnSnatRule`, the tenant's `extraExternalSubnets` + default route | **lightmare controller**, reconciled from `Subnet.egress` — never by hand |

## Per-cluster variables (`spectrum-manual-vars`)

| Var | Meaning | kabat-stage |
|---|---|---|
| `ENABLE_EXTERNAL_VPCS` | kube-ovn `--enable-external-vpc`; without it `OvnEip` / `enableExternal` do nothing | `true` |
| `EGRESS_ENABLED` | lightmare `EgressConfig` feature gate | `true` |
| `EGRESS_FABRIC_SUBNET` | name of the shared fabric subnet | `egress-fabric` |
| `EGRESS_HUB_NEXT_HOP` | the hub's fabric-side LRP address | `100.65.0.2` |
| `EGRESS_CLUSTER_DEFAULT_EXTERNAL_NETWORK` | whether the cluster defines a default external network (`ovn-external-gw-config`) | `false` |

Five variables, and only five: `EgressConfig` has exactly three fields,
`fabric_subnet`, `hub_next_hop` and `cluster_default_external_network`, plus
the gate. `EXTERNAL_NETWORK_ENABLED` went away with crd-controller 0.9.0 —
the egress reconcile is now the single owner of the tenant VPC's
`enableExternal` (lightmare #689). `EGRESS_EXTERNAL_SUBNET`,
`EGRESS_GW_NAMESPACE` and `EGRESS_REPLICAS` belonged to the deprecated per-VPC
gateway form and are gone.

**`EGRESS_CLUSTER_DEFAULT_EXTERNAL_NETWORK` must be right before egress is
first enabled.** The controller stamps its answer per VPC into the annotation
`egress.cloudless.dev/owns-external` on the first egress pass and never
re-consults the setting afterwards; a wrong `false` makes the next teardown
disconnect the cluster default gateway. Recovery is manual, per VPC:
`kubectl annotate vpcs.kubeovn.io <name> egress.cloudless.dev/owns-external-`.
None of our clusters has `ovn-external-gw-config` today, so `false` is correct
everywhere.

`--enable-eip-snat=true` is also required; it is already the default on our
clusters.

**`EGRESS_FABRIC_SUBNET` is effectively immutable once tenants are wired.**
Repointing it strands them on the old fabric: the previous name reads as foreign
to `attach_fabric` and is left in place, while the persisted
`status.egress_fabric_subnet` marker is overwritten, so nothing ever detaches the
old attachment. Rewire only with no egress subnets in play.

## Cluster-side prerequisites

- An external subnet on the underlay VLAN with a real routable block. On stage
  the public `/29` (`subnet-temp`, vlan 121) is reused rather than a dedicated one.
- `ovn.kubernetes.io/external-gw=true` on the nodes with an external uplink.
  The label marks nodes *eligible* as the external LRP's gateway chassis: OVN
  keeps **one** active, the rest are standby with BFD failover — it is not
  "every node NATs for itself". Labelling a single node is legal and is what
  stage does, at the cost of no failover.

  > It must be set through **Talos machine config (`nodeLabels`), patched onto the
  > node by beam** — not with `kubectl label`. Talos is the owner of node identity
  > here, and a hand-set label is unowned: nothing restores it, nothing notices its
  > absence, and a node that is reprovisioned or re-registered comes back without
  > it. That is not hypothetical — on 2026-08-19 stage's only node was found
  > carrying `ovn.kubernetes.io/external-gw: "false"` with no managedFields owner,
  > which silently denied egress to every VPC created after the flip while leaving
  > the already-attached ones working. Since spectrum-ng is Flux-only and does not
  > own Talos, this is a beam-side change; this repo can only detect the failure,
  > which `VpcEgressFabricAttachFailing` now does.
- Two free addresses in the public block. Budget them before enabling: a `/29`
  that already serves ingress and tenant public IPs can be left with nothing.

## Verifying — check the OVN topology, not CR status

CR status reports the controller's *intent*. Every object can read `READY` while
not a single packet leaves. Before trusting any connectivity run:

```
kubectl -n kube-system exec <ovn-central-pod> -c ovn-central -- ovn-nbctl show <hub-vpc>
```

The hub router must have all three:

1. a port on the fabric holding the gateway address (e.g. `100.65.0.2/24`),
2. a port on the external subnet with an address from its CIDR **and a bound
   `gateway chassis`**,
3. `nat snat: <public EIP> <- <fabric CIDR>`.

The classic trap is a half-built link: the switch port references a router port
that does not exist. Check with `ovn-nbctl lsp-get-options <ext-subnet>-<vpc>`
— the `router-port=<name>` it returns must appear in `ovn-nbctl show <vpc>`.
If it does not, the router has no interface on the external network, the default
route points at an unreachable next hop, and there is nothing for SNAT to apply
to — while everything still looks `READY` from the outside. The cure is to
toggle `Vpc.spec.extraExternalSubnets` (remove, re-add) so kube-ovn rebuilds the
router port together with its gateway chassis. Physical and VLAN config need no
changes.

`ovn-nbctl lr-route-list <hub>` catches the same trap independently: the default
route's next hop must lie in a CIDR where the router actually has an interface.

## Broadcast ARP for SNAT EIPs — `bcast_arp_nd_req_flood`

kube-ovn 1.16.8 (OVN 25.03.4) carries a vendor northd patch
(`northd-bcast-arp-nd-req-flood-default-false.patch`, kube-ovn PR #7516) that
adds a priority-90 flow to `ls_in_l2_lkup`:
`(eth.bcast && arp.op == 1) || nd_ns_mcast -> next`. Broadcast ARP requests then
go to `_MC_unknown`, which on an underlay switch is the localnet port only, and
the upstream priority-80 flows that hand ARP for router NAT addresses to the
router port never match. The upstream gateway's `who-has <hub public EIP>` goes
unanswered; egress keeps working until the gateway's ARP entry for the EIP
expires, then every tenant loses egress at once.

The patch has an off switch, `NB_Global options:bcast_arp_nd_req_flood=true`
(named `bcast_arp_req_flood` up to 1.16.7). The chart has no value for NB_Global
options, so the `ovn-nb-bcast-arp-flood` CronJob in the kube-ovn app sets both
names to `true` every five minutes, and writes only when a value differs. It
reaches the leader through the `ovn-nb` Service over plain TCP, which holds as
long as `networking.enableSsl` stays off.

Rolling kube-ovn back does not help: the 1.16.7 patch installs the same flow
under the older option name.

Verify on the NB and SB leaders (`-l ovn-nb-leader=true`, `-l ovn-sb-leader=true`):

```
kubectl -n kube-system exec <ovn-central-pod> -c ovn-central -- ovn-nbctl get NB_Global . options:bcast_arp_nd_req_flood
kubectl -n kube-system exec <ovn-central-pod> -c ovn-central -- ovn-sbctl lflow-list <public-underlay-switch> | grep 'ls_in_l2_lkup.*priority=90.*arp.op == 1'
```

The first prints `"true"`. The second prints nothing: a priority-90 broadcast
ARP `next` flow on the public underlay switch means the option is not in effect.

A green Job only proves that the option names it knows are set. The name has
already changed once, between 1.16.7 and 1.16.8. On every kube-ovn bump, check
`dist/images/patches/` in the new tag for the option the northd patch reads and
run the `lflow-list` check above; if the name moved, update the CronJob.

The trade-off: the vendor default exists to keep broadcast ARP/ND from being
flooded to every port of large underlay switches, where the flood can exceed
OVS's 4096-resubmit limit. Our underlay switches hold a localnet port, router
ports and a handful of LSPs, far below that limit.

Upstream issue: kubeovn/kube-ovn#7545. Once a release installs the skip-flood
flow below the router-owned-IP flows, the CronJob can go. The kube-ovn Flux
Kustomization runs with `prune: false`, so deleting the file does not remove the
CronJob; delete it from each cluster by hand.
