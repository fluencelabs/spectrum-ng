# Grafana OIDC via Authentik — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add OIDC login to spectrum-ng Grafana against the central Authentik (`https://authentik.cloudless.dev`), OIDC-only with `auto_login`, roles mapped from Authentik groups.

**Architecture:** Edit the grafana-operator `Grafana` CR (`config` + `deployment.env`), add a `grafana-oidc` Secret whose values come from a new out-of-band `spectrum-manual-secrets` Flux substitution source, and wire `postBuild.substituteFrom` into the grafana Flux Kustomization. Authentik-side (per-network OIDC apps) is done in the `infra` repo by the user — see Appendix A.

**Tech Stack:** Flux (Kustomization `postBuild.substituteFrom`), Kustomize, grafana-operator CRD `grafana.integreatly.org/v1beta1`, Authentik OIDC.

Spec: `docs/superpowers/specs/2026-06-01-grafana-oidc-authentik-design.md`

---

## File Structure

- `flux/apps/observability/grafana/app/oidc-secret.yml` — **create**. `Secret grafana-oidc` (namespace `observability`) holding `client_secret` and `admin_password`, values via Flux substitution.
- `flux/apps/observability/grafana/app/grafana.yml` — **modify**. Add `[server] root_url`, `[auth.generic_oauth]`, flip `disable_login_form`, move admin password to env; add container env vars.
- `flux/apps/observability/grafana/app/kustomization.yml` — **modify**. Add `oidc-secret.yml`.
- `flux/apps/observability/grafana/ks.yml` — **modify**. Add `postBuild.substituteFrom`.

Out-of-band (operator/bootstrap, NOT in git): `spectrum-manual-vars` ConfigMap gains `GRAFANA_OIDC_CLIENT_ID`; new `spectrum-manual-secrets` Secret holds `GRAFANA_OIDC_CLIENT_SECRET` and `GRAFANA_ADMIN_PASSWORD`. See Appendix B.

