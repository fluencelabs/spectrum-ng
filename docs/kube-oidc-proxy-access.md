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

The proxy pod reaches the mesh-only `authentik.infra` (for OIDC discovery/JWKS) via a NetBird sidecar
that the **netbird-operator (≥0.3.x) auto-injects** from the pod annotation `netbird.io/setup-key`.
The sidecar runs as root, brings up WireGuard and rewrites the pod's shared `/etc/resolv.conf` — no
dnsConfig or hand-rolled sidecar. This mirrors the Grafana OIDC back-channel (PR #142).

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
          - --oidc-extra-scope=groups
```

> The central Authentik has a `groups` scope mapping (Grafana and Vault use it), so request
> `groups` — the proxy's `--oidc-groups-claim=groups` reads it from the id_token. First `kubectl`
> call opens a browser to `authentik.infra`; kubelogin caches the token.

## Required per-cluster Flux vars (spectrum-manual-vars ConfigMap)

| Var | Example | Purpose |
|---|---|---|
| `KUBE_OIDC_SLUG` | `spectrum-kube-stage` | Authentik application slug → issuer path. Matches the infra TF app slug `spectrum-kube-<network>`. |
| `KUBE_OIDC_CLIENT_ID` | `<uuid>` | Authentik OIDC client id (public client). Copy from Vault `security/authentik-oidc/spectrum-kube-<network>`. |

> ⚠️ **Both keys MUST be present before this app reconciles.** Flux substitutes undefined vars with an
> empty string (no build error), so a missing `KUBE_OIDC_CLIENT_ID` yields an empty `--oidc-client-id`
> and OIDC discovery fails silently at pod startup. The in-manifest default `KUBE_OIDC_SLUG:=kube` is
> only a fallback — set it explicitly to `spectrum-kube-<network>`.

## Bootstrap secret (out-of-band, NOT in git)

> ⚠️ **First-reconcile ordering.** This app creates the `kube-oidc-proxy` namespace, but it also
> consumes the secret below in that namespace. On a fresh cluster, create the namespace and apply it
> *before/at* first Flux reconcile (`kubectl create namespace kube-oidc-proxy` then apply the secret),
> otherwise the Issuer/cert and pod stay pending until you do and Flux re-reconciles.

| Secret | Keys | Purpose |
|---|---|---|
| `fluence-mesh-intermediate` | `tls.crt`, `tls.key`, `ca.crt` | Per-cluster intermediate CA backing the `fluence-intermediate` Issuer (same hand-delivery as the Grafana namespace). Its **`ca.crt` is the Fluence Mesh Root** and is also mounted as the proxy's `--oidc-ca-file` to verify `authentik.infra` — no separate CA secret. |

> The NetBird **setup key is auto-minted** by the netbird-operator (`SetupKey` CR in
> `netbird-setupkey.yml`) — nothing hand-delivered. The sidecar is auto-injected via the
> `netbird.io/setup-key` pod annotation.

## Infra-side (provisioned as code — `terraform apply` by the infra owner)

The Authentik app + groups are defined in **`infra/infrahub/terraform/authentik/spectrum_kube_oidc.tf`**
(mirrors the spectrum-grafana app): public client + PKCE, slug `spectrum-kube-<network>`, mesh login
flow `authentik-infra-authentication`, redirects `http://localhost:{8000,18000}`, scopes
`openid profile email groups`, access groups `k8s-admins`/`k8s-viewers` (GitHub-team-backed via
`local_group_mappings`: `devops`/`devs`). After `terraform apply`:

1. Copy `client_id` from Vault `security/authentik-oidc/spectrum-kube-<network>` →
   `spectrum-manual-vars` `KUBE_OIDC_CLIENT_ID`; set `KUBE_OIDC_SLUG=spectrum-kube-<network>`.
   (Public client → no `client_secret` to copy.)
2. NetBird needs no extra policy — `authentik.infra`'s NBResource source group is `All`.

> NetBird: no extra policy needed — `authentik.infra`'s NBResource policy source group is `All`, so
> the auto-injected sidecar peer can reach it out of the box (same as Grafana's back-channel).
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
  --oidc-client-id=<client_id> --oidc-use-pkce \
  --oidc-extra-scope=profile --oidc-extra-scope=email --oidc-extra-scope=groups \
  | jq -r .status.token | cut -d. -f2 | base64 -d 2>/dev/null | jq '{groups, preferred_username}'

# 5. RBAC: admin can write, viewer is read-only
kubectl get ns          # oidc:k8s-admins → OK ; oidc:k8s-viewers → OK (read)
kubectl create ns probe # oidc:k8s-admins → OK ; oidc:k8s-viewers → Forbidden
```
