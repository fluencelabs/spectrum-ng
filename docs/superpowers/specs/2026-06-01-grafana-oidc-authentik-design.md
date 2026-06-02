# Grafana OIDC via Authentik — Design

Date: 2026-06-01
Status: Approved (pending spec review)
Scope repo: `spectrum-ng` (Grafana side). Authentik side lives in `infra` and is applied by the user.

## Goal

Enable OIDC login to Grafana in spectrum-ng clusters against the central Authentik
(`https://authentik.cloudless.dev`), replacing the static local admin login as the
primary auth path. Roles are derived from Authentik group membership.

## Decisions (from brainstorming)

1. **One Authentik application per network** — `spectrum-grafana-{testnet|mainnet|stage|dev}`.
   Redirect URIs within a network cover all clusters of that network (regex
   `^https?://grafana\.[^./]+\.<network>/login/generic_oauth$`). Credentials are isolated per network.
2. **OIDC-only + `auto_login`** — local login form hidden; users are redirected
   straight to Authentik.
3. **Roles by Authentik groups** — reuse the existing central groups (mapped to GitHub
   teams `devops`/`devs` like everywhere else): `grafana-admins` → `Admin`,
   `grafana-devs` → `Editor`, all other authenticated users → `Viewer` (via
   `role_attribute_path` JMESPath over the `groups` claim). No grafana OIDC app exists
   in infra yet; the monolithic `authentik_oidc_apps` grafana toggle is off.
4. **Secret delivery via a new `spectrum-manual-secrets` Secret** — a Flux
   `substituteFrom` source (applied out-of-band at cluster bootstrap, not in git),
   parallel to the existing `spectrum-manual-vars` **ConfigMap**. `client_id` stays
   in `spectrum-manual-vars` (non-secret); `client_secret` lives in
   `spectrum-manual-secrets`.

## Current state (context)

- Grafana is deployed via grafana-operator (CRD `grafana.integreatly.org/v1beta1`)
  in namespace `observability`: `flux/apps/observability/grafana/app/grafana.yml`.
  Current auth = local admin `fluence/admin` (plaintext in the CR), login form enabled.
- Grafana has **no public ingress**. It is reachable only inside the NetBird mesh as
  `grafana.${CLUSTER_ID}.${NETWORK}` (ExternalName service, TCP:80 → `grafana-service.observability`,
  groups `support,admins`): `flux/apps/networking/netbird-services/app/grafana/service.yml`.
- spectrum-ng has **no external-secrets/vault/sops tooling**. The established pattern is
  a manifest with `stringData: <k>: ${VAR}`, where `${VAR}` is substituted by Flux
  `postBuild.substituteFrom` from the `spectrum-vars` / `spectrum-manual-vars`
  **ConfigMaps** (the latter applied out-of-band at bootstrap; no definition in git).
- The grafana Flux Kustomization (`flux/apps/observability/grafana/ks.yml`) currently has
  **no** `postBuild.substituteFrom`.
- Networks (overlays): `testnet`, `mainnet`, `stage`, `dev`.

## Flow

```
Browser (on NetBird VPN)
  → GET http://grafana.<cid>.<net>/            (Grafana, auto_login)
  → 302 https://authentik.cloudless.dev/application/o/authorize/?client_id=...
  → user authenticates at Authentik
  → 302 http://grafana.<cid>.<net>/login/generic_oauth?code=...
Grafana backend (server-side egress to authentik.cloudless.dev)
  → POST /application/o/token/    (code → tokens)
  → GET  /application/o/userinfo/ (claims, incl. groups)
  → role mapped from groups; session established
```

Reachability requirements:
- Browser must reach both the NetBird Grafana host and `authentik.cloudless.dev`.
- Grafana pod must have egress to `authentik.cloudless.dev` (public).

## Infra side (spec for the user to apply — NOT edited here)

New file `infra/infrahub/terraform/authentik/spectrum_grafana_oidc.tf`, using the singular
`tf_modules//authentik_oidc_app` module (ref `v0.0.10`, same as `vault_oidc.tf`), one app
per network via `for_each`, publishing creds to the infrahub Vault (default `vault` provider):

```hcl
variable "spectrum_grafana_networks" {
  type    = set(string)
  default = ["testnet", "mainnet", "stage", "dev"]
}

module "spectrum_grafana_oidc" {
  source   = "git::ssh://git@github.com/fluencelabs/tf_modules.git//authentik_oidc_app?ref=v0.0.10"
  for_each = var.spectrum_grafana_networks

  providers = { authentik = authentik, vault = vault, random = random }

  authentik_url = var.authentik_url
  name          = "Grafana — Spectrum ${each.key}"
  slug          = "spectrum-grafana-${each.key}"
  client_type   = "confidential"

  redirect_uris = [
    {
      matching_mode = "regex"
      url           = "^https?://grafana\\.[^./]+\\.${each.key}/login/generic_oauth$"
    },
  ]
  scopes = ["openid", "profile", "email", "groups"]

  signing_key_name = var.signing_key_name
  access_groups    = var.grafana_access_groups # existing ["grafana-admins", "grafana-devs"]

  vault_path     = "security/authentik-oidc/spectrum-grafana-${each.key}"
  vault_kv_mount = var.vault_kv_mount

  depends_on = [module.authentik_groups]
}
```

