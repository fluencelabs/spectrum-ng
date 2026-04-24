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

NetBird API token for the kubernetes-operator to connect to centralized management.

```bash
kubectl create secret generic netbird-api-token \
  --namespace networking \
  --from-literal=token=<YOUR_NETBIRD_API_TOKEN>
```
