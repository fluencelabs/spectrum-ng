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
| `spectrum-manual-vars` | ConfigMap | **manual** | required for cert-manager / envoy / external-dns / piraeus; optional elsewhere | `CLUSTER_ID`, `PROVIDER`, `PUBLIC_SUBNET_LIST`, `ENVOY_PUBLIC_SUBNET`, `CLOUDFLARE_TOKEN`, `GRAFANA_OIDC_CLIENT_ID`, `STORAGE_CIDR`, `STORAGE_SATELLITE_IPS`, `STORAGE_MTU`, and `STORAGE_VLAN` where beam did not supply it |
| `spectrum-manual-secrets` | Secret | **manual** | optional (grafana only) | `GRAFANA_OIDC_CLIENT_SECRET` |

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
| `CLOUDFLARE_TOKEN` | `spectrum-manual-vars` | baked into Secrets `cloudflare-certmanager-token` / `cloudflare-external-dns-token` (key `token`) | ⚠️ plaintext token in a ConfigMap — cert-manager/external-dns ks have no Secret source |
| `GRAFANA_OIDC_CLIENT_ID` | `spectrum-manual-vars` | grafana `auth.generic_oauth.client_id` | non-secret |
| `GRAFANA_OIDC_CLIENT_SECRET` | `spectrum-manual-secrets` | baked into Secret `grafana-oidc` (key `client_secret`) | sensitive |
| `STORAGE_VLAN` | `spectrum-vars` where beam supplied it, otherwise `spectrum-manual-vars` | piraeus `linstor` Subnet | ⚠️ the quotes are part of the value — write `"504"`. `vlan` is a string in the CRD, and an unquoted value renders as a number the CRD rejects. beam writes it the same way |
| `STORAGE_CIDR` | `spectrum-manual-vars` | piraeus `linstor` Subnet | required on every cluster whose overlay has `network.yml` — no default, a missing value fails the build on purpose |
| `STORAGE_SATELLITE_IPS` | `spectrum-manual-vars` | `ip_pool` annotation on the LINSTOR satellite (stage overlay) | one address per node running a satellite, taken from `STORAGE_CIDR`; see §3 |
| `STORAGE_MTU` | `spectrum-manual-vars` | piraeus `linstor` Subnet `spec.mtu` (stage overlay) | what the cluster's storage port actually carries, usually 1500. Without it kube-ovn defaults pods to 1400, which reserves room for Geneve headers that a VLAN underlay never adds |

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

On a cluster whose overlay carries a `network.yml`, the satellite is attached to the
`linstor` NAD and gets a pinned address from `STORAGE_SATELLITE_IPS`. Pointing DRBD
replication at it takes one command **per node**, which has no declarative form in
Piraeus:

```bash
linstor node interface create <node> storage <ip-from-STORAGE_SATELLITE_IPS>
```

`PrefNic` is declared in the overlay (`satellite.yml` → `spec.properties`) and does not
need setting by hand. The interface does, because Piraeus only ever registers the
primary pod IP — it tracks its own set in the node property
`Aux/piraeus.io/configured-interfaces` and leaves interfaces it did not create alone,
so a hand-registered one survives satellite restarts.

Two things this does **not** do: the satellite's control connection to the controller
stays on the pod network (`CurStltConnName` remains `default-ipv4` — only replication
moves), and the VLAN must actually be trunked to the node's port by the site. Verify
with:

```bash
linstor node interface list <node>     # both default-ipv4 and storage present
linstor node list-properties <node>    # PrefNic = storage
```

Also required outside Kubernetes: a `ProviderNetwork` and `Vlan` for that VLAN on the
node's interface. These are per-cluster hardware facts, deliberately not in any overlay.

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
     --from-literal=CLOUDFLARE_TOKEN=<cf_token> \
     --from-literal=GRAFANA_OIDC_CLIENT_ID=<oidc_client_id>

   # Substitution Secret (OIDC client secret)
   kubectl -n flux-system create secret generic spectrum-manual-secrets \
     --from-literal=GRAFANA_OIDC_CLIENT_SECRET=<oidc_client_secret>

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
| `flux/apps/storage/piraeus-operator/cluster/overlays/foonet/` | `kustomization.yml`; add `network.yml` for a dedicated storage VLAN |