Outputs: `client_id` / `client_secret` published to the infrahub Vault (mount
`var.vault_kv_mount` = `authentik-oidc`) at `security/authentik-oidc/spectrum-grafana-<network>`.
Groups `grafana-admins` / `grafana-devs` already exist (created by `module.authentik_groups`
from `var.grafana_access_groups`; mapped to GitHub teams `devops`/`devs` in `local_group_mappings`).

## Secret bridge (manual bootstrap, out-of-band)

Per spectrum cluster, at bootstrap (mirrors how `CLOUDFLARE_TOKEN` etc. are seeded):
- Read `client_id` / `client_secret` from the infrahub Vault (mount `authentik-oidc`) at
  `security/authentik-oidc/spectrum-grafana-<network>`.
- Put `GRAFANA_OIDC_CLIENT_ID` into the `spectrum-manual-vars` ConfigMap.
- Put `GRAFANA_OIDC_CLIENT_SECRET` into the new `spectrum-manual-secrets` Secret.

`spectrum-manual-secrets` is a `kind: Secret` consumed by Flux `substituteFrom`
(`optional: true`), defined out-of-band like `spectrum-manual-vars`.

## spectrum-ng changes (implemented in this repo)

### 1. `flux/apps/observability/grafana/app/oidc-secret.yml` (new)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: grafana-oidc
  namespace: observability
type: Opaque
stringData:
  client_secret: ${GRAFANA_OIDC_CLIENT_SECRET}
```

### 2. `flux/apps/observability/grafana/app/grafana.yml` (edit the Grafana CR)

- `spec.config`:
  - `[server] root_url = http://grafana.${CLUSTER_ID}.${NETWORK}`
  - `[auth] disable_login_form = "true"`, keep `disable_signout_menu = "false"`
  - `[auth.generic_oauth]`:
    - `enabled = "true"`, `name = "Authentik"`, `auto_login = "true"`
    - `client_id = ${GRAFANA_OIDC_CLIENT_ID}`
    - `client_secret = $__env{GF_OAUTH_CLIENT_SECRET}`
    - `scopes = "openid profile email groups"`
    - `auth_url    = https://authentik.cloudless.dev/application/o/authorize/`
    - `token_url   = https://authentik.cloudless.dev/application/o/token/`
    - `api_url     = https://authentik.cloudless.dev/application/o/userinfo/`
    - `login_attribute_path  = preferred_username`
    - `email_attribute_path  = email`
    - `name_attribute_path   = name`
    - `role_attribute_path   = contains(groups[*], 'grafana-admins') && 'Admin' || contains(groups[*], 'grafana-devs') && 'Editor' || 'Viewer'`
    - `allow_assign_grafana_admin = "true"` (optional; only if the admins group should get server-admin)
  - **No `[security] admin_user/admin_password`** — grafana-operator (v5) auto-generates a
    random admin password into the managed Secret `grafana-admin-credentials` (ns observability,
    keys `GF_SECURITY_ADMIN_USER`/`GF_SECURITY_ADMIN_PASSWORD`). That is the break-glass account;
    no manual password, nothing in git.
- `spec.deployment.spec.template.spec.containers[name=grafana].env`:
  - `GF_OAUTH_CLIENT_SECRET` ← `secretKeyRef` `grafana-oidc.client_secret`

### 3. `flux/apps/observability/grafana/app/kustomization.yml`

- Add `oidc-secret.yml` to `resources`.

### 4. `flux/apps/observability/grafana/ks.yml`

- Add `postBuild.substituteFrom`:
  - `ConfigMap spectrum-vars` (optional: false) — `CLUSTER_ID`, `NETWORK`
  - `ConfigMap spectrum-manual-vars` (optional: true) — `GRAFANA_OIDC_CLIENT_ID`
  - `Secret spectrum-manual-secrets` (optional: true) — `GRAFANA_OIDC_CLIENT_SECRET`

## Escape-hatch & known risks

- **No fallback form with `auto_login`.** If Authentik is unreachable, append
  `?disableAutoLogin` (e.g. `http://grafana.<cid>.<net>/login?disableAutoLogin`) to show the local
  form; log in with the operator-generated creds from Secret `grafana-admin-credentials`
  (`kubectl -n observability get secret grafana-admin-credentials -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 -d`).
- **[[Authentik HTTP3 Flakiness]]** — browser→Authentik over the public edge can fail
  with `ERR_CONNECTION_CLOSED` (QUIC bug); `auto_login` makes this blocking for login.
  The `disableAutoLogin` + local admin path is the mitigation. Curl/server-side token
  exchange is unaffected.
- Grafana is served over **http** inside NetBird → redirect URI is http; the Authentik
  regex redirect must permit it.

## Testing / verification

- `kustomize build flux/apps/observability/grafana/app` renders cleanly.
- After Flux substitution, no unresolved `${...}` remain in the rendered Grafana CR / Secret.
- Manual: log in via Authentik; confirm group→role mapping (admin group → Admin,
  others → Viewer); confirm `?disableAutoLogin` shows the form and local admin works.

## Out of scope

- Introducing external-secrets/vault tooling into spectrum-ng (future improvement).
- Changes to the NetBird exposure of Grafana (unchanged).
- Per-cluster (vs per-network) Authentik applications.
