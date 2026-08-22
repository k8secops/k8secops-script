# k8secops-gate

A cloud-agnostic, Kubernetes-native CI system with 30+ security scanners, AI-powered risk grading (A–F), and a mandatory human approval gate before any image reaches your registry.

---

## Quick Install

> **Before you start**, you'll need `kubectl` 1.28+ and `helm` 3.12+ already installed and
> pointed at your target cluster (8 GB RAM / 4 CPUs minimum) — full details in
> [Prerequisites](#prerequisites) below.

> **The installer is interactive** — it asks a few questions before touching your cluster.  
> Download and run it (do not pipe directly to bash):

```bash
curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-install.sh \
  -o install.sh && chmod +x install.sh && ./install.sh
```

### What the installer asks

The script collects all inputs **before** making any changes to your cluster:

| Prompt | Required | Notes |
|--------|----------|-------|
| Cluster confirmation | ✓ | Shows current kubectl context, asks `y/N` |
| UI admin password | ✓ | Min 8 characters. Printed at the end. |
| Registry credentials | Optional | Docker Hub username + token (recommended, prevents pull rate limits), a private registry (type `private` at the prompt to supply server/username/token instead), or skip entirely for anonymous pulls. |
| NVD API key | Optional | Speeds up the first OWASP dependency-scan database sync. See [NVD API Key](#nvd-api-key-optional--speeds-up-dependency-scanning) below. |
| Database | ✓ | Managed PostgreSQL you already have (recommended for production) or in-cluster PostgreSQL (dev/trial). See [Database](#database-managed-vs-in-cluster) below. |

After collecting inputs the script runs unattended through all install steps.

---

## Before You Install — Get Your Keys

### Database (managed vs in-cluster)

The installer asks which database to use:

1. **A managed PostgreSQL you already have** (RDS, Cloud SQL, Azure Database for
   PostgreSQL, ...) — **recommended for production**. HA, automated backups, and
   patching become your provider's job instead of this chart's. Only
   **PostgreSQL 13–16** is supported (tested against 16); the installer connects
   and verifies the version before installing anything, and refuses to proceed
   against an unsupported version. Have the host, port, database name, username,
   and password ready — the installer prompts for each.
2. **In-cluster PostgreSQL** (the installer's default if you skip option 1) —
   fine for development/trial use, or as a last resort where no managed option
   exists. No built-in HA; backups are a nightly `pg_dump` CronJob rather than a
   provider-managed process.

> If your managed database is only reachable from inside the cluster (a common
> RDS/Cloud SQL private-subnet setup), the installer's version check will fail
> to connect from wherever you're running it. Re-run with
> `SKIP_DB_VERSION_CHECK=true` to skip verification in that case.

### Docker Hub Access Token (free account — recommended)

Pipeline scanner images (gitleaks, trivy, grype, semgrep, etc.) are pulled from Docker Hub when each pipeline stage runs. Docker Hub limits **anonymous** pulls to **100 per 6 hours** per node IP. If you hit this limit, pipeline stages fail with `429 Too Many Requests`.

Providing a Docker Hub account raises this to **200 authenticated pulls per 6 hours** — enough for normal workloads.

**How to get a Docker Hub access token:**

1. Create a free account at **[hub.docker.com](https://hub.docker.com)** (if you don't have one)
2. Log in and click your avatar → **Account Settings**
3. Go to **Security** → **Access Tokens**
4. Click **Generate New Token**
5. Give it a description (e.g. `gitops-platform`) and set permissions to **Read-only**
6. Copy the token (format: `dckr_pat_xxxxxxxxxx`) — it is only shown once

> A **free Docker Hub account** is sufficient. No paid plan is needed.

### NVD API Key (optional — speeds up dependency scanning)

The **OWASP Dependency-Check** scanner (one of the SCA tools in your pipeline — see [Security scanners](#security-scanners-30) below) needs a local copy of NIST's National Vulnerability Database (NVD) to check your dependencies against. That copy is kept warm by a scheduled background job, `owasp-db-refresh`, running once a day by default (`0 3 * * *`, 03:00) in `gitops-tooling` — it isn't fetched fresh per pipeline run.

**Why you need it**: NIST rate-limits *unauthenticated* requests to the NVD API much more strictly than authenticated ones. Without a key, that daily refresh takes **30–60 minutes**; with a free key, **~5 minutes**. You'll notice the difference right after a fresh install — the installer seeds this database for the first time during Step 5.5, and without a key it keeps running in the background well after the install script finishes (the installer prints exactly this at the end — see [After Install](#after-install--what-you-see)). If your very first pipeline run's OWASP Dependency-Check stage skips with a "NVD database not available" note, the seed job simply hasn't finished yet — it isn't a broken install, and OSV-Scanner (the other SCA tool) still covers you in the meantime.

**How to get a free key:**

1. Go to **[nvd.nist.gov/developers/request-an-api-key](https://nvd.nist.gov/developers/request-an-api-key)**
2. Fill in the short form (name, organization, email) and submit
3. The key arrives by email, usually within a few minutes

**When to add it**: paste it in at the installer's prompt during a fresh install (or set `NVD_API_KEY` for a non-interactive install — see below). Already installed without one? No need to reinstall — an admin can add or change it anytime from **Admin → Settings → "Dependency scanning (OWASP)"** in the platform UI, which also lets you change the `0 3 * * *` refresh schedule itself. This only affects the background refresh job — it never blocks or slows down an actual pipeline run.

---

## Non-Interactive Install (CI/CD, Automation)

Set environment variables to skip all prompts:

```bash
export UI_ADMIN_PASSWORD="MySecurePassword123"
export DOCKERHUB_USERNAME="myusername"
export DOCKERHUB_TOKEN="dckr_pat_xxxxxxxxxx"

# Using your own private registry instead of Docker Hub? Set these three
# instead of DOCKERHUB_USERNAME/DOCKERHUB_TOKEN above (mirror the scanner
# images there first -- see "make mirror-images" in HELM_VALUES.md):
# export PRIVATE_REGISTRY_SERVER="registry.company.com"
# export PRIVATE_REGISTRY_USERNAME="myusername"
# export PRIVATE_REGISTRY_TOKEN="mytoken"

# Optional -- speeds up the OWASP dependency-scan database refresh from
# 30-60 min to ~5 min. Free key: nvd.nist.gov/developers/request-an-api-key
# export NVD_API_KEY="your-nvd-api-key"

# Managed PostgreSQL (recommended) -- omit this whole block to get in-cluster
# PostgreSQL instead (DB_MODE defaults to internal when unset).
export DB_MODE="external"
export DB_EXT_HOST="mydb.xxxxxxxxxx.us-east-1.rds.amazonaws.com"
export DB_EXT_PORT="5432"                # optional, defaults to 5432
export DB_EXT_NAME="gitops_platform"     # optional, defaults to gitops_platform
export DB_EXT_USERNAME="gitops"
export DB_EXT_PASSWORD="MyDbPassword123"
export DB_EXT_SSLMODE="require"          # optional, defaults to require
# export SKIP_DB_VERSION_CHECK="true"    # only if the DB isn't reachable from here

curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-install.sh | bash
```

All variables are optional — unset variables cause the corresponding prompt to be skipped or use defaults.

---

## Advanced: Manual Helm Install & Full Configuration Reference

Want full control instead of the one-command installer — or need to change a setting after install (private registry, external database, ingress, mTLS, etc.)? See **[HELM_VALUES.md](HELM_VALUES.md)** for:

- Step-by-step manual `helm install` (no script)
- What the installer already sets for you automatically
- A complete reference of every Helm value, organized by section
- Common recipes: enabling the webhook-api split service, mTLS, a private image registry, external PostgreSQL, ingress

---

## What the Installer Does

| Step | Action |
|------|--------|
| Pre-flight | Checks `kubectl` and `helm` are installed, verifies cluster is reachable |
| Setup | Collects UI password, Docker Hub credentials |
| 1 | Creates namespaces (`gitops-core`, `gitops-tooling`, `gitops-db`, `tekton-pipelines`) |
| 2 | Installs Tekton Pipelines v1.13.0 |
| 3 | Installs Sealed Secrets controller |
| 4 | Installs the k8secops-gate Helm chart from Docker Hub OCI |
| 5 | Applies 30+ security scanner Tekton tasks |
| 6 | Waits until every pod is Running and Ready (in dependency order) |
| Done | Prints all credentials and access instructions |

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| `kubectl` | 1.28+ | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | 3.12+ | [helm.sh/docs/intro/install](https://helm.sh/docs/intro/install/) |

Minimum cluster resources: **8 GB RAM · 4 CPUs**  
Tested on: EKS · GKE · AKS · bare metal · Kind

---

## After Install — What You See

At the end of the install the script prints everything you need:

```
── Done ──
┌──────────────────────────────────────────────────────┐
│         k8secops-gate is ready!                      │
└──────────────────────────────────────────────────────┘

  ── Access ──────────────────────────────────────────────
    kubectl port-forward svc/gitops-operator -n gitops-core 8080:8080
    open http://localhost:8080

  ── Login credentials ───────────────────────────────────
    Username : admin
    Password : <the password you set>

  ── SonarQube admin (internal SAST) ─────────────────────
    kubectl port-forward svc/gitops-platform-sonarqube -n gitops-tooling 9000:9000
    open http://localhost:9000  (ClusterIP-only -- not reachable via node IP)
    Username : admin
    Password : <auto-generated, shown here>

  ── Vulnerability-DB cache ───────────────────────────────
    Note     : the OWASP/Grype vulnerability-DB cache refreshes itself on
               a schedule (daily / every 6h) in gitops-tooling; each
               pipeline run fetches from it automatically. If seeding
               hasn't finished yet, owasp-dc/grype scans cold-start instead.

  ── Save securely ───────────────────────────────────────
    Operator API token: <auto-generated>
```

---

### Retrieve credentials at any time

```bash
# UI admin password
kubectl get secret gitops-platform-secrets -n gitops-core \
  -o jsonpath='{.data.uiAdminPassword}' | base64 -d && echo

# Operator API token
kubectl get secret gitops-platform-secrets -n gitops-core \
  -o jsonpath='{.data.operatorApiToken}' | base64 -d && echo
```

### Reset a forgotten password

```bash
curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/reset-admin-password.sh \
  | bash -s -- --password yournewpassword
```

---

## Trial Period

The platform runs as a **30-day free trial**. The expiry date is baked into the operator image at build time (reinstalling or wiping the database does not reset it — only a new image from k8secops does).

| Period | Experience |
|--------|-----------|
| Day 1 → 3 days before expiry | Full functionality, no restrictions |
| Final 3 days | Warning banner: *"Your trial expires in N days"* |
| After expiry | Trial-expired screen on all pages. Health checks still pass. |

> Pipeline history, AI reports, and configuration are preserved in PostgreSQL throughout and after the trial.

**Contact k8secops@gmail.com** to purchase a license. You will receive an updated operator image — swap the image and restart the operator. Existing data is fully preserved.

---

## Pipeline

Every commit goes through an 11-stage security pipeline:

```
Clone → Secrets → SAST → Dep scan → Compile → Tests → Build → Image scan → AI → Review → Push
```

The AI stage is optional per app, and can be scoped to specific branches (e.g. only `main`/`release`, skip `dev` to save API cost) — configurable during onboarding and editable anytime. When AI is skipped, the pipeline goes straight from image scan to Review with raw scanner findings only.

### Security scanners (30+)

| Category | Tools |
|----------|-------|
| **Secrets** | Gitleaks, TruffleHog (live credential verification) |
| **SAST** | Semgrep, Bearer, SonarQube CE, Bandit, gosec, SpotBugs, ESLint Security, Roslyn, clippy+cargo-audit (Rust), cppcheck (C/C++) |
| **SCA** | OSV-Scanner, OWASP Dependency-Check |
| **IaC** | Checkov (Dockerfile, Terraform, Helm, K8s manifests), tflint (Terraform HCL linting) |
| **Image** | Trivy (CVE + licence + misconfig), Grype, Syft SBOM, ClamAV malware, Hadolint |
| **Supply chain** | cosign image signing, CycloneDX SBOM per build |

### AI risk grading

When enabled, the AI analyses all findings after every scan and produces a **risk grade A–F**, **executive summary**, and **prioritised findings list**. Each finding is tagged as genuinely AI-reasoned or a raw-data fallback (used if AI is disabled or the call fails), so it's never ambiguous which one you're looking at.

| Grade | Meaning |
|-------|---------|
| A | No significant issues — safe to push |
| B | Minor issues only — proceed with awareness |
| C | Moderate issues — review recommended |
| D | Significant vulnerabilities — strong review required |
| F | Critical issues — AI recommends not proceeding |

### Works with or without AI

AI is optional per app (`spec.ai.enabled`, on by default, editable anytime), and can even be scoped to specific branches (e.g. only `main`/`release`, skipping `dev` to save API cost). **Every scanner still runs in full either way** — nothing about scan coverage, the human gate, or pipeline correctness depends on AI being on. With AI off (or if an AI call fails), the platform falls back to a deterministic, non-AI report built directly from the raw scanner output — so you always get a risk grade and a findings list, never a blank report.

What you specifically miss without AI:

- **AI-authored executive summary** and per-finding recommendation/fix guidance — without it you see the raw finding as reported by the tool.
- **Exploitability-based prioritization and cross-tool deduplication** — e.g. the same CVE reported by both Trivy and Grype is merged and ranked by real-world risk, not just sorted by severity label.
- **The AI chat** on a run's detail page (ask questions about findings, get review guidance) — it requires the same AI credentials and returns an error without them.

Every finding and report is tagged `ai_generated: true` or `false` so it's never ambiguous which kind of analysis you're looking at, whether AI is on, off, or just failed for one run.

### Human gate

**No image reaches the registry without a human decision** — with one narrow, explicit exception: a scheduled (cron-triggered) run auto-approves if `spec.schedule.autoApprove.enabled` is set, the AI risk grade clears the configured minimum, and there are zero critical/high findings. Every other run, including every manually- or webhook-triggered one, goes through the same mandatory human gate: the reviewer sees the full AI report, risk grade, all findings, and test results before approving or rejecting. Every decision (or auto-approval) is logged.

### Preparing your app repo

Onboarding a Java/.NET/Python/Node/React/Next.js/Go/Rust/TypeScript/Terraform repo? See **[NOTES_TO_DEVELOPERS.md](NOTES_TO_DEVELOPERS.md)** for exactly what each language's pipeline expects — build tool/file conventions, how the unit-test stage invokes your test runner and what coverage format it expects, and the common per-language pitfalls (e.g. .NET's required app/test-project split, Rust's no-coverage-collected behavior).

### Team access (Groups)

Admins can create named **Groups** (Admin → Groups) that bundle a set of apps — each with its own role (developer/reviewer) — together with member users. Members inherit whatever app access their group grants, so a team lead adds people to the group once instead of wiring up per-app permissions by hand. A new app can be assigned to a Group directly during onboarding.

### Bring your own scanner

Already pay for a licensed scanner (Coverity, Snyk, or an internal tool)? Admins can register it once (Admin → Scanners) — container image, category (secrets/SAST/SCA/image-scan), and the shell command to run it — and assign it to specific apps, groups, or all apps. Registered scanners run **alongside** the 30+ free built-in tools below, never replacing them.

---

## CLI (kgate)

`kgate` is a companion CLI (Go, single static binary, kubectl-style command surface) that does **two** distinct jobs: it can **install or upgrade the platform itself** (`kgate install` — a native-Go alternative to the Quick Install script above, no `helm`/`kubectl` binary needed), and once a platform is running, it's a full day-to-day **client** for it (login, trigger, approve, logs, admin, ...) — enforcing the same per-app `admin`/`reviewer`/`user` roles as the web UI, nothing bypassed.

### Prerequisites

| To do this | You need |
|------------|----------|
| `kgate install` — install or upgrade the platform itself | A `kubeconfig` pointed at the target cluster with near-cluster-admin permissions (it creates namespaces, RBAC, CRDs, workloads); `tekton-tasks.yaml` and the `cluster-setup/` folder from this repo (below) — **no `gitops-platform` source checkout needed** |
| Use `kgate` as a day-to-day client against a platform that's already installed (login, trigger, approve, logs, admin, ...) | Linux or macOS (curl-install below), or Windows (manual `.zip` — see below); outbound access to `github.com`/`raw.githubusercontent.com` to fetch the binary once; a platform account (ask your admin, or `kgate login` with your own UI credentials) |
| `kgate install --install-linkerd`, or image signing | the `linkerd` / `cosign` CLI on your `PATH` — both optional, silently skipped if absent |

### Install

```bash
# Linux/macOS -- no Go toolchain needed:
curl -sSL https://raw.githubusercontent.com/k8secops/k8secops-script/main/install-kgate.sh | bash

# Windows: download the .zip from
# https://github.com/k8secops/k8secops-script/releases and put kgate.exe on your PATH
```

Pin a specific version with `KGATE_VERSION=vX.Y.Z bash install-kgate.sh` (bare — the published release tag has no `cli/` prefix; see "Releasing" below for why), or install somewhere that doesn't need `sudo` with `KGATE_INSTALL_DIR=$HOME/.local/bin bash install-kgate.sh`.

### Quick start

```bash
kgate login --url http://localhost:8080
kgate list                              # apps you can see
kgate trigger my-service --branch main
kgate wait <run-id> --for=status=AWAITING_HUMAN
kgate approve <run-id> --comment "LGTM"
```

### `kgate doctor` — check readiness before you install

Before downloading anything else, run:

```bash
kgate doctor
```

A read-only check of whether your cluster is ready — reachability, the
same permissions the installer needs, a working StorageClass, enough
CPU/RAM, and outbound network access to the OCI registry and GitHub. Never
creates or changes anything, so it's safe to run against any cluster,
including production. Catches a missing permission or blocked network path
immediately instead of partway through a real install.

### Bootstrapping the platform itself

`kgate install` is a native-Go alternative to `customer-install.sh` — no `helm`/`kubectl` binary required — and it doubles as the upgrade command on a repeat run (reuses existing credentials, refuses real downgrades unless `--force-downgrade`, prunes Tekton tasks removed in a newer release). Everything it needs is published in this repo, so no `gitops-platform` source checkout is required:

```bash
curl -O https://raw.githubusercontent.com/k8secops/k8secops-script/main/tekton-tasks.yaml
curl --create-dirs -o cluster-setup/01-namespaces.yaml \
  https://raw.githubusercontent.com/k8secops/k8secops-script/main/cluster-setup/01-namespaces.yaml
curl --create-dirs -o cluster-setup/02-installer-rbac.yaml \
  https://raw.githubusercontent.com/k8secops/k8secops-script/main/cluster-setup/02-installer-rbac.yaml

kgate install --yes --tekton-tasks-file ./tekton-tasks.yaml
```

`kgate install` looks for `cluster-setup/` relative to the current directory by default (or pass `--repo-root <dir>` to point elsewhere) — as long as the three files above are laid out this way, it needs nothing else from this repo or `gitops-platform`.

Always safe to preview first with `kgate install --dry-run` (validates against your live cluster, changes nothing).

### Releasing `kgate` (maintainers only)

`install-kgate.sh` above only works once a release actually exists. Binaries
are cross-compiled and published via [GoReleaser](https://goreleaser.com/),
manually, from a `gitops-platform` checkout — this repo (`k8secops-script`)
is only the *publish target*, not where the release is built.

**Prerequisites (one-time per machine):**
- A Go toolchain — [go.dev/doc/install](https://go.dev/doc/install), or without
  root/sudo:
  ```sh
  curl -sSL -o go.tar.gz https://go.dev/dl/go1.27.0.linux-amd64.tar.gz
  mkdir -p ~/go-sdk && tar -C ~/go-sdk -xzf go.tar.gz && rm go.tar.gz
  export PATH="$HOME/go-sdk/go/bin:$HOME/go/bin:$PATH"   # add to ~/.bashrc to persist
  ```
- `goreleaser` (needs Go from the step above first) —
  `go install github.com/goreleaser/goreleaser/v2@latest`
- A `GITHUB_TOKEN` with **write access to `k8secops-script` specifically**
  (not just `gitops-platform`) — e.g. `gh auth login` then
  `GITHUB_TOKEN=$(gh auth token)`

From a clean `gitops-platform/cli/` checkout with no uncommitted changes:

```sh
# 1. Tag the release commit -- BOTH tags, same commit (see why below):
git tag cli/v1.0.0 <commit>
git tag -f v1.0.0 <commit>
git push origin cli/v1.0.0
git push --force origin v1.0.0

# 2. Publish
cd cli
GITHUB_TOKEN=<token with write access to k8secops-script> \
  GORELEASER_CURRENT_TAG=v1.0.0 \
  goreleaser release --clean
```

**Why both tags, same commit — confirmed by an actual failed release
(2026-08-22), not theory:** `GORELEASER_CURRENT_TAG` must name a real git
tag that (a) parses as semver — `cli/v1.0.0` doesn't, the prefix breaks it
— **and** (b) points at the exact commit being released, or it fails with
`git tag v1.0.0 was not made against commit ...`. `gitops-platform`
already carries its own bare `v1.0.0` platform-release tag, almost always
pointing at a *different* commit than whichever one the CLI is being
released from, so condition (b) means re-pointing that tag too (`git tag
-f`) — harmless, nothing reads what commit it points at, it's purely
informational.

**The published release itself lands under the bare `v1.0.0` tag** — a way
to keep the `cli/` prefix on the published release turned out to be
GoReleaser Pro-only too (confirmed live: `field tag not found in type
config.Release` on the OSS build). `install-kgate.sh` expects a bare tag
(it always did — an earlier pass of this README mistakenly required the
`cli/` prefix; reverted). The `cli/v1.0.0` **local git tag** on
`gitops-platform` still exists and still matters for Go module resolution
— it's just unrelated to what the release publishes under.

**Known quirk, not a bug**: the bare `v1.0.0` tag on this repo is the same
name already used for chart/Tekton-tasks versioning (`customer-install.sh`'s
`TEKTON_TASKS_URL`) — safe, since a GitHub release just attaches to
whichever commit the tag already points to here, it doesn't move it, but
one tag name now means two different things in this repo.

**Mandatory: verify the actual published binary before considering a
release done.** Confirmed live (2026-08-22): a release published with zero
errors, `kgate version` printed correctly, but the binary still ran
old, pre-fix logic — a stale Go build cache from an earlier release
attempt in the same session defeated GoReleaser's cross-compile (`go
build` run separately, right before, showed correct behavior the whole
time — the problem was specific to GoReleaser's own build step, never
fully root-caused beyond that). After every real release:

```sh
go clean -cache   # before every real release, not just when something looks wrong
curl -sSL -o /tmp/kgate_verify.tar.gz \
  https://github.com/k8secops/k8secops-script/releases/download/vX.Y.Z/kgate_linux_amd64.tar.gz
tar -xzf /tmp/kgate_verify.tar.gz -C /tmp kgate
/tmp/kgate version
```

If it shows stale behavior, delete the bad release
(`gh release delete vX.Y.Z --repo k8secops/k8secops-script --yes` — this
removes the GitHub Release and its assets, not the git tag) and re-run
`go clean -cache` + the release. This is exactly what happened the first
time `v1.0.0` was published — caught only because a real install still
failed afterward, not because the release process itself reported
anything wrong.

Until this has been run once, `curl ... | bash` above fails with
`no published release found` — that's expected, not a bug.

Full command reference: run `kgate --help` or `kgate <command> --help` — every command's flags, RBAC requirements, and behavior are documented inline in the binary itself.

---

## Uninstall

### Default — keeps PostgreSQL data

```bash
curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-uninstall.sh | bash
```

Removes: Helm releases, Sealed Secrets, per-app secrets, cache PVCs.  
Keeps: namespaces, PostgreSQL PVCs (all pipeline history preserved), Tekton controllers,
and the platform's own credentials (operator token, UI password, DB password) — these are
reused automatically on your next install, which is what keeps previously-configured
apps' encrypted credentials readable instead of orphaning them.

### Full wipe — deletes everything including pipeline history

```bash
curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-uninstall.sh | bash -s -- --purge
```

---

## What Gets Installed

| Component | Namespace | Description |
|-----------|-----------|-------------|
| GitOps Operator + UI | `gitops-core` | FastAPI + HTMX platform served on port 8080 |
| Tekton Pipelines | `tekton-pipelines` | CI pipeline engine (v1.13.0) |
| SonarQube CE | `gitops-tooling` | In-cluster SAST and code quality analysis |
| PostgreSQL | `gitops-db` | Pipeline history, AI reports, audit trail |
| Sealed Secrets | `gitops-tooling` | Encrypted Kubernetes secrets at rest |
| vulndb-cache-server + trivy-server | `gitops-tooling` | Persistent OWASP/Grype/Trivy vulnerability-DB caches, refreshed by CronJobs |
| package-cache-server | `gitops-tooling` | On-demand proxy-cache for Maven/Go/npm/Cargo dependency downloads, enabled by default |
| 30+ scanner tasks | `gitops-core` | Pre-configured, zero setup required -- copied into each run's own ephemeral namespace at trigger time |

---

## Images

Every image the platform pulls under the `k8secops/k8secops` Docker Hub repository is **public** — no login required, verified by an anonymous pull of each tag below:

**[hub.docker.com/r/k8secops/k8secops](https://hub.docker.com/r/k8secops/k8secops)**

> **Docker Hub rate limits apply to anonymous pulls** (100 per 6 hours per node IP).  
> Provide Docker Hub or private-registry credentials during install to avoid pipeline failures under load.  
> See [Registry credentials](#docker-hub-access-token-free-account--recommended) above.

### Platform images (always pulled)

| Tag | Used for |
|-----|----------|
| `gitops-operator-1.0.0` | Operator + controller process (UI, API, Kopf, scheduler) |
| `gitops-builder-1.0.0` | Kaniko image builder (Alpine-based, no external registry dependency) |
| `kubectl-1.29` | Helm chart's own pre-install/pre-delete hook Jobs |
| `gitops-webhook-api-1.0.0` | Required -- webhook ingestion and pipeline triggering live exclusively here (`webhookApi.enabled` defaults to `true`) |

### Security scanner images (always pulled — every pipeline run, regardless of app language)

| Tag | Tool |
|-----|------|
| `gitleaks-v8.18.4` | Secrets scanner |
| `trufflehog-3.95.5` | Verified secrets scanner |
| `semgrep-1.77.0` | SAST (2,000+ rules) |
| `bearer-v1.44.0` | SAST (data-flow/privacy-focused) |
| `sonar-scanner-cli-5.0.1` | SonarQube scan trigger |
| `checkov-3.2.0` | Dockerfile/IaC scanner |
| `tflint-v0.54.0` | Terraform HCL linting |
| `owasp-dependency-check-10.0.4` | SCA — dependency CVEs |
| `osv-scanner-v1.8.5` | SCA — dependency CVEs |
| `hadolint-v2.12.0-debian` | Dockerfile linting |
| `trivy-0.54.1` | Image CVE + licence + misconfig scanner |
| `grype-v0.80.0` | Image CVE scanner (Anchore DB) |
| `syft-v1.9.0` | SBOM generator (CycloneDX) |
| `clamav-stable` | Malware scanner |
| `skopeo-v1.16.0` | Image push |
| `cosign-2.2.4` | Image signing |
| `git-v2.45.2` | Repo clone |
| `alpine-3.20` | Shared shell/utility steps |

### Language runtime images (only the ones matching the languages you actually onboard)

| Tag(s) | Language |
|--------|----------|
| `dotnet-sdk-6.0`, `dotnet-sdk-8.0`, `dotnet-sdk-9.0` | .NET |
| `golang-1.21-alpine`, `golang-1.22-alpine`, `golang-1.23-alpine` | Go |
| `maven-3.9-eclipse-temurin-17`, `maven-3.9-eclipse-temurin-21` | Java (Maven/Gradle/Ant) |
| `node-18-alpine`, `node-20-alpine`, `node-22-alpine` | Node.js / React / Next.js / TypeScript |
| `python-3.10-slim`, `python-3.11-slim`, `python-3.12-slim`, `python-3.13-slim` | Python (also used at runtime for AI analysis) |
| `rust-1.75-slim`, `rust-1.78-slim`, `rust-1.81-slim` | Rust |
| `gcc-12`, `gcc-13`, `gcc-14` | C/C++ |
| `cppcheck-2.14.2` | C/C++ SAST |

### Official upstream images (not hosted by k8secops — already public on their own repos, no action needed)

| Image | Used for |
|-------|----------|
| `sonarqube:lts-community` | SonarQube CE |
| `postgres:16` | In-cluster PostgreSQL (default; not pulled if you use a managed external DB) |
| `nginx:1.27-alpine` | `vulndb-cache-server` / `package-cache-server` |
| Tekton Pipelines v1.13.0 images | Pulled from `gcr.io/tekton-releases` during Step 2 of the installer |
| Sealed Secrets controller | Pulled by the `sealed-secrets` Helm subchart during Step 3 |
| `bitnami/kubectl` | PipelineRun pruner CronJob |

*(Full tag list, including every pinned version: [hub.docker.com/r/k8secops/k8secops/tags](https://hub.docker.com/r/k8secops/k8secops/tags) — a couple of extra tags there, e.g. `postgres-16`/`sonarqube-lts-community`, are pre-mirrored copies of the upstream images above for the private-registry mirroring workflow; the default install pulls the upstream images directly and never needs them.)*

---

## Support

| Topic | Contact |
|-------|---------|
| Issues and bugs | Open an issue in this repository |
| Licensing and pricing | k8secops@gmail.com |
| Security vulnerabilities | k8secops@gmail.com |

---

*k8secops-gate v1.0.0 · [hub.docker.com/r/k8secops/k8secops](https://hub.docker.com/r/k8secops/k8secops)*
