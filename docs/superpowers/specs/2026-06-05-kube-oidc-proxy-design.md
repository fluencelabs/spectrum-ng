# kube-oidc-proxy — OIDC access to the beam cluster API

**Date:** 2026-06-05
**Status:** Draft (design approved in brainstorming; pending spec review)
**Author:** Nick

## 1. Summary

Give operators authenticated `kubectl` access to the beam Kubernetes cluster API
using their Authentik identity, exposed over the NetBird mesh — analogous to how
Grafana is reached at `https://grafana.${CLUSTER_ID}.${NETWORK}.spectrum`.

Because the kube-apiserver and Talos machine config are owned by **beam** (not this
repo), we cannot add native `--oidc-*` apiserver flags. Instead we deploy
[`kube-oidc-proxy`](https://github.com/jetstack/kube-oidc-proxy) (Tremolo Security
maintained fork) as an in-cluster reverse proxy: it validates Authentik OIDC tokens
itself and **impersonates** the user + groups to the real apiserver. No apiserver
changes required.

## 2. Goals / Non-goals

**Goals**
- `kubectl` access via Authentik SSO, no static kubeconfig credentials.
- Two RBAC tiers driven by Authentik groups: `k8s-admins` → `cluster-admin`,
  `k8s-viewers` → `view`.
- Mesh-only endpoint `k8s.${CLUSTER_ID}.${NETWORK}.spectrum`, served with a Fluence
  mesh leaf cert (laptops already trust the Fluence Mesh Root from the Grafana work).
- Ship via Flux, parameterized by `${CLUSTER_ID}`/`${NETWORK}`, **stage network first**.

**Non-goals**
- Modifying the kube-apiserver / Talos config (owned by beam).
- Creating the Authentik application/provider (done out-of-band on infra by Nick;
  this repo only consumes issuer + client_id).
- testnet / mainnet rollout (follow-up once stage is validated).
- Editing the `infra` repo from this session (suggest infra-side changes only).

## 3. Background & constraints

- **beam owns the apiserver.** spectrum-ng is Flux-only; apiserver-level auth must be
  delivered as an in-cluster workload. → impersonation proxy.
- **Grafana is the template.** The mesh hostname, Fluence intermediate Issuer + leaf
  Certificate, `ExternalName` Service with `netbird.io/*` annotations, and the
  `NBResource`-setup Job all already exist for Grafana
  (`flux/apps/observability/grafana/app/`, `flux/apps/networking/netbird-services/app/grafana/`).
  We mirror them.
- **Authentik host split & QUIC.** Grafana dodges the Authentik HTTP3/QUIC edge bug by
  sending the browser leg to the mesh-only host `authentik.infra` while keeping
  server-side token/userinfo calls on the public `authentik.cloudless.dev`. Grafana can
  do this because it overrides each OIDC endpoint independently.
- **kubelogin cannot split endpoints.** `kubectl oidc-login` (int128/kubelogin) derives
  *all* endpoints from one `--oidc-issuer-url` discovery document, and `kube-oidc-proxy`
  must validate the token `iss` against an issuer it can fetch JWKS for. We therefore
  pick a single issuer host (decision below).
- **Image maintenance.** jetstack/kube-oidc-proxy was archived 2024-05; use the Tremolo
  Security maintained fork image, pinned by digest.

## 4. Decisions

| Topic | Decision |
|---|---|
| Mechanism | `kube-oidc-proxy` (impersonation), Tremolo fork image, pinned digest |
| Client tooling | `kubectl oidc-login` (int128/kubelogin), **public client + PKCE** (no client secret anywhere) |
| RBAC tiers | `k8s-admins` → `cluster-admin`; `k8s-viewers` → `view` |
| Hostname | `k8s.${CLUSTER_ID}.${NETWORK}.spectrum` |
| Scope | stage network first |
| OIDC issuer host | **`authentik.infra`** (mesh) — clean browser leg, no QUIC |
| Proxy → JWKS reachability | **NetBird sidecar** on the proxy pod (joins `spectrum-${NETWORK}`, reaches `authentik.infra` directly) |
| Flux location | `flux/apps/networking/kube-oidc-proxy/` (workload) + `flux/apps/networking/netbird-services/app/kube-oidc-proxy/` (mesh exposure) |

## 5. Architecture & data flow

```
kubectl
  │  exec: kubectl oidc-login (browser auth-code + PKCE)
  │        issuer = https://authentik.infra/application/o/<slug>/   (mesh, no QUIC)
  ▼
[ Authentik ]  ── ID token (iss=authentik.infra, aud=<client_id>, groups=[…]) ──▶ kubectl
  │
  ▼  https://k8s.${CLUSTER_ID}.${NETWORK}.spectrum   (NetBird mesh, Fluence leaf cert)
[ kube-oidc-proxy pod ]
  │   ├─ main container: validate iss/aud/signature; read username + groups
  │   │     sets Impersonate-User / Impersonate-Group headers
  │   └─ netbird sidecar: joins spectrum-${NETWORK}; resolves & reaches
  │         authentik.infra for discovery/JWKS
  ▼  in-cluster, as its ServiceAccount (impersonate RBAC)
[ real kube-apiserver ]
  ▼
RBAC evaluates the impersonated identity (k8s-admins → cluster-admin, etc.)
```

