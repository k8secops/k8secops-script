# Helm Install & Configuration Reference

Complete reference for installing and configuring the GitOps Platform via Helm. If you used the one-command installer (`customer-install.sh` / `install.sh`), most of the values below were already set for you — see [What the installer already sets](#what-the-installer-already-sets). This document is for anyone who wants a manual `helm install`, needs to change a setting after install, or wants to understand exactly what a value does before overriding it.

The canonical source for every value is `helm/gitops-platform/values.yaml` in the platform's own source repo — this document mirrors it section-by-section, in sync as of chart version **1.0.0**.

---

## Contents

- [Manual Helm install](#manual-helm-install)
- [What the installer already sets](#what-the-installer-already-sets)
- [Changing a value after install](#changing-a-value-after-install)
- [Full values reference](#full-values-reference)
- [Common recipes](#common-recipes)

---

## Manual Helm install

Most users should use the one-command installer instead (see the main README). Use this path only if you want full control over every value up front, or you're scripting an install outside `customer-install.sh`.

```bash
# 1. Create namespaces, install Tekton + Sealed Secrets first — see the main
#    README's "What the script does" table. The Helm chart itself only
#    installs the operator/controller/webhook-api/SonarQube/PostgreSQL layer.

# 2. Pull the chart from Docker Hub OCI
helm pull oci://registry-1.docker.io/k8secops/gitops-platform --version 1.0.0

# 3. Generate required secrets
OPERATOR_API_TOKEN=$(openssl rand -hex 32)
CREDENTIAL_ENCRYPTION_KEY=$(openssl rand -hex 32)
SECRET_KEY=$(openssl rand -hex 32)
SONARQUBE_PASSWORD=$(openssl rand -base64 24)
UI_ADMIN_PASSWORD=$(openssl rand -base64 16)
DB_PASSWORD=$(openssl rand -base64 24)

# 4. Install
helm upgrade --install gitops-platform ./gitops-platform-1.0.0.tgz \
  --namespace gitops-core --create-namespace \
  --set operator.apiToken="${OPERATOR_API_TOKEN}" \
  --set operator.credentialEncryptionKey="${CREDENTIAL_ENCRYPTION_KEY}" \
  --set operator.secretKey="${SECRET_KEY}" \
  --set sonarqube.adminPassword="${SONARQUBE_PASSWORD}" \
  --set ui.auth.password="${UI_ADMIN_PASSWORD}" \
  --set database.internal.password="${DB_PASSWORD}" \
  --timeout 10m

# 5. Apply the 30+ Tekton scanner tasks (not part of the Helm chart itself —
#    hosted separately so they can be updated independently)
kubectl apply -f tekton-tasks.yaml
```

Save the values you generated in step 3 somewhere safe — `operator.apiToken` in particular is also the bearer token Tekton tasks use to call back into the platform, and `operator.credentialEncryptionKey` decrypts every stored app credential (git tokens, registry credentials, AI API keys). Losing it makes those credentials unrecoverable (you'd need to re-enter them per app).

---

## What the installer already sets

`customer-install.sh` (the one-command installer) auto-generates or prompts for these values so you don't have to think about them on a first install:

| Value | Source |
|---|---|
| `operator.apiToken` | Auto-generated (`openssl rand -hex 32`) |
| `operator.secretKey` | Auto-generated |
| `operator.credentialEncryptionKey` | Auto-generated |
| `ui.auth.password` | `UI_ADMIN_PASSWORD` env var if set before running the installer, otherwise `admin` (change it after first login) |
| `sonarqube.adminPassword` | Auto-generated |
| `database.internal.password` | Auto-generated |
| `vulnDbCacheServer.nvdApiKey` | `NVD_API_KEY` env var if set, otherwise empty (optional — see [toolVersions & security tools](#tool-versions)) |
| `global.pipelineDockerHub.*` / `global.pipelineImagePullSecret.*` | Interactive prompt (private registry credentials for pulling scanner images), skippable |
| `webhookApi.enabled` | `false` — the standalone operator serves everything; enabling the split service is a manual opt-in, see [Enabling webhook-api](#enabling-webhook-api) |

Everything else in this document is a chart default you can leave alone unless you have a specific reason to change it.

---

## Changing a value after install

```bash
helm upgrade gitops-platform oci://registry-1.docker.io/k8secops/gitops-platform \
  --namespace gitops-core --reuse-values \
  --set <key>=<value>
```

**Important gotcha with `--reuse-values`:** Helm's `--reuse-values` reuses the *previous release's fully-computed values* — including chart defaults that were baked in at install time, not just the values you explicitly passed with `--set`/`-f`. This means:

- If you're changing a value that was **never explicitly set** by you or the installer (i.e. it's been sitting at whatever the chart's built-in default was), you must pass it explicitly with `--set` — `--reuse-values` alone will keep reusing the old default from when you first installed, even after upgrading to a chart version that ships a new default for it. This was confirmed live: lowering `operator.pipelineTimeout`'s default in a newer chart version had **zero effect** on an existing install until it was passed explicitly with `--set operator.pipelineTimeout=8h0m0s`.
- New top-level values.yaml keys introduced in a chart upgrade (e.g. `controller:`, `webhookApi:`) are always safe to leave unset — the chart's templates guard every new key with a `default` fallback specifically so `--reuse-values` upgrades from an older release never crash on a missing key.

When in doubt, `helm get values gitops-platform -n gitops-core -a` shows the **full computed value set** currently active (not just what you passed explicitly) — check it before assuming a values.yaml default change will reach a live cluster on its own.

---

## Full values reference

### `global` — cluster-wide settings

| Key | Default | Description |
|---|---|---|
| `global.aiProvider` | `anthropic` | AI provider for pipeline analysis: `anthropic`, `openai`, or `gemini`. Per-app, not global — this is only the picker default shown at onboarding. |
| `global.aiApiKey` | `""` | Default AI API key offered at onboarding (each app can override its own). |
| `global.imagePullPolicy` | `IfNotPresent` | Applies to all platform-owned pods. |
| `global.platformImagePullSecret.enabled` | `false` | Set `true` if the operator/controller/webhook-api images themselves are in a private registry. |
| `global.platformImagePullSecret.{registryServer,registryUsername,registryToken}` | `""` | Only used when `enabled: true` above. |
| `global.pipelineDockerHub.{username,token}` | `""` | Docker Hub credentials so Tekton scanner-image pulls (gitleaks, trivy, grype, etc.) don't hit the 100-pulls/6h anonymous rate limit. |
| `global.pipelineImagePullSecret.{server,username,token}` | `""` | Alternative to the above for a private registry (Harbor, Nexus, ECR, GHCR). Requires also mirroring images there and setting `imageRepo`. |

### `operator` — HTTP UI/API process

| Key | Default | Description |
|---|---|---|
| `operator.apiToken` | `""` (**required**) | Bearer token for internal/Tekton-callback auth. Generate: `openssl rand -hex 32`. |
| `operator.credentialEncryptionKey` | `""` | Encrypts stored app credentials at rest. Recommended to set explicitly — if empty, derived from `apiToken` instead, coupling credential decryption to token rotation. |
| `operator.secretKey` | `""` | JWT signing key for UI sessions. Empty = auto-generated per pod restart (sessions break on every restart) — set explicitly for production. |
| `operator.image` | `k8secops/k8secops:gitops-operator-1.0.0` | |
| `operator.replicas` | `1` | Scales freely — the operator process is stateless HTTP (Kopf/cron run in the separate `controller` process, see below). |
| `operator.maxConcurrentPipelines` | `3` | Beyond this, new webhook triggers get HTTP 429. |
| `operator.resources` | `100m/128Mi` request, `500m/512Mi` limit | |
| `operator.service.port` | `8080` | |
| `operator.runHistoryRetentionDays` | `30` | Run metadata (AI report, findings, decision) purged after this many days. Active runs are never purged. |
| `operator.logRetentionDays` | `10` | Raw task logs cleared after this many days (metadata kept per `runHistoryRetentionDays` regardless). Also changeable at runtime via Admin → Settings (1-180 days). |
| `operator.pipelineTimeout` | `8h0m0s` | Overall Tekton `PipelineRun` timeout — must cover CI time *plus* however long a human takes to review the gate. On timeout, Tekton cancels the run and the platform tears down its namespace automatically (see the `--reuse-values` gotcha above if you change this on an existing install). |
| `operator.externalUrl` | `""` | Public URL, e.g. `https://gitops.example.com`. Enables automatic git-provider webhook registration. |
| `operator.webhookDeliveryInsecureSsl` | `false` | Only set `true` for a self-signed/dev tunnel cert. |
| `operator.ingress.*` | disabled | Standard ingress block: `enabled`, `className`, `host`, `annotations`, `tls.{enabled,secretName}`. |

### `webhookApi` — optional split-out webhook/trigger service

Disabled by default — the operator serves everything standalone. See [Enabling webhook-api](#enabling-webhook-api) before flipping this on.

| Key | Default | Description |
|---|---|---|
| `webhookApi.enabled` | `false` | |
| `webhookApi.image` | `k8secops/k8secops:gitops-webhook-api-1.0.0` | |
| `webhookApi.replicas` | `1` | Safe to run multiple — no cluster-scoped RBAC, no leader election. |
| `webhookApi.resources` | `100m/128Mi` request, `500m/512Mi` limit | |
| `webhookApi.service.port` | `8080` | |
| `webhookApi.ingress.*` | disabled | Same shape as `operator.ingress`. |

### `controller` — Kopf reconciler + cron scheduler

Always-on (not optional like `webhookApi`), always exactly one instance — no `replicas` key. Reuses the operator's own image with a different container command; nothing to build separately.

| Key | Default | Description |
|---|---|---|
| `controller.image` | `k8secops/k8secops:gitops-operator-1.0.0` | |
| `controller.resources` | `50m/128Mi` request, `300m/384Mi` limit | |

### `ui` — login and exposure

| Key | Default | Description |
|---|---|---|
| `ui.auth.username` | `admin` | |
| `ui.auth.password` | `""` (**required**) | |
| `ui.service.type` | `NodePort` | Change to `ClusterIP` if you're using `operator.ingress` instead. |
| `ui.service.nodePort` | `30080` | Access at `http://<any-node-ip>:30080`. |
| `ui.service.tls.*` | disabled | |

### `oidc` — optional SSO

Adds a "Sign in with SSO" option; doesn't remove username/password login or the API token.

| Key | Default | Description |
|---|---|---|
| `oidc.enabled` | `false` | |
| `oidc.issuer` | `""` | As reachable from the **browser**. |
| `oidc.audience` | `""` | Expected `aud`/`azp` claim. |
| `oidc.jwksUrl` | `""` | Override only if `issuer` isn't reachable from the operator pod itself (in-cluster). |

### `tekton`

| Key | Default | Description |
|---|---|---|
| `tekton.enabled` | `true` | Set `false` if Tekton is shared with other workloads and should survive `helm uninstall`. |
| `tekton.version` | `v1.13.0` | |
| `tekton.kubectlImage` | `k8secops/k8secops:kubectl-1.29` | Used by the install/uninstall hook Jobs. |
| `tekton.removeOnUninstall` | `true` | |

### `cache` / `registryMirror` — pipeline performance

| Key | Default | Description |
|---|---|---|
| `registryMirror` | `""` | Local Docker registry mirror URL — Kaniko pulls base images from here instead of Docker Hub directly. Recommended for production to avoid rate limits. |
| `cache.vulnDb.size` | `2Gi` | Per-run vulndb-cache PVC size (seeded from the shared `vulnDbCacheServer`, see below). |

### `pruner` — completed PipelineRun cleanup

| Key | Default | Description |
|---|---|---|
| `pruner.enabled` | `true` | |
| `pruner.schedule` | `*/5 * * * *` | |
| `pruner.retentionMinutes` | `15` | Deletes completed `PipelineRun`/`TaskRun`/pod objects older than this. Run history itself lives independently in PostgreSQL and is unaffected. |
| `pruner.image` | `k8secops/k8secops:python-3.12-slim` | |

### `ephemeralNamespaceSweep` — stuck-namespace backstop

| Key | Default | Description |
|---|---|---|
| `ephemeralNamespaceSweep.enabled` | `true` | |
| `ephemeralNamespaceSweep.schedule` | `*/10 * * * *` | |
| `ephemeralNamespaceSweep.stuckAfterMinutes` | `10` | Namespaces stuck in `Terminating` past this are retried and flagged at `/admin/stuck-namespaces`. |

### `sonarqube`

| Key | Default | Description |
|---|---|---|
| `sonarqube.enabled` | `true` | |
| `sonarqube.image` | `sonarqube:lts-community` | |
| `sonarqube.postgresql.enabled` | `true` | Persists SonarQube data across restarts using the shared PostgreSQL instance. `false` = embedded H2 + emptyDir, data lost on every restart. |
| `sonarqube.postgresql.database` | `sonarqube` | |
| `sonarqube.postgresql.dataSize` | `2Gi` | File-store PVC (plugins/temp/extensions) — separate from the relational data. |
| `sonarqube.resources` | `500m/2Gi` request, `2000m/4Gi` limit | |
| `sonarqube.adminPassword` | `""` (**required**) | No default shipped — must be set at install time. |
| `sonarqube.forceAuthentication` | `true` | |

### `networkPolicy`

| Key | Default | Description |
|---|---|---|
| `networkPolicy.enabled` | `true` | Requires a CNI that enforces `NetworkPolicy` (Calico, Cilium, Azure CNI, etc.) — Kind's default `kindnet` does **not** enforce it, so this installs harmlessly there but provides no real isolation. |

### `rbacHardening`

| Key | Default | Description |
|---|---|---|
| `rbacHardening.enabled` | `false` | Installs a `ValidatingAdmissionPolicy` closing a defense-in-depth gap around the operator/webhook-api's cluster-wide namespace-provisioning `ClusterRole`. Requires Kubernetes 1.28+ with the (beta on 1.28/1.29, GA from 1.30+) `ValidatingAdmissionPolicy` feature. Should have zero effect on normal operation — verify on a disposable cluster first before enabling in production. |

### `mtls` — optional service mesh encryption

| Key | Default | Description |
|---|---|---|
| `mtls.provider` | `none` | `none`, `linkerd`, or `istio`. `install.sh --linkerd` sets this up end-to-end automatically; see [Enabling mTLS](#enabling-mtls) for bring-your-own-mesh. |
| `mtls.linkerd.version` | `stable-2.15.0` | Pinned Linkerd release installed by `install.sh --linkerd`. |

### `database`

| Key | Default | Description |
|---|---|---|
| `database.mode` | `internal` | `internal` = platform installs PostgreSQL in `gitops-db`. `external` = you supply connection details. |
| `database.internal.image` | `postgres:16` | `postgres:16-alpine` also supported (smaller, non-standard UID — the init container handles either). |
| `database.internal.storage.{data,wal,backup}` | `10Gi` / `5Gi` / `10Gi` | |
| `database.internal.storageClass` | `""` | Empty = cluster default. |
| `database.internal.maxConnections` | `200` | Raise for `operator.replicas > 1` and/or `webhookApi.enabled`. |
| `database.internal.resources` | `250m/512Mi` request, `1/1Gi` limit | |
| `database.internal.backup.enabled` | `true` | Nightly `pg_dump` CronJob. |
| `database.internal.backup.schedule` | `0 2 * * *` | |
| `database.internal.backup.retentionDays` | `7` | |
| `database.external.{host,port,database,username,password}` | `""` / `5432` / `gitops_platform` / `""` / `""` | Only used when `mode: external`. |

### `namespaceConfig`

Single source of truth for every namespace name the platform uses — changing these propagates to every Helm template automatically.

| Key | Default |
|---|---|
| `namespaceConfig.operator` | `gitops-core` |
| `namespaceConfig.tekton` | `tekton-pipelines` |
| `namespaceConfig.tooling` | `gitops-tooling` |
| `namespaceConfig.db` | `gitops-db` |

### `buildNamespacePolicy`

| Key | Default | Description |
|---|---|---|
| `buildNamespacePolicy.extraReservedNamespaces` | `[]` | Extra namespace names to block a generated ephemeral run-namespace from ever colliding with, on top of the built-in reserved list. |

### `serviceAccountNames`

| Key | Default |
|---|---|
| `serviceAccountNames.operator` | `gitops-operator` |
| `serviceAccountNames.webhookApi` | `gitops-webhook-api` |
| `serviceAccountNames.controller` | `gitops-controller` |
| `serviceAccountNames.pipeline` | `gitops-pipeline-sa` |

### `pipeline` — per-app defaults

| Key | Default | Description |
|---|---|---|
| `pipeline.coverageThreshold` | `80` | Test coverage % below which the pipeline shows a warning (does not block). |
| `pipeline.aiMinScore` | `5.0` | AI score (0-10) below which the AI recommends fixing before proceeding. |

### `imageRepo`

| Key | Default | Description |
|---|---|---|
| `imageRepo` | `k8secops/k8secops` | Where all scanner/base/runtime images are pulled from. Override after mirroring images to a private registry (`make mirror-images REGISTRY=...`). |

### `vulnDbCacheServer` — shared vulnerability-DB cache

| Key | Default | Description |
|---|---|---|
| `vulnDbCacheServer.enabled` | `true` | One persistent PVC + nginx Service in `gitops-tooling`, kept warm on a schedule and served to every run's own cold per-run cache. |
| `vulnDbCacheServer.storageClassName` | `""` | |
| `vulnDbCacheServer.dataSize` | `3Gi` | |
| `vulnDbCacheServer.owaspRefreshSchedule` | `0 3 * * *` (daily) | |
| `vulnDbCacheServer.grypeRefreshSchedule` | `0 */6 * * *` (every 6h) | |
| `vulnDbCacheServer.nvdApiKey` | `""` | Optional — cuts the OWASP refresh from 30-60 min to ~5 min. Free key: https://nvd.nist.gov/developers/request-an-api-key |
| `vulnDbCacheServer.resources` | `300m/1Gi` request, `1000m/3Gi` limit | |

### `packageCacheServer` — dependency-package cache

| Key | Default | Description |
|---|---|---|
| `packageCacheServer.enabled` | `true` | On-demand nginx proxy-cache for Maven/Go/npm/Cargo registries. |
| `packageCacheServer.storageClassName` | `""` | |
| `packageCacheServer.dataSize` | `5Gi` | |
| `packageCacheServer.resources` | `100m/128Mi` request, `500m/512Mi` limit | |

### `prepull`

| Key | Default | Description |
|---|---|---|
| `prepull.enabled` | `true` | DaemonSet pre-warming critical pipeline images on every node so the first run after cluster start isn't slowed by cold image pulls. |

### `toolVersions` — pinned scanner tool versions {#tool-versions}

Single source of truth for every scanner image tag. Bump a version here, then run `make apply-platform` to re-render the Tekton task YAMLs. Full current list (30+ tools): `gitleaks`, `trufflehog`, `semgrep`, `bearer`, `sonar-scanner-cli`, `checkov`, `tflint`, `gosec`, `bandit`, `eslint`, `eslint-plugin-security`, `eslint-plugin-no-unsanitized`, `cargo-audit`, `owasp-dependency-check`, `osv-scanner`, `hadolint`, `buildkit`, `trivy`, `grype`, `syft`, `clamav`, `skopeo`, `cosign`, `git`. See `values.yaml`'s `toolVersions` block for exact pinned versions.

### `compatibleSet` / `toolVersionsNext`

Internal version-compatibility tracking — not something you need to touch for a normal install. `compatibleSet` records the last tool-version combination that passed the platform's own smoke tests; `toolVersionsNext` is a staging area for testing a version bump before promoting it into `toolVersions`.

---

## Common recipes

### Enabling webhook-api {#enabling-webhook-api}

Splits webhook ingestion + pipeline triggering out of the operator into its own scalable service. Do this deliberately, not casually — it needs a coordinated cutover of callback URLs and git-provider webhooks:

```bash
helm upgrade gitops-platform oci://registry-1.docker.io/k8secops/gitops-platform \
  --namespace gitops-core --reuse-values \
  --set webhookApi.enabled=true
kubectl rollout restart deployment -n gitops-core
```

### Enabling mTLS {#enabling-mtls}

Bring-your-own Linkerd or Istio (already installed on your cluster):

```bash
kubectl apply -f cluster-setup/optional/mtls-linkerd.yaml   # or mtls-istio.yaml
helm upgrade gitops-platform oci://registry-1.docker.io/k8secops/gitops-platform \
  --namespace gitops-core --reuse-values \
  --set mtls.provider=linkerd   # or istio
kubectl rollout restart deployment -n gitops-core
```

Or let the installer do it end-to-end on a fresh install: `install.sh --linkerd`.

### Private registry for scanner images

```bash
make mirror-images REGISTRY=registry.company.com/sec
helm upgrade gitops-platform oci://registry-1.docker.io/k8secops/gitops-platform \
  --namespace gitops-core --reuse-values \
  --set imageRepo=registry.company.com/sec \
  --set global.pipelineImagePullSecret.server=registry.company.com \
  --set global.pipelineImagePullSecret.username=<user> \
  --set global.pipelineImagePullSecret.token=<token>
make apply-platform
```

### External (managed) PostgreSQL

```bash
helm upgrade gitops-platform oci://registry-1.docker.io/k8secops/gitops-platform \
  --namespace gitops-core --reuse-values \
  --set database.mode=external \
  --set database.external.host=<rds-or-cloudsql-host> \
  --set database.external.username=<user> \
  --set database.external.password=<password>
```

### Exposing via Ingress instead of NodePort

```bash
helm upgrade gitops-platform oci://registry-1.docker.io/k8secops/gitops-platform \
  --namespace gitops-core --reuse-values \
  --set operator.externalUrl=https://gitops.example.com \
  --set operator.ingress.enabled=true \
  --set operator.ingress.className=nginx \
  --set operator.ingress.host=gitops.example.com \
  --set operator.ingress.annotations."cert-manager\.io/cluster-issuer"=letsencrypt-prod \
  --set operator.ingress.tls.enabled=true \
  --set operator.ingress.tls.secretName=gitops-tls
```

See the main platform documentation's Ingress/SSL section for required annotations (SSE buffering must stay off for nginx-ingress) and Traefik/Istio-specific notes.