**Validation note:** This is declarative k8s/Flux config, not unit-tested code. "Tests" = `kustomize build` renders cleanly + a local `envsubst` dry-run leaves no unresolved `${...}` (while preserving Grafana's `$__env{...}` refs, which are not Flux syntax).

---

### Task 1: Wire substitution sources into the grafana Flux Kustomization

**Files:**
- Modify: `flux/apps/observability/grafana/ks.yml`

- [ ] **Step 1: Add `postBuild.substituteFrom` to the Kustomization spec**

Current file:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: grafana
  namespace: flux-system
spec:
  path: ./flux/apps/observability/grafana/app
  prune: true
  targetNamespace: observability
  sourceRef:
    kind: GitRepository
    name: spectrum
    namespace: flux-system
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  dependsOn:
    - name: grafana-operator-crd
    - name: vm-stack
```

Replace the whole file with (adds `postBuild` block before `dependsOn`):

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: grafana
  namespace: flux-system
spec:
  path: ./flux/apps/observability/grafana/app
  prune: true
  targetNamespace: observability
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
    - name: grafana-operator-crd
    - name: vm-stack
```

- [ ] **Step 2: Verify YAML parses**

Run: `kubectl --dry-run=client apply -f flux/apps/observability/grafana/ks.yml 2>/dev/null || python3 -c "import yaml,sys; list(yaml.safe_load_all(open('flux/apps/observability/grafana/ks.yml'))); print('OK')"`
Expected: `OK` (or a clean dry-run; no YAML parse error).

- [ ] **Step 3: Commit**

```bash
git add flux/apps/observability/grafana/ks.yml
git commit -m "wip"
```

---

### Task 2: Create the `grafana-oidc` Secret manifest

**Files:**
- Create: `flux/apps/observability/grafana/app/oidc-secret.yml`

- [ ] **Step 1: Create the Secret**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: grafana-oidc
  namespace: observability
type: Opaque
stringData:
  client_secret: ${GRAFANA_OIDC_CLIENT_SECRET}
  admin_password: ${GRAFANA_ADMIN_PASSWORD}
```

- [ ] **Step 2: Verify YAML parses**

Run: `python3 -c "import yaml; print(yaml.safe_load(open('flux/apps/observability/grafana/app/oidc-secret.yml'))['metadata']['name'])"`
Expected: `grafana-oidc`

- [ ] **Step 3: Commit**

```bash
git add flux/apps/observability/grafana/app/oidc-secret.yml
git commit -m "wip"
```

---

### Task 3: Register the Secret in the app kustomization

**Files:**
- Modify: `flux/apps/observability/grafana/app/kustomization.yml`

- [ ] **Step 1: Add `oidc-secret.yml` to `resources`**

Current file:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - grafana.yml
  - folders/
```

Replace with:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - grafana.yml
  - oidc-secret.yml
  - folders/
```

- [ ] **Step 2: Verify kustomize build includes the Secret**

Run: `kustomize build flux/apps/observability/grafana/app | grep -A1 'kind: Secret'`
Expected: output shows the `grafana-oidc` Secret (with the literal `${GRAFANA_OIDC_CLIENT_SECRET}` placeholder, since substitution happens in-cluster).

- [ ] **Step 3: Commit**

```bash
git add flux/apps/observability/grafana/app/kustomization.yml
git commit -m "wip"
```

---

### Task 4: Configure OIDC in the Grafana CR

**Files:**
- Modify: `flux/apps/observability/grafana/app/grafana.yml`

- [ ] **Step 1: Replace the `config` block (lines 14-29)**

Current `config` block:

```yaml
  config:
    log:
      mode: "console"
    users:
      allow_sign_up: "false"
      allow_org_create: "false"
    auth:
      disable_login_form: "false"
      disable_signout_menu: "false"
    security:
      admin_user: fluence
      admin_password: admin
    analytics:
      check_for_updates: "false"
    news:
      news_feed_enabled: "false"
```

Replace with:

```yaml
  config:
    server:
      root_url: "http://grafana.${CLUSTER_ID}.${NETWORK}"
    log:
      mode: "console"
    users:
      allow_sign_up: "false"
      allow_org_create: "false"
    auth:
      disable_login_form: "true"
      disable_signout_menu: "false"
    auth.generic_oauth:
      enabled: "true"
      name: "Authentik"
      auto_login: "true"
      client_id: "${GRAFANA_OIDC_CLIENT_ID}"
      client_secret: "$__env{GF_OAUTH_CLIENT_SECRET}"
      scopes: "openid profile email groups"
      auth_url: "https://authentik.cloudless.dev/application/o/authorize/"
      token_url: "https://authentik.cloudless.dev/application/o/token/"
      api_url: "https://authentik.cloudless.dev/application/o/userinfo/"
      login_attribute_path: "preferred_username"
      email_attribute_path: "email"
      name_attribute_path: "name"
      role_attribute_path: "contains(groups[*], 'spectrum-grafana-admins') && 'Admin' || 'Viewer'"
      allow_assign_grafana_admin: "true"
      use_pkce: "true"
    security:
      admin_user: fluence
      admin_password: "$__env{GF_SECURITY_ADMIN_PASSWORD}"
    analytics:
      check_for_updates: "false"
    news:
      news_feed_enabled: "false"
```

Notes for the implementer:
- `auth.generic_oauth` is a valid INI section name; the dotted YAML key is intentional.
- `$__env{...}` is Grafana's env-reference syntax and is NOT touched by Flux substitution (Flux only replaces `${...}`). Do not change it to `${...}`.
- `${CLUSTER_ID}` / `${NETWORK}` / `${GRAFANA_OIDC_CLIENT_ID}` ARE Flux substitution vars.

- [ ] **Step 2: Add container env to the grafana deployment (current lines 35-43)**

Current container block:

```yaml
          containers:
            - name: grafana
              readinessProbe:
                failureThreshold: 3
              securityContext:
                allowPrivilegeEscalation: false
                capabilities:
                  drop:
                  - ALL
```

Replace with (adds `env`):

```yaml
          containers:
            - name: grafana
              readinessProbe:
                failureThreshold: 3
              securityContext:
                allowPrivilegeEscalation: false
                capabilities:
                  drop:
                  - ALL
              env:
                - name: GF_OAUTH_CLIENT_SECRET
                  valueFrom:
                    secretKeyRef:
                      name: grafana-oidc
                      key: client_secret
                - name: GF_SECURITY_ADMIN_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: grafana-oidc
                      key: admin_password
```

- [ ] **Step 3: Verify YAML parses and the section is present**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('flux/apps/observability/grafana/app/grafana.yml')); print('auth.generic_oauth' in d['spec']['config'], d['spec']['config']['auth']['disable_login_form'])"`
Expected: `True true`

- [ ] **Step 4: Verify env wired to the secret**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('flux/apps/observability/grafana/app/grafana.yml')); env=d['spec']['deployment']['spec']['template']['spec']['containers'][0]['env']; print([e['name'] for e in env])"`
Expected: `['GF_OAUTH_CLIENT_SECRET', 'GF_SECURITY_ADMIN_PASSWORD']`

- [ ] **Step 5: Commit**

```bash
git add flux/apps/observability/grafana/app/grafana.yml
git commit -m "wip"
```

---

### Task 5: Full render + substitution dry-run

**Files:** none (validation only)

- [ ] **Step 1: kustomize build renders cleanly**

Run: `kustomize build flux/apps/observability/grafana/app > /tmp/grafana-rendered.yaml && echo OK`
Expected: `OK`, no error.

- [ ] **Step 2: Simulate Flux substitution and confirm no unresolved `${...}`**

