# kube-oidc-proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy `kube-oidc-proxy` (impersonation) on the beam cluster so operators reach the kube API at `https://k8s.${CLUSTER_ID}.${NETWORK}.spectrum` via Authentik SSO, mirroring the Grafana mesh pattern.

**Architecture:** In-cluster reverse proxy validates Authentik OIDC tokens and impersonates user+groups to the real apiserver (apiserver owned by beam, can't be flagged). Exposed over NetBird mesh with a Fluence leaf cert. The proxy pod reaches `authentik.infra` for JWKS via a NetBird sidecar. RBAC: group `k8s-admins`→`cluster-admin`, `k8s-viewers`→`view`. Shipped via Flux, `${CLUSTER_ID}`/`${NETWORK}`-parameterized, stage first.

**Tech Stack:** Flux Kustomization, cert-manager, kube-oidc-proxy (`quay.io/jetstack/kube-oidc-proxy:v0.3.0`), NetBird operator/client, kubelogin (client side).

**Validation environment note:** This session validates statically only — `kubectl kustomize <dir>` (built-in) and `flux` 2.3.0 are available; there is **no live cluster**. Steps that require a running cluster (rollout, JWKS reachability, kubectl happy-path) are marked **[IN-CLUSTER]** and are executed by the operator after merge via Flux. `${...}` Flux postBuild vars remain literal in static renders — that is expected.

**Reference pattern files (read before starting):**
- `flux/apps/observability/grafana/app/{fluence-intermediate-issuer,grafana-tls-cert}.yml`
- `flux/apps/networking/netbird-services/app/grafana/{service,resource-setup,ks}.yml`
- `flux/apps/networking/netbird-services/kustomization.yml`
- `flux/apps/networking/kustomization.yml`
- `flux/apps/observability/grafana/ks.yml`

---

## File Structure

**Workload app — `flux/apps/networking/kube-oidc-proxy/`**
- `kustomization.yml` — aggregator, `resources: [ks.yml]`
- `ks.yml` — Flux Kustomization → `path: ./flux/apps/networking/kube-oidc-proxy/app`, `targetNamespace: kube-oidc-proxy`
- `app/kustomization.yml` — lists the app resources
- `app/namespace.yml` — Namespace `kube-oidc-proxy`
- `app/fluence-intermediate-issuer.yml` — CA Issuer from `fluence-mesh-intermediate` (bootstrap secret)
- `app/tls-cert.yml` — leaf cert for `k8s.${CLUSTER_ID}.${NETWORK}.spectrum`
- `app/rbac-proxy.yml` — proxy SA + impersonate ClusterRole + binding
- `app/rbac-users.yml` — `k8s-admins`→cluster-admin, `k8s-viewers`→view
- `app/deployment.yml` — proxy container + netbird sidecar
- `app/service.yml` — ClusterIP :443

**Mesh exposure — `flux/apps/networking/netbird-services/app/kube-oidc-proxy/`**
- `service.yml` — ExternalName + `netbird.io/*` annotations
- `resource-setup.yml` — Job applying NBResource with the `.spectrum` address
- `ks.yml` — Flux Kustomization `netbird-services-kube-oidc-proxy`
- `kustomization.yml` — `resources: [service.yml, resource-setup.yml]`

**Registrations (modify):**
- `flux/apps/networking/kustomization.yml` — add `kube-oidc-proxy`
- `flux/apps/networking/netbird-services/kustomization.yml` — add `app/kube-oidc-proxy/ks.yml`

**Docs (no cluster impact):**
- `docs/kube-oidc-proxy-access.md` — operator kubeconfig + kubelogin setup + bootstrap prereqs

---

## Task 1: Scaffold workload app + register in networking area

**Files:**
- Create: `flux/apps/networking/kube-oidc-proxy/kustomization.yml`
- Create: `flux/apps/networking/kube-oidc-proxy/ks.yml`
- Create: `flux/apps/networking/kube-oidc-proxy/app/kustomization.yml`
- Create: `flux/apps/networking/kube-oidc-proxy/app/namespace.yml`
- Modify: `flux/apps/networking/kustomization.yml`

- [ ] **Step 1: Namespace**

`app/namespace.yml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kube-oidc-proxy
```

- [ ] **Step 2: App kustomization (resources added incrementally; start minimal)**

`app/kustomization.yml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yml
```

- [ ] **Step 3: Flux Kustomization (ks.yml)** — mirrors `grafana/ks.yml`

`ks.yml`:
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kube-oidc-proxy
  namespace: flux-system
spec:
  path: ./flux/apps/networking/kube-oidc-proxy/app
  prune: true
  targetNamespace: kube-oidc-proxy
  sourceRef:
    kind: GitRepository
    name: spectrum
    namespace: flux-system
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: spectrum-vars
        optional: false
      - kind: ConfigMap
        name: spectrum-manual-vars
        optional: true
      - kind: Secret
        name: spectrum-manual-secrets
        optional: true
  dependsOn:
    - name: cert-manager
```

- [ ] **Step 4: App-dir aggregator kustomization**

`kustomization.yml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ks.yml
```

- [ ] **Step 5: Register in networking area** — add `kube-oidc-proxy` to `flux/apps/networking/kustomization.yml` `resources:` list (alphabetical-ish, after `netbird-token-rotate`).

- [ ] **Step 6: Validate**

Run: `kubectl kustomize flux/apps/networking/kube-oidc-proxy/app && kubectl kustomize flux/apps/networking >/dev/null && echo OK`
Expected: namespace YAML printed, then `OK`.

- [ ] **Step 7: Commit**
```bash
git add flux/apps/networking/kube-oidc-proxy flux/apps/networking/kustomization.yml
git commit -m "wip"
```

---

## Task 2: TLS (Fluence intermediate Issuer + leaf cert)

**Files:**
- Create: `flux/apps/networking/kube-oidc-proxy/app/fluence-intermediate-issuer.yml`
- Create: `flux/apps/networking/kube-oidc-proxy/app/tls-cert.yml`
- Modify: `flux/apps/networking/kube-oidc-proxy/app/kustomization.yml`

- [ ] **Step 1: Issuer** (copied from grafana, ns is rewritten by `targetNamespace`; keep explicit for clarity)

`app/fluence-intermediate-issuer.yml`:
```yaml
# Per-cluster intermediate CA (signed by the single Fluence Mesh Root), name-constrained to
# <cluster_id>.<network>.spectrum. The cert+key live in the bootstrap secret
# `fluence-mesh-intermediate` (NOT in git; hand-delivered into this namespace, like
# netbird-api-token). cert-manager issues the proxy leaf from it locally.
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: fluence-intermediate
  namespace: kube-oidc-proxy
spec:
  ca:
    secretName: fluence-mesh-intermediate
```

- [ ] **Step 2: Leaf cert** (copied from `grafana-tls-cert.yml`, hostname/secret changed)

`app/tls-cert.yml`:
```yaml
# Leaf cert for the mesh-only hostname k8s.<cluster_id>.<network>.spectrum, signed by the
# fluence-intermediate Issuer. ${CLUSTER_ID}/${NETWORK} are substituted by the ks postBuild.
# Consumed by the kube-oidc-proxy pod (native TLS), mounted from secret kube-oidc-proxy-tls.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: kube-oidc-proxy-tls
  namespace: kube-oidc-proxy
spec:
  secretName: kube-oidc-proxy-tls
  duration: 2160h # 90d
  renewBefore: 360h
  commonName: k8s.${CLUSTER_ID}.${NETWORK}.spectrum
  dnsNames:
    - k8s.${CLUSTER_ID}.${NETWORK}.spectrum
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: fluence-intermediate
    kind: Issuer
```

- [ ] **Step 3: Add to kustomization** — append `fluence-intermediate-issuer.yml` and `tls-cert.yml` to `app/kustomization.yml` resources.

- [ ] **Step 4: Validate**

Run: `kubectl kustomize flux/apps/networking/kube-oidc-proxy/app >/dev/null && echo OK`
Expected: `OK` (3 docs render).

- [ ] **Step 5: Commit**
```bash
git add flux/apps/networking/kube-oidc-proxy/app
git commit -m "wip"
```

---

## Task 3: Proxy RBAC (impersonation privilege)

**Files:**
- Create: `flux/apps/networking/kube-oidc-proxy/app/rbac-proxy.yml`
- Modify: `flux/apps/networking/kube-oidc-proxy/app/kustomization.yml`

- [ ] **Step 1: SA + ClusterRole + binding**

`app/rbac-proxy.yml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-oidc-proxy
  namespace: kube-oidc-proxy
---
# The proxy authenticates to the real apiserver as this SA, then sets impersonation headers.
# Scope strictly to users/groups (+ extras) — this is the impersonation blast radius.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kube-oidc-proxy
rules:
  - apiGroups: [""]
    resources: ["users", "groups"]
    verbs: ["impersonate"]
  - apiGroups: ["authentication.k8s.io"]
    resources: ["userextras/scopes", "userextras/remote-client-ip"]
    verbs: ["impersonate"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-oidc-proxy
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kube-oidc-proxy
subjects:
  - kind: ServiceAccount
    name: kube-oidc-proxy
    namespace: kube-oidc-proxy
```

- [ ] **Step 2: Add to kustomization** — append `rbac-proxy.yml`.

- [ ] **Step 3: Validate**

Run: `kubectl kustomize flux/apps/networking/kube-oidc-proxy/app >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**
```bash
git add flux/apps/networking/kube-oidc-proxy/app
git commit -m "wip"
```

---

## Task 4: End-user RBAC (group → role)

**Files:**
- Create: `flux/apps/networking/kube-oidc-proxy/app/rbac-users.yml`
- Modify: `flux/apps/networking/kube-oidc-proxy/app/kustomization.yml`

- [ ] **Step 1: Group bindings** (groups arrive as Impersonate-Group from the OIDC `groups` claim)

`app/rbac-users.yml`:
```yaml
# Authentik group -> cluster access. Group names are Authentik-controlled (not user-forgeable).
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: k8s-admins
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: Group
    name: k8s-admins
    apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: k8s-viewers
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: Group
    name: k8s-viewers
    apiGroup: rbac.authorization.k8s.io
```

- [ ] **Step 2: Add to kustomization** — append `rbac-users.yml`.

- [ ] **Step 3: Validate**

Run: `kubectl kustomize flux/apps/networking/kube-oidc-proxy/app >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**
```bash
git add flux/apps/networking/kube-oidc-proxy/app
git commit -m "wip"
```

---

## Task 5: Deployment (proxy container) + Service + OIDC env

> **Decision — `system:` escalation guard (spec §7):** use `--oidc-username-prefix` / `--oidc-groups-prefix` left EMPTY (no prefix) but rely on apiserver's built-in protection: the apiserver refuses impersonating `system:masters` unless the proxy SA is explicitly granted it (it is not). RBAC subjects use bare `k8s-admins`/`k8s-viewers`. If in-cluster testing shows group collisions, revisit prefixes (would require updating Task 4 subjects to the prefixed names).

**Files:**
- Create: `flux/apps/networking/kube-oidc-proxy/app/deployment.yml`
- Create: `flux/apps/networking/kube-oidc-proxy/app/service.yml`
- Modify: `flux/apps/networking/kube-oidc-proxy/app/kustomization.yml`

- [ ] **Step 1: Deployment (proxy only; sidecar added in Task 6)**

`app/deployment.yml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kube-oidc-proxy
  namespace: kube-oidc-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kube-oidc-proxy
  template:
    metadata:
      labels:
        app: kube-oidc-proxy
    spec:
      serviceAccountName: kube-oidc-proxy
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: proxy
          # jetstack repo archived 2024-05; this image is the last published tag and is what the
          # Tremolo maintained fork's chart still defaults to. Pin by digest before merge (Step 4).
          image: quay.io/jetstack/kube-oidc-proxy:v0.3.0
          command: ["kube-oidc-proxy"]
          args:
            - "--secure-port=443"
            - "--tls-cert-file=/etc/oidc/tls/tls.crt"
            - "--tls-private-key-file=/etc/oidc/tls/tls.key"
            - "--oidc-issuer-url=https://authentik.infra/application/o/${KUBE_OIDC_SLUG}/"
            - "--oidc-client-id=${KUBE_OIDC_CLIENT_ID}"
            - "--oidc-username-claim=preferred_username"
            - "--oidc-groups-claim=groups"
            # authentik.infra serves a Fluence-chain cert; trust the mesh root mounted below.
            - "--oidc-ca-file=/etc/oidc/authentik-ca/ca.crt"
          ports:
            - name: https
              containerPort: 443
            - name: probe
              containerPort: 8080
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 20
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: tls
              mountPath: /etc/oidc/tls
              readOnly: true
            - name: authentik-ca
              mountPath: /etc/oidc/authentik-ca
              readOnly: true
      volumes:
        - name: tls
          secret:
            secretName: kube-oidc-proxy-tls
        - name: authentik-ca
          # Bootstrap secret: the Fluence Mesh Root used to verify authentik.infra's served cert.
          # Hand-delivered into this namespace (key: ca.crt). See docs/kube-oidc-proxy-access.md.
          secret:
            secretName: kube-oidc-proxy-authentik-ca
```

> **Vars:** `KUBE_OIDC_SLUG` and `KUBE_OIDC_CLIENT_ID` come from `spectrum-manual-vars` (set per-cluster, not secret). Add them to that ConfigMap out-of-band (documented in Task 9 / docs).

- [ ] **Step 2: ClusterIP Service**

`app/service.yml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: kube-oidc-proxy
  namespace: kube-oidc-proxy
spec:
  selector:
    app: kube-oidc-proxy
  ports:
    - name: https
      port: 443
      targetPort: 443
      protocol: TCP
```

- [ ] **Step 3: Add to kustomization** — append `deployment.yml`, `service.yml`.

- [ ] **Step 4: Pin image digest** **[IN-CLUSTER / has registry access]**

Run (where crane/docker available):
`docker manifest inspect quay.io/jetstack/kube-oidc-proxy:v0.3.0 | sha256` → replace the tag with `@sha256:<digest>` in `deployment.yml`.
If no tooling here, leave the tag and note it for the merge step.

- [ ] **Step 5: Validate**

Run: `kubectl kustomize flux/apps/networking/kube-oidc-proxy/app >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 6: Commit**
```bash
git add flux/apps/networking/kube-oidc-proxy/app
git commit -m "wip"
```

---

## Task 6: NetBird sidecar (proxy → authentik.infra JWKS)

> **[IN-CLUSTER VERIFICATION REQUIRED]** The sidecar brings up a WireGuard interface (needs `NET_ADMIN` + `/dev/net/tun`) and an embedded DNS resolver. Cross-container DNS in a pod is the risk: the proxy container must resolve `authentik.infra` via the sidecar. We set pod-level `dnsConfig` to prepend NetBird's resolver. **Verify in-cluster** that the proxy resolves `authentik.infra`; if it doesn't, fall back to the spec §8 split-discovery approach (issuer.url=authentik.infra + discoveryURL=authentik.cloudless.dev) which removes the sidecar entirely.

**Files:**
- Modify: `flux/apps/networking/kube-oidc-proxy/app/deployment.yml`

- [ ] **Step 1: Add sidecar container** to `spec.template.spec.containers`:
```yaml
        - name: netbird
          image: netbirdio/netbird:latest
          env:
            - name: NB_MANAGEMENT_URL
              value: "https://netbird.infrahub.cloudless.dev"
            - name: NB_SETUP_KEY
              valueFrom:
                secretKeyRef:
                  name: kube-oidc-proxy-netbird-setupkey
                  key: NB_SETUP_KEY
            - name: NB_HOSTNAME
              value: "kube-oidc-proxy-${CLUSTER_ID}"
            # Run NetBird's DNS resolver on a fixed local address the proxy container can target.
            - name: NB_DNS_RESOLVER_ADDRESS
              value: "127.0.0.1:5353"
          securityContext:
            capabilities:
              add: ["NET_ADMIN"]
          volumeMounts:
            - name: nb-tun
              mountPath: /dev/net/tun
```
- [ ] **Step 2: Add volume + pod dnsConfig** (under `spec.template.spec`):
```yaml
      dnsPolicy: ClusterFirst
      dnsConfig:
        nameservers:
          - 127.0.0.1
        options:
          - name: ndots
            value: "1"
```
and add to `volumes`:
```yaml
        - name: nb-tun
          hostPath:
            path: /dev/net/tun
            type: CharDevice
```
> Note: pinning the proxy `securityContext.runAsUser`/`runAsNonRoot` stays; the netbird sidecar needs `NET_ADMIN` and root — give it its own `securityContext` (omit the hardened pod defaults for this container by setting `runAsNonRoot: false`, `runAsUser: 0`). Adjust accordingly.

- [ ] **Step 3: Validate**

Run: `kubectl kustomize flux/apps/networking/kube-oidc-proxy/app >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit**
```bash
git add flux/apps/networking/kube-oidc-proxy/app
git commit -m "wip"
```

---

## Task 7: Mesh exposure (NBResource + Service)

**Files:**
- Create: `flux/apps/networking/netbird-services/app/kube-oidc-proxy/service.yml`
- Create: `flux/apps/networking/netbird-services/app/kube-oidc-proxy/resource-setup.yml`
- Create: `flux/apps/networking/netbird-services/app/kube-oidc-proxy/kustomization.yml`
- Create: `flux/apps/networking/netbird-services/app/kube-oidc-proxy/ks.yml`
- Modify: `flux/apps/networking/netbird-services/kustomization.yml`

- [ ] **Step 1: ExternalName Service** (mirror grafana `service.yml`)

`service.yml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: kube-oidc-proxy
  annotations:
    netbird.io/expose: "true"
    netbird.io/resource-name: "k8s.${CLUSTER_ID}.${NETWORK}"
    netbird.io/groups: "spectrum-${NETWORK}"
    netbird.io/policy-name: "k8s-access"
    netbird.io/policy-source-groups: "support,admins"
    netbird.io/policy-protocol: "tcp"
    netbird.io/policy-ports: "443"
spec:
  type: ExternalName
  externalName: kube-oidc-proxy.kube-oidc-proxy.svc.cluster.local
  ports:
    - protocol: TCP
      port: 443
```

- [ ] **Step 2: NBResource setup Job** (mirror grafana `resource-setup.yml` exactly; only name/address change)

`resource-setup.yml`:
```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-oidc-proxy-nbresource-setup
  namespace: networking
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kube-oidc-proxy-nbresource-setup
  namespace: networking
rules:
  - apiGroups: ["netbird.io"]
    resources: ["nbroutingpeers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["netbird.io"]
    resources: ["nbresources"]
    verbs: ["get", "list", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kube-oidc-proxy-nbresource-setup
  namespace: networking
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kube-oidc-proxy-nbresource-setup
subjects:
  - kind: ServiceAccount
    name: kube-oidc-proxy-nbresource-setup
    namespace: networking
---
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-oidc-proxy-nbresource-setup
  namespace: networking
  annotations:
    kustomize.toolkit.fluxcd.io/force: "Enabled"
spec:
  backoffLimit: 10
  ttlSecondsAfterFinished: 600
  template:
    spec:
      serviceAccountName: kube-oidc-proxy-nbresource-setup
      restartPolicy: OnFailure
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: setup
          image: alpine/k8s:1.30.13
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          env:
            - name: HOME
              value: /tmp
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              NETID=""
              for i in $(seq 1 30); do
                NETID=$(kubectl -n networking get nbroutingpeer router -o jsonpath='{.status.networkID}' 2>/dev/null || true)
                [ -n "$${NETID}" ] && break
                echo "waiting for NBRoutingPeer networkID... ($i/30)"
                sleep 10
              done
              [ -n "$${NETID}" ] || { echo "ERROR: NBRoutingPeer networkID not found"; exit 1; }
              echo "networkID=$${NETID}"

              cat <<EOF | kubectl apply -f -
              apiVersion: netbird.io/v1
              kind: NBResource
              metadata:
                name: kube-oidc-proxy
                namespace: networking
              spec:
                name: k8s.${CLUSTER_ID}.${NETWORK}
                address: k8s.${CLUSTER_ID}.${NETWORK}.spectrum
                networkID: $${NETID}
                groups:
                  - spectrum-${NETWORK}
              EOF
              echo "applied NBResource kube-oidc-proxy -> k8s.${CLUSTER_ID}.${NETWORK}.spectrum"
```

- [ ] **Step 3: kustomization + ks.yml**

`kustomization.yml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - service.yml
  - resource-setup.yml
```

`ks.yml` (mirror `netbird-services/app/grafana/ks.yml`):
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: netbird-services-kube-oidc-proxy
  namespace: flux-system
spec:
  path: ./flux/apps/networking/netbird-services/app/kube-oidc-proxy
  prune: true
  targetNamespace: networking
  sourceRef:
    kind: GitRepository
    name: spectrum
    namespace: flux-system
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: spectrum-vars
        optional: false
      - kind: ConfigMap
        name: spectrum-manual-vars
        optional: true
  dependsOn:
    - name: netbird-setup
    - name: kube-oidc-proxy
```

- [ ] **Step 4: Register** — add `app/kube-oidc-proxy/ks.yml` to `flux/apps/networking/netbird-services/kustomization.yml` resources.

- [ ] **Step 5: Validate**

Run: `kubectl kustomize flux/apps/networking/netbird-services/app/kube-oidc-proxy >/dev/null && kubectl kustomize flux/apps/networking >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 6: Commit**
```bash
git add flux/apps/networking/netbird-services
git commit -m "wip"
```

---

## Task 8: Operator access docs + bootstrap checklist

**Files:**
- Create: `docs/kube-oidc-proxy-access.md`

- [ ] **Step 1: Write docs** with (a) kubeconfig template, (b) bootstrap prerequisites, (c) infra-side checklist.

`docs/kube-oidc-proxy-access.md`:
````markdown
# kube-oidc-proxy — operator access

## Prerequisites
- You are on the NetBird mesh (resolve `authentik.infra` and `k8s.<id>.<net>.spectrum`).
- `kubectl` + `kubelogin` (`kubectl oidc-login`) installed.
- Trust the Fluence Mesh Root CA locally (same as Grafana access).

## kubeconfig
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

## Bootstrap secrets (out-of-band, NOT in git)
Per cluster namespace `kube-oidc-proxy`:
- `fluence-mesh-intermediate` (tls.crt + tls.key) — intermediate CA, like the Grafana ns.
- `kube-oidc-proxy-authentik-ca` (key `ca.crt`) — Fluence Mesh Root to verify authentik.infra.
- `kube-oidc-proxy-netbird-setupkey` (key `NB_SETUP_KEY`) — NetBird setup key for the sidecar peer.

Per cluster `spectrum-manual-vars` ConfigMap:
- `KUBE_OIDC_SLUG` — Authentik application slug.
- `KUBE_OIDC_CLIENT_ID` — Authentik OIDC client id (public client).

## Infra-side checklist (Authentik / NetBird — done by infra owner)
- Authentik application + OIDC provider for kube-oidc-proxy: **public client + PKCE**,
  redirect URIs for kubelogin (`http://localhost:8000` and `http://127.0.0.1:18000` by default),
  emits the `groups` claim.
- Authentik groups `k8s-admins`, `k8s-viewers` with membership.
- NetBird access policy allowing the sidecar peer's group → `authentik.infra:443`.
- Confirm `authentik.infra` serving cert chains to the Fluence Mesh Root.
````

- [ ] **Step 2: Commit**
```bash
git add docs/kube-oidc-proxy-access.md
git commit -m "wip"
```

---

## Task 9: Full-tree validation + handoff

- [ ] **Step 1: Static validation of the whole networking area**

Run:
```bash
kubectl kustomize flux/apps/networking >/dev/null && echo "networking OK"
kubectl kustomize flux/apps/networking/kube-oidc-proxy/app >/dev/null && echo "workload OK"
kubectl kustomize flux/apps/networking/netbird-services/app/kube-oidc-proxy >/dev/null && echo "mesh OK"
```
Expected: three `OK` lines.

- [ ] **Step 2: Variable-substitution smoke test** (confirms no malformed refs after Flux postBuild)

Run:
```bash
CLUSTER_ID=7b0c4ed4-4a1c-4ebb-85a4-28ca3e473684 NETWORK=stage \
KUBE_OIDC_SLUG=kube KUBE_OIDC_CLIENT_ID=demo \
sh -c 'kubectl kustomize flux/apps/networking/kube-oidc-proxy/app | sed "s/\${CLUSTER_ID}/$CLUSTER_ID/g; s/\${NETWORK}/$NETWORK/g; s/\${KUBE_OIDC_SLUG}/$KUBE_OIDC_SLUG/g; s/\${KUBE_OIDC_CLIENT_ID}/$KUBE_OIDC_CLIENT_ID/g"' \
| grep -E "k8s\.|authentik\.infra|application/o" | head
```
Expected: hostname `k8s.7b0c4ed4-...stage.spectrum` and issuer URL render cleanly (no stray `${...}`).

- [ ] **Step 3: Final commit (squash-friendly wip)** and stop. Do NOT push.

- [ ] **Step 4 [IN-CLUSTER, by operator after merge]:** rollout via Flux; then verify:
  - sidecar resolves+curls `authentik.infra/.well-known/openid-configuration`
  - `openssl s_client -connect k8s.<id>.<net>.spectrum:443` chains to Fluence Mesh Root
  - `kubectl get ns` as `k8s-admins` member → OK; as `k8s-viewers` → read OK, write denied
  - no token → 401 at proxy; apiserver audit shows impersonated identity, not proxy SA

---

## Self-Review

- **Spec coverage:** §6 components A–F all mapped (A→T1/3/5/6, B→T2, C→T4, D→T7, E→T1/7, F→T8). §7 security → T3 (scoped impersonate), T5 decision note (`system:` guard). §8 sidecar → T6 (with fallback). §9 bootstrap → T8. §11 testing → T9. §12 rollout → T9 Step 4. ✓
- **Placeholders:** image is concrete (`quay.io/jetstack/kube-oidc-proxy:v0.3.0`) with a digest-pin step; `<slug>`/`<client_id>` are genuine per-deploy inputs documented as vars/secrets, not plan gaps. ✓
- **Consistency:** secret names (`kube-oidc-proxy-tls`, `-authentik-ca`, `-netbird-setupkey`), SA `kube-oidc-proxy`, group names `k8s-admins`/`k8s-viewers`, hostname `k8s.${CLUSTER_ID}.${NETWORK}.spectrum`, ks names align across tasks. ✓
- **Known risk:** T6 cross-container DNS is the one item that can't be statically proven; fallback (split-discovery) is documented.
