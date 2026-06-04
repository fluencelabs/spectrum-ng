# kube-oidc-proxy — operator access

Authenticated `kubectl` access to the beam cluster API via Authentik SSO, over the NetBird mesh.
Analogous to Grafana at `https://grafana.<cluster_id>.<network>.spectrum`.

## How it works

```
kubectl → oidc-login (browser auth-code + PKCE → Authentik on authentik.infra) → ID token
  → https://k8s.<cluster_id>.<network>.spectrum   (NetBird mesh, Fluence leaf cert)
    → kube-oidc-proxy: validates iss/aud/signature, reads username + groups
      → real kube-apiserver  with Impersonate-User / Impersonate-Group
        → RBAC: group k8s-admins → cluster-admin, k8s-viewers → view
```

The apiserver itself is owned by **beam** and is not OIDC-configured; the proxy does impersonation,
so no apiserver flags are required.

## Prerequisites (operator laptop)

- On the NetBird mesh (so `authentik.infra` and `k8s.<id>.<net>.spectrum` resolve).
- Trust the Fluence Mesh Root CA locally (same root already trusted for Grafana access).
- `kubectl` plus `kubelogin` — install the `kubectl oidc-login` plugin:
  `kubectl krew install oidc-login` (or download the int128/kubelogin release).
- Member of Authentik group `k8s-admins` (full) or `k8s-viewers` (read-only).

## kubeconfig

Replace `<cluster_id>`, `<network>`, `<slug>`, `<client_id>`, and the CA path.

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: beam-<network>
    cluster:
      server: https://k8s.<cluster_id>.<network>.spectrum
      certificate-authority: /path/to/fluence-mesh-root.pem
contexts:
  - name: beam-<network>
    context:
      cluster: beam-<network>
      user: authentik
current-context: beam-<network>
users:
  - name: authentik
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: kubectl
        args:
          - oidc-login
          - get-token
          - --oidc-issuer-url=https://authentik.infra/application/o/<slug>/
          - --oidc-client-id=<client_id>
          - --oidc-use-pkce
          - --oidc-extra-scope=groups
          - --oidc-extra-scope=profile
          - --oidc-extra-scope=email
```

First `kubectl` call opens a browser to `authentik.infra`; the token is cached by kubelogin.

## Bootstrap secrets (out-of-band, NOT in git)

Created per cluster in namespace `kube-oidc-proxy`:

| Secret | Keys | Purpose |
|---|---|---|
| `fluence-mesh-intermediate` | `tls.crt`, `tls.key` | Per-cluster intermediate CA backing the `fluence-intermediate` Issuer (same hand-delivery as the Grafana namespace) |
| `kube-oidc-proxy-authentik-ca` | `ca.crt` | Fluence Mesh Root, used by the proxy to verify `authentik.infra`'s served cert (`--oidc-ca-file`) |
| `kube-oidc-proxy-netbird-setupkey` | `NB_SETUP_KEY` | NetBird setup key for the sidecar peer (reusable; group `spectrum-${NETWORK}`) |

And per cluster in the `spectrum-manual-vars` ConfigMap:

| Var | Example | Purpose |
|---|---|---|
| `KUBE_OIDC_SLUG` | `kube` | Authentik application slug → issuer path |
| `KUBE_OIDC_CLIENT_ID` | `<uuid>` | Authentik OIDC client id (public client) |

## Infra-side checklist (Authentik / NetBird — done by the infra owner)

- Authentik application + OIDC provider for kube-oidc-proxy:
  - **public client + PKCE** (no client secret),
  - redirect URIs for kubelogin: `http://localhost:8000` and `http://127.0.0.1:18000`,
  - issuer host `authentik.infra`, emits the `groups` claim.
- Authentik groups `k8s-admins`, `k8s-viewers` with membership.
- NetBird access policy permitting the sidecar peer group → `authentik.infra:443`.
- Confirm `authentik.infra`'s serving cert chains to the Fluence Mesh Root (for `--oidc-ca-file`).

## Verification (after Flux rollout)

```bash
# proxy reaches Authentik discovery via the sidecar
kubectl -n kube-oidc-proxy exec deploy/kube-oidc-proxy -c netbird -- \
  wget -qO- https://authentik.infra/application/o/<slug>/.well-known/openid-configuration | head

# served cert chains to the Fluence Mesh Root
openssl s_client -connect k8s.<id>.<net>.spectrum:443 -servername k8s.<id>.<net>.spectrum </dev/null

# RBAC: admin can write, viewer is read-only
kubectl get ns          # k8s-admins → OK ; k8s-viewers → OK (read)
kubectl create ns probe # k8s-admins → OK ; k8s-viewers → Forbidden
```