## 6. Components

### A. Workload app — `flux/apps/networking/kube-oidc-proxy/`

```
kube-oidc-proxy/
  ks.yml                     # Flux Kustomization, postBuild substituteFrom spectrum-vars
  kustomization.yml
  app/
    kustomization.yml
    namespace.yml            # ns: kube-oidc-proxy
    deployment.yml           # proxy + netbird sidecar
    serviceaccount.yml       # SA + impersonate ClusterRole/ClusterRoleBinding
    service.yml              # ClusterIP :443 -> targetPort (proxy secure port)
    fluence-intermediate-issuer.yml   # copied from grafana
    tls-cert.yml             # leaf for k8s.${CLUSTER_ID}.${NETWORK}.spectrum
    rbac-users.yml           # k8s-admins -> cluster-admin, k8s-viewers -> view
```

- **Deployment** — two containers:
  - `proxy`: Tremolo `kube-oidc-proxy` (pinned digest). Key args:
    - `--oidc-issuer-url=https://authentik.infra/application/o/<slug>/`
    - `--oidc-client-id=${KUBE_OIDC_CLIENT_ID}`
    - `--oidc-username-claim=preferred_username`
    - `--oidc-groups-claim=groups`
    - `--secure-port=443`
    - `--tls-cert-file`/`--tls-private-key-file` → mounted `kube-oidc-proxy-tls`
    - `--oidc-ca-file` → Fluence Mesh Root, if `authentik.infra` is served with a
      Fluence-chain cert (TBD — confirm authentik.infra's serving CA).
    - readiness/liveness on `/ready`. Hardened securityContext copied from Grafana
      (runAsNonRoot, drop ALL caps, no privilege escalation).
  - `netbird` sidecar (see §8).
- **ServiceAccount + ClusterRole + ClusterRoleBinding**: grant the proxy SA
  `impersonate` on `users` and `groups` (and `userextras`/`uids` as required by the
  fork). This is the proxy's own privilege; end-user privilege is §C.
- **Service**: ClusterIP, port 443 → proxy secure port. Referenced by the mesh
  `ExternalName` in §D.

### B. TLS (mesh leaf)

Copied verbatim from `grafana-tls-cert.yml` + `fluence-intermediate-issuer.yml`, with
the namespace changed to `kube-oidc-proxy` and:
- `commonName` / `dnsNames`: `k8s.${CLUSTER_ID}.${NETWORK}.spectrum`
- `secretName`: `kube-oidc-proxy-tls`
- `issuerRef`: `fluence-intermediate` (CA Issuer backed by the hand-delivered
  `fluence-mesh-intermediate` secret — see §9).

### C. End-user RBAC — `rbac-users.yml`

Two `ClusterRoleBinding`s binding **group** subjects (impersonated groups arrive as
`Impersonate-Group`):
- `k8s-admins` → ClusterRole `cluster-admin`
- `k8s-viewers` → ClusterRole `view`

No prefix on usernames/groups initially (Authentik controls the `groups` claim, so the
values aren't user-forgeable). See §7 for the `system:` hardening note.

### D. Mesh exposure — `flux/apps/networking/netbird-services/app/kube-oidc-proxy/`

Mirror the Grafana pair:
- `service.yml`: `ExternalName` → `kube-oidc-proxy.kube-oidc-proxy.svc.cluster.local`,
  annotations: `netbird.io/expose`, `resource-name: k8s.${CLUSTER_ID}.${NETWORK}`,
  `groups: spectrum-${NETWORK}`, `policy-name: k8s-access`,
  `policy-source-groups: support,admins`, `policy-protocol: tcp`, `policy-ports: 443`.
- `resource-setup.yml`: Job (same SA/Role pattern as Grafana) that reads the network ID
  from the `router` NBRoutingPeer and applies an `NBResource` with
  `address: k8s.${CLUSTER_ID}.${NETWORK}.spectrum`, `groups: spectrum-${NETWORK}`.
- `kustomization.yml`; register under `netbird-services` parent.

### E. Flux wiring

- `kube-oidc-proxy/ks.yml`: `targetNamespace: kube-oidc-proxy`, `postBuild.substituteFrom`
  `spectrum-vars` (+ manual vars/secrets, optional), `dependsOn: cert-manager`.
- Register the new app `ks.yml`(s) in the networking-area kustomization
  (`flux/apps/networking/kustomization.yml`) and the netbird-services overlay.

### F. Client docs (not applied to cluster)

A documented kubeconfig template:
- `clusters[].cluster.server: https://k8s.<id>.<net>.spectrum`
- `clusters[].cluster.certificate-authority`: Fluence Mesh Root (already trusted from
  the Grafana rollout)
- `users[].user.exec`: `kubectl oidc-login get-token` with
  `--oidc-issuer-url=https://authentik.infra/application/o/<slug>/`,
  `--oidc-client-id=<client>`, `--oidc-use-pkce`, `--oidc-extra-scope=groups`.
- Prereq: operator laptop on NetBird mesh (resolves `authentik.infra` and
  `k8s.<id>.<net>.spectrum`).

## 7. Security considerations

- **Impersonation blast radius.** The proxy SA can impersonate any user/group. Protect
  the pod (no shell access, hardened securityContext) and keep the impersonate
  ClusterRole scoped to `users`/`groups` only.
- **`system:` escalation.** Ensure the proxy/authenticator rejects tokens whose
  `groups`/username resolve to `system:masters` / `system:*`. If the fork doesn't guard
  this by default, add `--oidc-username-prefix` / `--oidc-groups-prefix` (e.g. `oidc:`)
  and bind RBAC to the prefixed names instead. **Resolve during planning.**
- **Audience pinning.** `--oidc-client-id` must equal the token `aud`; kubelogin requests
  tokens for that same client.
- **Public client + PKCE.** No client secret stored in this repo or in user kubeconfigs.
- **NetBird access policy.** The sidecar peer's group must be allowed to reach
  `authentik.infra:443` by NetBird policy (managed on the infra/Authentik side).

## 8. NetBird sidecar (proxy → authentik.infra)

- Image: `netbirdio/netbird` client, `NB_MANAGEMENT_URL=https://netbird.infrahub.cloudless.dev`.
- Joins group `spectrum-${NETWORK}` so it can resolve and reach `authentik.infra`.
- Setup-key provisioning — **open implementation choice** (resolve in planning):
  1. Bootstrap secret `kube-oidc-proxy-netbird-setupkey` (hand-delivered, like
     `netbird-api-token`), or
  2. A setup Job that mints an ephemeral/reusable setup key via the NetBird API
     (`netbird-api-token`) and writes it to a Secret the sidecar consumes — keeps it
     self-contained, mirrors `netbird-setup` Job style.
- Sidecar lifecycle: shares the pod; the proxy should not report ready until the mesh
  interface is up and `authentik.infra` resolves (ordering / startup probe — resolve in
  planning). NetBird peer cleanup follows the operator's model; do **not** force-remove
  NetBird CR finalizers.

## 9. Bootstrap prerequisites (out-of-band, not in git)

- `fluence-mesh-intermediate` (cert+key) present in the `kube-oidc-proxy` namespace
  (same hand-delivery as the Grafana namespace) — backs the `fluence-intermediate` Issuer.
- NetBird sidecar setup key (per §8 choice).
- **Infra-side (Nick, suggested — not edited here):**
  - Authentik application/provider for kube-oidc-proxy (public client + PKCE), emitting
    `groups`; note the `<slug>` / issuer + client_id.
  - Authentik groups `k8s-admins`, `k8s-viewers` (and membership).
  - NetBird access policy permitting the sidecar peer group → `authentik.infra:443`.
  - Confirm `authentik.infra`'s serving CA (Fluence chain?) to set `--oidc-ca-file`.

## 10. Open items to resolve in planning

1. Confirm Tremolo fork image, tag/digest, and exact flag set (claims, prefixes,
   `system:` guard, CA file).
2. `system:` escalation guard → prefix or built-in rejection (§7).
3. NetBird setup-key provisioning method (§8).
4. Sidecar/proxy startup ordering & readiness gating (§8).
5. `authentik.infra` serving CA for `--oidc-ca-file` (§9).

## 11. Testing & verification

- **Flux dry-run / kustomize build** for both app and netbird-services overlays.
- **TLS:** `openssl s_client` to `k8s.<id>.<net>.spectrum` from a mesh laptop chains to
  Fluence Mesh Root.
- **Sidecar reachability:** from the proxy pod's sidecar, resolve + curl
  `authentik.infra/.well-known/openid-configuration`.
- **Happy path:** `kubectl --kubeconfig <template> get ns` as a `k8s-admins` member →
  succeeds; as a `k8s-viewers` member → read works, write denied (RBAC `view`).
- **Negative:** no/expired token → 401 at the proxy; user with no mapped group →
  authenticated but RBAC-forbidden.
- **Audit:** apiserver audit log shows the impersonated username/groups, not the proxy SA.

## 12. Rollout

1. Land stage config; verify end-to-end on the stage cluster referenced by
   `grafana.7b0c4ed4-4a1c-4ebb-85a4-28ca3e473684.stage.spectrum`.
2. Once validated, extend to testnet/mainnet (config already `${NETWORK}`-parameterized;
   re-create Authentik app/groups + bootstrap secrets per network).

## 13. References

- Grafana OIDC work: commit `b33e8bd` (feat: Grafana OIDC login via Authentik, #140).
- kube-oidc-proxy: https://github.com/jetstack/kube-oidc-proxy (archived; Tremolo fork
  maintained).
- kubelogin: https://github.com/int128/kubelogin
- Related notes: [[Fluencelabs Spectrum-NG]], [[Authentik HTTP3 Flakiness]],
  [[NetBird Finalizer Handling]].