> Any cluster that includes `flux/apps/observability` **must** also include
> `flux/apps/networking` — Grafana joins the mesh (creates `SetupKey`/`NBSetupKey`,
> annotates its pod for sidecar injection, and serves on `grafana.<id>.<net>.spectrum`
> over mesh-only `authentik.infra`). Without the NetBird operator those CRs reference
> missing CRDs and OIDC login breaks.

---

## 6. Gotchas

1. **`netbird-api-token` key is `NB_API_KEY`** (not `token`). The operator, setup/route
   jobs and the rotate CronJob all read `NB_API_KEY`.
2. **`STORAGE_VLAN` can come from either ConfigMap.** beam writes it into `spectrum-vars`
   when its bootstrap supplied a storage vlan; where it did not, put it in
   `spectrum-manual-vars`. The `linstor-cluster` Kustomization reads both — it used to
   substitute only `spectrum-vars`, which is why the variable used to look like it had to
   live there. Note beam's storage bootstrap step currently fails on every cluster (it
   POSTs a namespaced CRD through a cluster-scoped path and gets a plain-text 404), so in
   practice new clusters supply all three `STORAGE_*` vars by hand.
3. **`CLOUDFLARE_TOKEN` lives in a ConfigMap** (`spectrum-manual-vars`) in plaintext —
   cert-manager/external-dns Kustomizations have no Secret substitution source. It is
   baked into Opaque Secrets at apply time.
4. **Don't force-remove NetBird CR finalizers** on teardown — the operator owns
   control-plane cleanup.
5. **`grafana-admin-credentials`** only adopts its seeded password on a *fresh* Grafana DB.
   If the PVC already has an admin user, delete the grafana PVC + pod once so first-init
   picks it up.

---

## 7. Verified against spectrum-stage (2026-06-06)

The above was confirmed on the live `spectrum-stage` child cluster (reached via
`kubectl -n beam-cloudless exec <beam-agent pod> -- kubectl --kubeconfig /root/kubeconfig …`
on infra-stage):

| Object | Keys found on stage |
|---|---|
| `spectrum-vars` (CM) | `NETWORK` **only** — beam injects nothing else |
| `spectrum-manual-vars` (CM) | `CLUSTER_ID`, `PROVIDER`, `PUBLIC_SUBNET_LIST`, `ENVOY_PUBLIC_SUBNET`, `CLOUDFLARE_TOKEN`, `GRAFANA_OIDC_CLIENT_ID`, and since 2026-07-28 `STORAGE_CIDR`, `STORAGE_VLAN`, `STORAGE_SATELLITE_IPS` |
| `spectrum-manual-secrets` (Secret) | `GRAFANA_OIDC_CLIENT_SECRET` |
| `netbird-api-token` (Secret, networking) | `NB_API_KEY` |
| `alertmanager-config` (Secret, observability) | `alertmanager.yaml` |
| `fluence-mesh-intermediate` (Secret, observability) | `ca.crt`, `tls.crt`, `tls.key` |
| `lightmare-ssh-creds` (Secret, fluence) | `identity`, `known_hosts` |

Stage since gained a storage overlay of its own, so the `STORAGE_*` trio now lives in its
`spectrum-manual-vars` — `spectrum-vars` still holds `NETWORK` only, because beam's
storage bootstrap step never completes. The earlier reading of gotcha #2, that
`STORAGE_VLAN` had to live in `spectrum-vars`, no longer holds: `linstor-cluster`
substitutes from both ConfigMaps.

To re-verify on any cluster (keys only, no secret values leave the cluster):

```bash
kubectl -n flux-system get cm spectrum-vars        -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
kubectl -n flux-system get cm spectrum-manual-vars -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
kubectl -n flux-system get secret spectrum-manual-secrets -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
```
