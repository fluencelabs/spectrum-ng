# Adding a new cluster

How to bring up a new spectrum-ng cluster end-to-end: the Flux bootstrap, the
out-of-band config (ConfigMaps + Secrets that are **not** in git), and the per-network
git overlays.

> spectrum-ng is **Flux-only**. The cluster, Talos config and apiserver are provisioned
> by **beam**, not by this repo. This repo only carries the GitOps workload manifests.
>
> A spectrum cluster is created by a **beam-agent** — one per provider, deployed on the
> infra cluster (e.g. `beam-cloudless` on infra-stage). The agent is configured (see its
> `beam-agent-config` ConfigMap) with:
> - `BEAM__K8S__DEFAULT__SPECTRUM__NETWORK=<env>` — beam injects this as `spectrum-vars.NETWORK`;
> - `BEAM__BOOTSTRAP__EXTRA_MANIFEST=…/spectrum-ng/…/bootstrap/bootstrap.yml` — beam applies
>   this repo's flux bootstrap automatically (so step 3 below is normally done *by* beam);
> - `BEAM__VAULT__MOUNT=beam` — the cluster's kubeconfig/talosconfig live in Vault, and the
>   apiserver is reached over beam's WireGuard tunnel (not a public endpoint). To inspect a
>   running spectrum cluster you go in via beam/Vault, not a downloaded kubeconfig.

There are two flavours of "add a cluster":

- **(A) New cluster of an existing network** (e.g. a second `testnet`) — the git overlays
  already exist; you only provision the cluster and seed its per-cluster vars/secrets.
  `CLUSTER_ID` is what makes it unique.
