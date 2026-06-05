# Grafana OIDC — token/userinfo over the mesh-only `authentik.infra`

**Branch:** `grafana-authentik-infra-backchannel`
**Status:** design VALIDATED end-to-end on the **stage** cluster (`7b0c4ed4…`, node kabat-05) on 2026-06-05.

## Goal

Move Grafana's server-side OIDC legs (`token_url`/`api_url`) from the public
`authentik.cloudless.dev` to the mesh-only `authentik.infra` (the browser `auth_url` was already
there). The Grafana pod isn't a NetBird peer by default, so we join it to the mesh with a NetBird
sidecar **injected by the netbird-operator** and let it carry the OIDC back-channel.

## Final design (operator-managed; no hand-rolled sidecar)

1. **Bump netbird-operator → 0.3.1** (`flux/apps/networking/netbird-operator/app/release.yml`).
   0.3.x adds the `SetupKey` (v1alpha1) controller that auto-mints+rotates a setup key via the
   operator's `NB_API_KEY`. (0.3.1 is the last tag on the current `netbirdio` HelmRepository; 0.4.0+
   moved to OCI + renamed — out of scope here.)
2. **`SetupKey` + `NBSetupKey`** (`netbird-setupkey.yml`):
   - `SetupKey/grafana` → operator mints the key into Secret `setup-key-grafana` (key `setup-key`)
     and rotates it. Nothing hand-created/copied.
   - `NBSetupKey/grafana` → references that Secret so the **legacy annotation injection** works.
     (The v1alpha1 `SidecarProfile` label-injection is NOT wired in the 0.3.1 webhook — verified on
     stage — so we use the annotation path.)
3. **`grafana.yml`**:
   - `token_url`/`api_url` → `https://authentik.infra/...`; `tls_client_ca: /etc/fluence-ca/root.crt`.
   - Pod template annotation `netbird.io/setup-key: grafana` → operator injects the `netbird` sidecar.
   - **securityContext split**: `runAsUser/runAsGroup/runAsNonRoot: 1001/true` on the **grafana
     container**; pod-level keeps only `fsGroup: 1001`. This lets the injected sidecar run as **root**
     — mandatory, because it must create the WireGuard iface AND rewrite the pod's shared
     `/etc/resolv.conf`. (A pod-level non-root forced the sidecar to crash:
     `mkdir /var/log/netbird` / `bind /var/run/netbird.sock: permission denied`.)
   - Mount the Fluence Mesh Root (configmap `fluence-mesh-root-ca`) for `tls_client_ca`.
   - **No** dnsConfig, no init-sidecar, no caps — all handled by the operator + kubelet's shared
     pod resolv.conf.

## Why these specifics (learned on stage)

- **Shared resolv.conf is the key.** kubelet bind-mounts ONE pod `/etc/resolv.conf` into all
  containers, so the root netbird sidecar's rewrite (→ `nameserver <wt0-IP>`, search `fluence.nb …`)
  is seen by the grafana container — `getent hosts authentik.infra` → `10.99.127.20` with no
  dnsConfig.
- **Root, not rootless.** netstack/userspace (`-rootless`) has no DNS and only proxies netbird's own
  traffic → breaks the co-container path. Kernel mode (the default image, NET_ADMIN added by the
  operator) creates a real `wt0` that routes the whole pod.
- **`init-sidecar` hung** the pod under kube-ovn (Init / no sandbox); a regular container works.
- **CA = Fluence Mesh Root.** authentik.infra's leaf is signed directly by `CN=Fluence Mesh Root CA`
  (1-cert chain, root not served) — confirmed by `openssl s_client` on stage.
- **No infra NetBird policy change.** authentik.infra NBResource policy source group = `All`.

## Bootstrap prerequisite (out-of-band, NOT in git)

- **`fluence-mesh-root-ca`** (ConfigMap, ns `observability`, key `root.crt`) = the Fluence Mesh Root
  **public** cert (PEM). Same root operators already import; safe to deliver. The operator-minted
  setup-key Secret and the rotated key are handled automatically by the `SetupKey` CR (no bootstrap).

## Stage validation evidence (2026-06-05)

- operator upgraded 0.2.2→0.3.1; `SetupKey/grafana` Ready, Secret `setup-key-grafana` minted by the
  operator; `NBSetupKey/grafana` Ready.
- grafana pod `2/2 Running`, sidecar connected to mesh; grafana `/etc/resolv.conf` = netbird;
  `getent hosts authentik.infra` → 10.99.127.20; probe pod got OIDC discovery **HTTP 200**.
- The stage validation used `tls_skip_verify_insecure` to dodge the CA-provisioning step; the final
  config above uses `tls_client_ca` (TLS validity to Fluence Mesh Root proven separately).

## Open item

- A full browser login (auth-code + PKCE) on stage to confirm the token exchange round-trips — the
  network path is proven; only the interactive login remains to click through.
