# spectrum-ng

## Post-bootstrap prerequisites

After bootstrapping a cluster, the following resources must be created manually.

### ConfigMap: `spectrum-vars` (namespace: `flux-system`)

Created automatically by beam. Contains:

| Variable | Description |
|---|---|
| `NETWORK` | Network name (e.g. `testnet`, `mainnet`, `stage`) |

### ConfigMap: `spectrum-manual-vars` (namespace: `flux-system`, optional)

Cluster-specific overrides, created manually.

| Variable | Description |
|---|---|
| `CLUSTER_ID` | Unique cluster identifier |
| `PROVIDER` | Infrastructure provider identifier |
| `PUBLIC_SUBNET_LIST` | Public subnet list for CRD operator |
| `ENVOY_PUBLIC_SUBNET` | Public subnet for Envoy proxy |
| `STORAGE_VLAN` | VLAN ID for storage network (optional) |
| `CLOUDFLARE_TOKEN` | Cloudflare API token for DNS and cert-manager |

### Secret: `alertmanager-config` (namespace: `observability`)

Alertmanager configuration for VMAlertmanager. Must contain the key `alertmanager.yaml`.

```bash
kubectl create secret generic alertmanager-config \
  --namespace observability \
  --from-file=alertmanager.yaml=<PATH_TO_ALERTMANAGER_CONFIG>
```

### Secret: `netbird-api-token` (namespace: `networking`)

Required on every cluster that deploys the `networking` (NetBird) app group — i.e.
all clusters running the observability stack, since Grafana joins the mesh to reach
the mesh-only authentik.infra for OIDC.

A hand-seeded admin PAT for the per-cluster NetBird service user `spectrum-<NETWORK>`
(e.g. `spectrum-testnet`). The service user, plus the shared `support` and `admins`
groups, must already exist on the centralized management at
`netbird.infrahub.cloudless.dev`. The `netbird-token-rotate` CronJob rotates this PAT
in place afterwards.

The secret key consumed by the operator and the setup/rotate jobs is `NB_API_KEY`
(not `token`):

```bash
kubectl create namespace networking
kubectl create secret generic netbird-api-token \
  --namespace networking \
  --from-literal=NB_API_KEY=<spectrum-NETWORK_admin_PAT>
```

The `netbird-gate` Flux Kustomization health-gates the whole NetBird stack on this
secret, so the rest of the cluster reconciles normally until it is present.
