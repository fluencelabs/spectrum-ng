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
| Node label `ovn.kubernetes.io/external-gw=true` | applied to the cluster |
| kube-ovn controller gate, lightmare egress config | **spectrum-ng** (this repo), from the vars below |
| Per-VPC `OvnEip` on the fabric, per-subnet `OvnSnatRule`, the tenant's `extraExternalSubnets` + default route | **lightmare controller**, reconciled from `Subnet.egress` — never by hand |

## Per-cluster variables (`spectrum-manual-vars`)

| Var | Meaning | kabat-stage |
|---|---|---|
| `ENABLE_EXTERNAL_VPCS` | kube-ovn `--enable-external-vpc`; without it `OvnEip` / `enableExternal` do nothing | `true` |
| `EXTERNAL_NETWORK_ENABLED` | lightmare `ExternalNetworkConfig` | `true` |
| `EGRESS_ENABLED` | lightmare `EgressConfig` feature gate | `true` |
| `EGRESS_FABRIC_SUBNET` | name of the shared fabric subnet | `egress-fabric` |
| `EGRESS_HUB_NEXT_HOP` | the hub's fabric-side LRP address | `100.65.0.2` |

Five variables, and only five: `EgressConfig` has exactly two fields,
`fabric_subnet` and `hub_next_hop`, plus the gate. `EGRESS_EXTERNAL_SUBNET`,
`EGRESS_GW_NAMESPACE` and `EGRESS_REPLICAS` belonged to the deprecated per-VPC
gateway form and are gone.

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