- **(B) A brand-new network** (e.g. `foonet`) — additionally create the git overlays
  (see [§5](#5-new-network-extra-git-changes)).

All per-cluster configuration is injected out-of-band through **three substitution
sources** plus a handful of **standalone secrets**. None of these live in git.

---

## 1. Substitution sources (namespace `flux-system`)

Almost every Flux Kustomization sets `postBuild.substituteFrom` over these. `${VAR}`
tokens in the manifests are filled from them at apply time.

| Object | Kind | Created by | `optional` | Holds |
|---|---|---|---|---|
| `spectrum-vars` | ConfigMap | **beam** | `false` (always required) | `NETWORK` |
| `spectrum-manual-vars` | ConfigMap | **manual** | required for cert-manager / envoy / external-dns / piraeus; optional elsewhere | `CLUSTER_ID`, `PROVIDER`, `PUBLIC_SUBNET_LIST`, `ENVOY_PUBLIC_SUBNET`, `GRAFANA_OIDC_CLIENT_ID`, `STORAGE_SATELLITE_IPS`, `STORAGE_NAD`, `STORAGE_PREF_NIC` |
| `spectrum-manual-secrets` | Secret | **manual** | optional | `GRAFANA_OIDC_CLIENT_SECRET`, `CLOUDFLARE_TOKEN` |

> ⚠️ `optional: true` means the *source object* may be absent — **not** that the
> variables are optional. `CLUSTER_ID` etc. are still required for manifests to render
> correctly; leaving them unset bakes literal `${CLUSTER_ID}` into hostnames and breaks
> things silently.

### Variable → source → consumer

| Variable | Source | Consumed by | Notes |
|---|---|---|---|
| `NETWORK` | `spectrum-vars` (beam) | everything; also selects every `overlays/${NETWORK}` path | the master switch |
| `CLUSTER_ID` | `spectrum-manual-vars` | coredns `.spectrum` zone, grafana `root_url`, NetBird group/route/NBResource names, crd-api host | unique per cluster |
| `PROVIDER` | `spectrum-manual-vars` | external-dns `txtOwnerId`, crd-api host | required (external-dns ks requires manual-vars) |
| `PUBLIC_SUBNET_LIST` | `spectrum-manual-vars` | crd-operator controller public-network subnets | |
| `ENVOY_PUBLIC_SUBNET` | `spectrum-manual-vars` | envoy proxy | required (envoy ks requires manual-vars) |
| `CLOUDFLARE_TOKEN` | `spectrum-manual-secrets` | baked into Secrets `cloudflare-certmanager-token` / `cloudflare-external-dns-token` (key `token`) | sensitive. `cluster-issuers` and `external-dns-cloudflare` list the Secret **after** the ConfigMaps, so it overrides a leftover plaintext copy while a cluster is being migrated |
| `GRAFANA_OIDC_CLIENT_ID` | `spectrum-manual-vars` | grafana `auth.generic_oauth.client_id` | non-secret |
| `GRAFANA_OIDC_CLIENT_SECRET` | `spectrum-manual-secrets` | baked into Secret `grafana-oidc` (key `client_secret`) | sensitive |
| `STORAGE_SATELLITE_IPS` | `spectrum-manual-vars` | `ip_pool` annotation on the LINSTOR satellite | one address per node running a satellite, from the storage subnet's CIDR. A **set**, not a mapping — the nth entry is not the nth node, read the address off the pod. Pinned for the node's life: LINSTOR stores the literal IP, so a reallocated one leaves a dead `NetInterface` and replication fails silently; see §3 |
| `STORAGE_NAD` | `spectrum-manual-vars` | `k8s.v1.cni.cncf.io/networks` on the LINSTOR satellite | `<namespace>/<name>` of the hand-applied NAD, e.g. `storage/linstor` — the whole reference, not just the name. The `Subnet`'s `provider` encodes the same pair as `<nad>.<namespace>.ovn` |
| `STORAGE_PREF_NIC` | `spectrum-manual-vars` | `PrefNic` property on the LINSTOR satellite | name of the LINSTOR `NetInterface` DRBD replicates over, e.g. `storage`. Must equal the name used in the manual `linstor node interface create`; nothing verifies the two, see §3 |
| `OVN_TUNNEL_IFACE` | `spectrum-manual-vars` | kube-ovn `agent.interface` → `--iface` | the interface Geneve leaves on. Unset means the interface holding the node IP — the 1G management port on every Kabat node, so all east-west shares it. Setting it needs an address on that interface first (Talos, beam); see §6 |
| `SERVICE_CIDR` | `spectrum-manual-vars` | kube-ovn `networking.services.cidr.v4` → `--service-cluster-ip-range` | must equal what the apiserver actually allocates from (`kubectl -n default get svc kubernetes`). Defaults to the chart's `10.96.0.0/12`, which is **not** what every cluster runs — stage serves `10.112.0.0/12`. Nothing detects the mismatch; see gotcha #5 |

`NETID`, `NEWEST_AGE`, `RENEW_AFTER_DAYS` are **not** bootstrap variables — they are
shell variables inside Jobs (escaped `$${NETID}`) or hardcoded Job env, not Flux
substitutions.

---

## 2. Standalone secrets (created directly, not via substitution)

| Secret | Namespace | Key(s) | Consumer | Needed when |
|---|---|---|---|---|
| `spectrum-manual-secrets` | `flux-system` | `GRAFANA_OIDC_CLIENT_SECRET` | grafana OIDC (via substitution) | observability present |
| `netbird-api-token` | `networking` | `NB_API_KEY` | netbird operator + setup/route/rotate jobs | `networking` group present (= every cluster with observability/Grafana mesh) |
| `alertmanager-config` | `observability` | `alertmanager.yaml` | VMAlertmanager | observability present |
| `fluence-mesh-intermediate` | `observability` | `ca.crt` + `tls.crt` + `tls.key` | cert-manager `fluence-intermediate` Issuer → issues `grafana-spectrum-tls`; Grafana also mounts its `ca.crt` | observability present (Grafana mesh TLS/OIDC) |
| `lightmare-ssh-creds` | `fluence` | `identity` + `known_hosts` | crd-operator chart `GitRepository lightmare` | **stage only** — testnet/mainnet pull the chart from OCI and need no SSH secret |
| `regcred` (testnet) / `fluence-regcred` (mainnet) | `fluence` | `.dockerconfigjson` for `containers.cloudless.dev` (user `node-puller`) | crd-operator chart `OCIRepository crd-operator` (`secretRef`), and image pulls where the nodes carry no registry creds | **testnet/mainnet** — the chart moved from Docker Hub to the private zot in 2026-09; without this secret the next chart bump silently never arrives (Flux keeps the old chart and reports nothing but a stale revision). The name differs per network because both secrets were hand-applied before the OCIRepository needed them; `kubectl -n fluence get secret -o custom-columns=NAME:.metadata.name,TYPE:.type` shows which one a cluster has |

> `netbird-api-token` is a hand-seeded admin PAT for the per-cluster NetBird service user
> `spectrum-<NETWORK>` (e.g. `spectrum-testnet`). The service user, plus the shared
> `support`/`admins` groups, must already exist on the central management at
> `netbird.infrahub.cloudless.dev`. `netbird-gate` health-gates the whole NetBird stack
> on this secret, so the cluster reconciles normally until it is seeded.
>
> `fluence-mesh-intermediate` is this cluster's intermediate CA (cert+key), signed by the
> single Fluence Mesh Root on infrahub and name-constrained to
> `<CLUSTER_ID>.<NETWORK>.spectrum`. Hand-delivered (copy-flow); the root key never leaves
> infrahub.

### Auto-managed (no manual step — listed for awareness)

| Secret | How it's created |
|---|---|
| `cloudflare-certmanager-token`, `cloudflare-external-dns-token` | rendered from `${CLOUDFLARE_TOKEN}` |
| `grafana-oidc` | rendered from `${GRAFANA_OIDC_CLIENT_SECRET}` |
| `grafana-admin-credentials` | random, seeded by the `grafana-admin-bootstrap` Job (no Vault/ESO) |
| `grafana-spectrum-tls`, `cloudless-dev-tls`, `cloudless-dev-key` | issued by cert-manager |

---

## 3. Node prerequisites (beam)

- Storage nodes must carry the label `beam/linstor_ready=true` — the piraeus
  `LinstorCluster` satellite `nodeSelector` targets it.

### Dedicated storage network (per node, manual)

On a cluster that has a storage network, the satellite is attached to the `linstor`
NAD and gets a pinned address from `STORAGE_SATELLITE_IPS`. Pointing DRBD
replication at it takes one command **per node**, which has no declarative form in
Piraeus:

```bash
linstor node interface create <node> <STORAGE_PREF_NIC> <ip-from-STORAGE_SATELLITE_IPS>
```

`PrefNic` is declared in the overlay (`satellite.yml` → `spec.properties`) and does not
need setting by hand. The interface does, because Piraeus only ever registers the
primary pod IP — it tracks its own set in the node property
`Aux/piraeus.io/configured-interfaces` and leaves interfaces it did not create alone,
so a hand-registered one survives satellite restarts. Registration is therefore
one-off per node, not a standing reconcile: the `NetInterface` lives in the LINSTOR
controller's database, not in the satellite pod.

> ⚠️ `PrefNic` and this hand-registered interface are two ends of one name, and nothing
> verifies them against each other: `PrefNic` comes from `STORAGE_PREF_NIC`, the
> interface is created by hand. A mismatch fails nothing — the pod starts, and DRBD
> quietly replicates over the pod network instead. Check it whenever a node joins.

Two things this does **not** do: the satellite's control connection to the controller
stays on the pod network (`CurStltConnName` remains `default-ipv4` — only replication
moves), and the VLAN must actually be trunked to the node's port by the site. Verify
with:

```bash
linstor node interface list <node>     # default-ipv4 AND the STORAGE_PREF_NIC name
linstor node list-properties <node>    # PrefNic = that same name
```

All three storage values in `satellite.yml` — `STORAGE_NAD`, `STORAGE_SATELLITE_IPS`
and `STORAGE_PREF_NIC` — come from `spectrum-manual-vars`, set by hand at bootstrap
alongside the objects they name. Keeping them as variables means one place per cluster
describes its storage network, rather than splitting that description between a
ConfigMap and three overlays.

None of them has a default, deliberately. An unset variable substitutes to an empty string, and
the CRD accepts an empty `PrefNic` or `ip_pool` — which points DRBD back at the pod
network without failing anything. A cluster with no storage network must therefore leave `satellite.yml`
out of its overlay, which is why the file is overlay-scoped rather than shared. Note
also that `${VAR:?message}` does **not** help: in flux's substitution it yields the
message text as the value and still succeeds, so there is no "required variable" that
fails a build.

> ⚠️ **Known open risk: nothing checks that the overlay and the cluster agree.** Leaving
> `satellite.yml` out is a *convention*, not a mechanism — all three overlays include it
> today with the same unconditional `patches:` entry. A cluster whose overlay carries the
> file but which has no storage network gets an empty `ip_pool`; a cluster with the
> network whose overlay omits the file gets no network annotation at all. Neither fails a
> build, kills a pod, or logs an error; in both cases DRBD replicates over the pod
> network — through Geneve and out the 1G management port. The only check that catches it
> is observing the outcome — whether replication actually rides the storage NIC — which
> needs LINSTOR metrics that are not scraped yet.

What the satellite attaches *to* — the `ProviderNetwork`, the `Vlan`, the `linstor`
`Subnet` and its NAD — is **applied by hand** on each cluster. On stage that is
`ProviderNetwork storage` on the dedicated 10G port `enp16s0f1`, so replication does not
share the workload underlay, plus `Vlan 504` and the subnet on it.

beam briefly owned the `Subnet` and NAD (this repo dropped them in #202) and then
withdrew the whole storage-ownership set, so **nothing outside a human creates or
reconciles any of the four objects today**. The site also has to trunk the VLAN to the
node's port, which nothing in Kubernetes can verify.

> ⚠️ **This is the single point of loss in the storage network.** No manifest in any repo
> describes these objects; they exist only on the live cluster, in one copy. Deleting
> them does not break anything visibly — a running satellite keeps its interface until it
> restarts — and nothing recreates them. Keep a copy of the four manifests to hand, and
> re-check before reprovisioning a node.
>
> This is unfinished, not intended: the objects need an owner, either back in this repo
> as hardware manifests or somewhere that reconciles them.

### Which interface and VLAN carries what

A Kabat node has three traffic classes, and only two of them ride a VLAN today:

| Traffic | How it leaves the node | Owner of the objects |
|---|---|---|
| Public (Kabat ASN) | tagged, through the underlay `ProviderNetwork` bridge | beam (`ProviderNetwork` + `Vlan` + the public `Subnet`, labelled `fluence/created-by=beam`) |
| Storage / DRBD replication | tagged, through a `ProviderNetwork` bridge | all four objects (`ProviderNetwork`, `Vlan`, `Subnet`, NAD) by hand, reconciled by nothing; this repo keeps only the satellite wiring, see above |
| Pod east-west (Geneve) | **untagged, on whichever interface holds the node IP** | kube-ovn default, until `OVN_TUNNEL_IFACE` is set |

The third row is the one to check on a new cluster. kube-ovn picks the tunnel endpoint
from the node IP, which on the Kabat nodes is the 1G management port — so pod-to-pod
traffic shares a 1G link with the control plane while the 10G ports carry only public
and storage. Nothing warns about it; the cluster is simply slower than its cabling.

Moving it is not a GitOps-only change. `OVN_TUNNEL_IFACE` names an interface that must
already hold an address, which is a Talos machine-config fact owned by beam. When
kube-ovn has taken that port into a provider bridge it migrates the address onto the
bridge, so the value to set is then `br-underlay`, not the physical port.

Whether the underlay carries one VLAN or several is a data question, not a code one: a
`ProviderNetwork` holds a list of VLANs, so a second `Vlan` with the same `provider:`
plus a `Subnet` referencing it is all that separates, say, public traffic from other
underlay subnets on the same trunk. Testnet already runs two (public and storage) off a
single `ProviderNetwork`. The site has to trunk the VLAN to that port first.

Per-node interface names differ, and beam handles that with
`ProviderNetwork.spec.customInterfaces` — testnet's underlay is `enp36s0f0` by default
with `enp65s0f0` overridden for `kabat-02`. A new node with different NICs needs that
list extended, or its bridge never initializes.

Verify on a running cluster:

```bash
kubectl get provider-networks -o wide      # DEFAULTINTERFACE + READY
kubectl get vlans                          # ID → provider
kubectl get subnets.kubeovn.io -o wide     # which subnet rides which VLAN
kubectl get node <node> -o jsonpath='{.metadata.annotations}' | tr ',' '\n' \
  | grep provider-network                  # per-node interface actually taken
```

The last one is the honest check: `ProviderNetwork.status.ready` keeps its last good
value, so a bridge that was torn down still reads `ready: true` while the node
annotations are gone.

---

## 4. Bootstrap sequence

1. **beam** provisions the Talos cluster, creates `spectrum-vars` (`NETWORK=<env>`, from
   the agent's `BEAM__K8S__DEFAULT__SPECTRUM__NETWORK`) in `flux-system`, and labels
   storage nodes (`beam/linstor_ready=true`). For an existing network this just means
   pointing/adding a beam-agent for the new provider.

2. **Seed the manual config** (substitution sources + standalone secrets):

   ```bash
   # Substitution ConfigMap
   kubectl -n flux-system create configmap spectrum-manual-vars \
     --from-literal=CLUSTER_ID=<id> \
     --from-literal=PROVIDER=<provider> \
     --from-literal=PUBLIC_SUBNET_LIST=<list> \
     --from-literal=ENVOY_PUBLIC_SUBNET=<cidr> \
     --from-literal=GRAFANA_OIDC_CLIENT_ID=<oidc_client_id>

   # Substitution Secret (anything sensitive)
   kubectl -n flux-system create secret generic spectrum-manual-secrets \
     --from-literal=GRAFANA_OIDC_CLIENT_SECRET=<oidc_client_secret> \
     --from-literal=CLOUDFLARE_TOKEN=<cf_token>

   # Standalone secrets
   kubectl create namespace networking
   kubectl -n networking create secret generic netbird-api-token \
     --from-literal=NB_API_KEY=<spectrum-NETWORK_admin_PAT>

   kubectl create namespace observability
   kubectl -n observability create secret generic alertmanager-config \
     --from-file=alertmanager.yaml=<path>
   kubectl -n observability create secret generic fluence-mesh-intermediate \
     --from-file=ca.crt=<root-or-chain.crt> \
     --from-file=tls.crt=<intermediate.crt> --from-file=tls.key=<intermediate.key>

   # stage only (testnet/mainnet use the OCI chart, no SSH secret):
   # kubectl -n fluence create secret generic lightmare-ssh-creds \
   #   --from-file=identity=<ssh_key> --from-file=known_hosts=<known_hosts>
   ```

3. **Bootstrap Flux** (flux-operator + FluxInstance + spectrum source, pointing at
   `./clusters/bootstrap`). Normally **beam does this for you** — its
   `BEAM__BOOTSTRAP__EXTRA_MANIFEST` points at this repo's `bootstrap/bootstrap.yml`. To
   do it by hand (e.g. a non-beam cluster):

   ```bash
   kubectl apply --server-side -k bootstrap/bootstrap
   # (or the pre-rendered bundle beam uses: kubectl apply -f bootstrap/bootstrap.yml)
   ```

   This brings up Flux and the minimal `clusters/bootstrap` set (`kube-system` +
   `flux-system`).

4. **Select the environment** (one-time). The env overlay is **not** reconciled by Flux
   automatically — apply it by hand to repoint the `spectrum` GitRepository ref and the
   root Kustomization from `./clusters/bootstrap` to `./clusters/<env>`:

   ```bash
   kubectl apply -k flux/apps/flux-system/flux-instance/app/spectrum/overlays/<env>
   ```

   - `stage` → tracks branch `main`, path `./clusters/stage`
   - `testnet` / `mainnet` → tracks git tag `testnet` / `mainnet`, path `./clusters/<env>`

5. **Watch it converge:**

   ```bash
   flux get kustomizations -A
   flux get helmreleases -A
   ```

---

## 5. New network: extra git changes

Because the per-app `ks.yml` files select their overlay by `path: .../overlays/${NETWORK}`,
a brand-new `NETWORK` needs an overlay directory in **every** such place or its
Kustomization fails to reconcile. For a new network `foonet`, add:

| Path | What |
|---|---|
| `clusters/foonet/kustomization.yml` | app-group list (copy from `testnet`; add `networking` if it runs Grafana) |
| `flux/apps/flux-system/flux-instance/app/spectrum/overlays/foonet/` | `gitrepository.yml` (branch or tag) + `spectrum.yml` (`path: ./clusters/foonet`) |
| `flux/apps/fluence/crd-operator/app/overlays/foonet/` | chart source — OCI (like testnet/mainnet) or git (like stage) |
| `flux/apps/networking/netbird-operator-config/app/overlays/foonet/` | `router.replicas: 1` patch (only if `networking` is included) |
| `flux/apps/storage/piraeus-operator/cluster/overlays/foonet/` | `kustomization.yml`; add `satellite.yml` only if the cluster has a hand-built storage VLAN |

> Any cluster that includes `flux/apps/observability` **must** also include
> `flux/apps/networking` — Grafana joins the mesh (creates `SetupKey`/`NBSetupKey`,
> annotates its pod for sidecar injection, and serves on `grafana.<id>.<net>.spectrum`
> over mesh-only `authentik.infra`). Without the NetBird operator those CRs reference
> missing CRDs and OIDC login breaks.

---

## 6. Gotchas

1. **`netbird-api-token` key is `NB_API_KEY`** (not `token`). The operator, setup/route
   jobs and the rotate CronJob all read `NB_API_KEY`.
2. **`CLOUDFLARE_TOKEN` moved out of the ConfigMap.** It used to sit in
   `spectrum-manual-vars` in plaintext, because `cluster-issuers` and
   `external-dns-cloudflare` had no Secret substitution source; they do now, and the
   token belongs in `spectrum-manual-secrets`. On a cluster still carrying the old copy,
   the Secret wins (it is listed last), so seed it first and drop the ConfigMap key
   afterwards. Either way the value is baked into Opaque Secrets at apply time.
3. **Don't force-remove NetBird CR finalizers** on teardown — the operator owns
   control-plane cleanup.
4. **`grafana-admin-credentials`** only adopts its seeded password on a *fresh* Grafana DB.
   If the PVC already has an admin user, delete the grafana PVC + pod once so first-init
   picks it up.
5. **kube-ovn's idea of the service range is a chart default, not the cluster's.**
   `--service-cluster-ip-range` comes from this repo (`SERVICE_CIDR`, defaulting to
   `10.96.0.0/12`); the range the apiserver actually allocates from comes from Talos
   (`cluster.network.serviceSubnets`) and is set by whoever provisions the cluster. On
   stage they disagreed — services live in `10.112.0.0/12` while kube-ovn was told
   `10.96.0.0/12` — and nothing surfaced it, because OVN load balancers serve ClusterIPs
   from the logical switch regardless. The range still governs what the CNI treats as
   service traffic for SNAT and routing, so check it on every new cluster:
   `kubectl -n default get svc kubernetes` names the range in one number.

---

## 7. Verified against spectrum-stage (2026-06-06)

The above was confirmed on the live `spectrum-stage` child cluster (reached via
`kubectl -n beam-cloudless exec <beam-agent pod> -- kubectl --kubeconfig /root/kubeconfig …`
on infra-stage):

| Object | Keys found on stage |
|---|---|
| `spectrum-vars` (CM) | `NETWORK` **only** — beam injects nothing else |
| `spectrum-manual-vars` (CM) | `CLUSTER_ID`, `PROVIDER`, `PUBLIC_SUBNET_LIST`, `ENVOY_PUBLIC_SUBNET`, `GRAFANA_OIDC_CLIENT_ID`, and since 2026-07-28 `STORAGE_CIDR`, `STORAGE_VLAN`, `STORAGE_SATELLITE_IPS`, `STORAGE_MTU`. `STORAGE_NAD` and `STORAGE_PREF_NIC` were **absent** at that observation — see the prerequisite note below |
| `spectrum-manual-secrets` (Secret) | `GRAFANA_OIDC_CLIENT_SECRET`, `CLOUDFLARE_TOKEN` |
| `netbird-api-token` (Secret, networking) | `NB_API_KEY` |
| `alertmanager-config` (Secret, observability) | `alertmanager.yaml` |
| `fluence-mesh-intermediate` (Secret, observability) | `ca.crt`, `tls.crt`, `tls.key` |
| `lightmare-ssh-creds` (Secret, fluence) | `identity`, `known_hosts` |

Stage's `spectrum-manual-vars` still carries the `STORAGE_*` trio from when this repo
rendered the `linstor` `Subnet`. `spectrum-vars` holds `NETWORK` only.

### Re-verified on spectrum-stage (`kabat-05`, 2026-08-18)

| Observed | Value |
|---|---|
| `spectrum-vars` keys | `NETWORK`, `STORAGE_VLAN` — beam still writes `STORAGE_VLAN`, read by nothing here |
| `spectrum-manual-vars` storage keys | `STORAGE_CIDR`, `STORAGE_MTU`, `STORAGE_SATELLITE_IPS`, `STORAGE_VLAN` |
| **`STORAGE_NAD`, `STORAGE_PREF_NIC`** | **absent** |
| Live `LinstorSatelliteConfiguration/talos-override` | `networks: storage/linstor`, `PrefNic: storage`, `ip_pool: 10.118.147.51` |
| Hand-applied objects present | NAD `storage/linstor`; `ProviderNetwork/storage` on `enp16s0f1`; `Vlan/504` provider `storage` |

> ⚠️ **Hard prerequisite before `satellite.yml` may consume variables.** It reads three
> keys — `STORAGE_NAD`, `STORAGE_SATELLITE_IPS`, `STORAGE_PREF_NIC`. Only the middle one
> exists on stage today. The other two must be added to `spectrum-manual-vars` on **every**
> cluster running a satellite *before* this repo is reconciled, matching the hand-applied
> objects — on stage `STORAGE_NAD=storage/linstor` and `STORAGE_PREF_NIC=storage`.
>
> `piraeus-operator/ks.yml` marks `spectrum-manual-vars` `optional: false`, so a cluster
> with no such ConfigMap fails the build loudly. That does **not** cover a ConfigMap that
> exists but lacks a key: flux substitutes an empty string and succeeds, and an empty
> `PrefNic` or NAD reference is accepted by the CRD — DRBD then replicates over the pod
> network via Geneve and the management NIC, with nothing failing. Check the keys with the
> commands below before merging a change that consumes them.

To re-verify on any cluster (keys only, no secret values leave the cluster):

```bash
kubectl -n flux-system get cm spectrum-vars        -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
kubectl -n flux-system get cm spectrum-manual-vars -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
kubectl -n flux-system get secret spectrum-manual-secrets -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
```
