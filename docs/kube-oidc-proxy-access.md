# kube-oidc-proxy — operator access

Authenticated `kubectl` access to the beam cluster API via Authentik SSO, over the NetBird mesh.
Analogous to Grafana at `https://grafana.<cluster_id>.<network>.spectrum`.

## How it works

```
kubectl → oidc-login (browser auth-code + PKCE → Authentik on authentik.infra) → ID token
  → https://k8s.<cluster_id>.<network>.spectrum   (NetBird mesh, Fluence leaf cert)
    → kube-oidc-proxy: validates iss/aud/signature, reads username + groups,
      prefixes them with "oidc:" and sets Impersonate-User / Impersonate-Group
      → real kube-apiserver
        → RBAC: group oidc:k8s-admins → cluster-admin, oidc:k8s-viewers → view
```

The apiserver itself is owned by **beam** and is not OIDC-configured; the proxy does impersonation,
so no apiserver flags are required.

> **Security note — the `oidc:` prefix is load-bearing.** The proxy runs with
> `--oidc-username-prefix=oidc:` / `--oidc-groups-prefix=oidc:`, so every OIDC identity is namespaced
> and an Authentik group named e.g. `system:masters` arrives as the inert `oidc:system:masters`.
> The RBAC subjects (`oidc:k8s-admins`/`oidc:k8s-viewers`), the prefix flags, and the
> `resourceNames` allowlist in `rbac-proxy.yml` are coupled — change them together.

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
          - --oidc-extra-scope=profile
          - --oidc-extra-scope=email
```

> Do **not** add `--oidc-extra-scope=groups`: Authentik has no default scope named `groups`. The
> `groups` claim (and `preferred_username`) are delivered by the default **`profile`** scope mapping
> — see the infra checklist. First `kubectl` call opens a browser to `authentik.infra`; kubelogin
> caches the token.

## Required per-cluster Flux vars (spectrum-manual-vars ConfigMap)

| Var | Example | Purpose |
|---|---|---|
| `KUBE_OIDC_SLUG` | `kube` | Authentik application slug → issuer path (defaults to `kube` in-manifest) |
| `KUBE_OIDC_CLIENT_ID` | `<uuid>` | Authentik OIDC client id (public client) |

> ⚠️ **Both keys MUST be present before this app reconciles.** Flux substitutes undefined vars with an
> empty string (no build error), so a missing `KUBE_OIDC_CLIENT_ID` yields an empty `--oidc-client-id`
> and OIDC discovery fails silently at pod startup. `KUBE_OIDC_SLUG` has an in-manifest default
> (`kube`); `KUBE_OIDC_CLIENT_ID` does not.

## Bootstrap secrets (out-of-band, NOT in git)

> ⚠️ **First-reconcile ordering.** This app creates the `kube-oidc-proxy` namespace, but it also
> consumes three hand-delivered secrets in that namespace. On a fresh cluster, create the namespace
> and apply these secrets *before/at* first Flux reconcile (`kubectl create namespace kube-oidc-proxy`
> then apply the secrets), otherwise the Issuer/cert and pods stay pending until you do and Flux
> re-reconciles.

| Secret | Keys | Purpose |
|---|---|---|
| `fluence-mesh-intermediate` | `tls.crt`, `tls.key` | Per-cluster intermediate CA backing the `fluence-intermediate` Issuer (same hand-delivery as the Grafana namespace) |
| `kube-oidc-proxy-authentik-ca` | `ca.crt` | Fluence Mesh Root, used by the proxy to verify `authentik.infra`'s served cert (`--oidc-ca-file`) |
| `kube-oidc-proxy-netbird-setupkey` | `NB_SETUP_KEY` | NetBird setup key for the sidecar peer — mint it **reusable + ephemeral** with **auto-assigned group `spectrum-${NETWORK}`** (ephemeral peers are auto-reaped after ~10 min offline, avoiding peer churn from emptyDir state; the group is what the `authentik.infra:443` policy authorizes — the deployment cannot set it) |

## Infra-side checklist (Authentik / NetBird — done by the infra owner)

- Authentik application + OIDC provider for kube-oidc-proxy:
  - **public client + PKCE** (no client secret),
  - redirect URIs (kubelogin defaults): `http://localhost:8000` **and** `http://localhost:18000`
    (host is `localhost`, both ports — the second is kubelogin's fallback when 8000 is busy),
  - issuer host `authentik.infra`,
  - **Selected scopes include the default `profile` mapping** (it emits
    `"groups": [group.name …]` and `preferred_username`),
  - **enable "Include claims in id_token"** (Advanced protocol settings) — without it the `groups`
    and `preferred_username` claims go only to userinfo/access_token, which kube-oidc-proxy never
    reads (it validates the id_token). This is the silent authenticated-but-Forbidden failure mode.
- Authentik groups `k8s-admins`, `k8s-viewers` with membership (the proxy prefixes them to
  `oidc:k8s-admins` / `oidc:k8s-viewers` for RBAC).
- NetBird access policy permitting the sidecar peer group (`spectrum-${NETWORK}`) → `authentik.infra:443`.
- Confirm `authentik.infra`'s serving cert chains to the Fluence Mesh Root (for `--oidc-ca-file`).
- Confirm beam runs **Talos ≥ 1.8** (the netbird sidecar mounts `/dev/net/tun`; the runc 1.2.0–1.2.3
  TUN regression does not apply on ≥ 1.8 / runc ≥ 1.2.4).

## Verification (after Flux rollout)

```bash
# 1. The PROXY container (not the sidecar) must resolve authentik.infra — this is the DNS path the
#    proxy actually uses; testing from the netbird container would give a false green.
kubectl -n kube-oidc-proxy exec deploy/kube-oidc-proxy -c proxy -- getent hosts authentik.infra

# 2. Proxy became Ready (it only latches ready after OIDC discovery via the mesh succeeds)
kubectl -n kube-oidc-proxy get deploy kube-oidc-proxy

# 3. Served cert chains to the Fluence Mesh Root
openssl s_client -connect k8s.<id>.<net>.spectrum:443 -servername k8s.<id>.<net>.spectrum </dev/null

# 4. The id_token actually carries groups + preferred_username (catches the missing-claim case that
#    RBAC smoke tests cannot distinguish from an RBAC misconfig)
kubectl oidc-login get-token --oidc-issuer-url=https://authentik.infra/application/o/<slug>/ \
  --oidc-client-id=<client_id> --oidc-use-pkce --oidc-extra-scope=profile --oidc-extra-scope=email \
  | jq -r .status.token | cut -d. -f2 | base64 -d 2>/dev/null | jq '{groups, preferred_username}'

# 5. RBAC: admin can write, viewer is read-only
kubectl get ns          # oidc:k8s-admins → OK ; oidc:k8s-viewers → OK (read)
kubectl create ns probe # oidc:k8s-admins → OK ; oidc:k8s-viewers → Forbidden
```