Run:
```bash
CLUSTER_ID=demo NETWORK=testnet \
GRAFANA_OIDC_CLIENT_ID=test-client-id \
GRAFANA_OIDC_CLIENT_SECRET=test-secret \
GRAFANA_ADMIN_PASSWORD=test-admin-pw \
envsubst '$CLUSTER_ID $NETWORK $GRAFANA_OIDC_CLIENT_ID $GRAFANA_OIDC_CLIENT_SECRET $GRAFANA_ADMIN_PASSWORD' \
  < /tmp/grafana-rendered.yaml > /tmp/grafana-substituted.yaml
grep -n '\${' /tmp/grafana-substituted.yaml || echo "NO_UNRESOLVED_VARS"
```
Expected: `NO_UNRESOLVED_VARS` (note: restricting `envsubst` to the named vars prevents it from eating Grafana's `$__env{...}` — verify the next step).

- [ ] **Step 3: Confirm Grafana `$__env{...}` refs survived**

Run: `grep -c '\$__env{' /tmp/grafana-substituted.yaml`
Expected: `2` (client_secret + admin_password references intact).

- [ ] **Step 4: Confirm root_url and client_id substituted**

Run: `grep -E 'root_url|client_id' /tmp/grafana-substituted.yaml`
Expected: `root_url: "http://grafana.demo.testnet"` and `client_id: "test-client-id"`.

- [ ] **Step 5: Clean up temp files**

Run: `rm -f /tmp/grafana-rendered.yaml /tmp/grafana-substituted.yaml && echo done`
Expected: `done`

No commit (validation only).

---

## Self-Review

- **Spec coverage:** root_url (T4), generic_oauth + auto_login + roles (T4), disable_login_form (T4), admin escape-hatch via env (T2/T4), `grafana-oidc` Secret (T2), kustomization wiring (T3), ks `substituteFrom` incl. `spectrum-manual-secrets` (T1), render/substitution validation (T5). Infra side and bootstrap are Appendices A/B (user-owned). ✓
- **Placeholders:** none — every step has concrete content/commands. `${...}` / `$__env{...}` are intended runtime tokens, not plan placeholders. ✓
- **Type/name consistency:** Secret name `grafana-oidc` and keys `client_secret`/`admin_password` are identical across T2, T3, T4. Env names `GF_OAUTH_CLIENT_SECRET` / `GF_SECURITY_ADMIN_PASSWORD` match between T4 config and T4 env. Flux vars `GRAFANA_OIDC_CLIENT_ID` / `GRAFANA_OIDC_CLIENT_SECRET` / `GRAFANA_ADMIN_PASSWORD` consistent across T1/T2/T4/T5 and Appendix B. ✓

---

## Appendix A — Infra side (user applies in `infra`, NOT this repo)

Per network (`testnet`, `mainnet`, `stage`, `dev`), add to `infra/infrahub/terraform/authentik/`
a module mirroring `stage_oidc.tf` (module ref `v0.0.10`):

```hcl
module "spectrum_oidc_grafana_<network>" {
  source = "git::ssh://git@github.com/fluencelabs/tf_modules.git//authentik_oidc_app?ref=v0.0.10"
  providers = { authentik = authentik, vault = vault.<network>, random = random }

  authentik_url = "https://authentik.cloudless.dev"
  name          = "Grafana (<network>)"
  slug          = "spectrum-grafana-<network>"
  client_type   = "confidential"

  redirect_uris = [
    { matching_mode = "regex", url = "^http://grafana\\..*\\.<network>/login/generic_oauth$" },
  ]
  scopes           = ["openid", "profile", "email", "groups"]
  signing_key_name = var.signing_key_name
  access_groups    = ["spectrum-grafana-admins", "spectrum-grafana-viewers"]

  vault_path     = "security/authentik-oidc/grafana"
  vault_kv_mount = var.vault_kv_mount
}
```

Prereqs: Authentik groups `spectrum-grafana-admins` / `spectrum-grafana-viewers` exist;
the module publishes `client_id`/`client_secret` to the per-network Vault at
`security/authentik-oidc/grafana`.

## Appendix B — Bootstrap secret seeding (out-of-band, per spectrum cluster)

At cluster bootstrap (same mechanism that seeds `CLOUDFLARE_TOKEN` etc.):
- Read `client_id` / `client_secret` from the network Vault `security/authentik-oidc/grafana`.
- `spectrum-manual-vars` **ConfigMap**: set `GRAFANA_OIDC_CLIENT_ID=<client_id>`.
- `spectrum-manual-secrets` **Secret** (new substitution source; create if absent): set
  `GRAFANA_OIDC_CLIENT_SECRET=<client_secret>` and `GRAFANA_ADMIN_PASSWORD=<chosen break-glass pw>`.

## Operations — login & break-glass

- Normal: open `http://grafana.<cluster_id>.<network>/` → redirected to Authentik → back to Grafana.
- Break-glass (Authentik down, incl. [[Authentik HTTP3 Flakiness]]): open
  `http://grafana.<cluster_id>.<network>/login?disableAutoLogin` → local form → log in as
  `fluence` with `GF_SECURITY_ADMIN_PASSWORD`.
