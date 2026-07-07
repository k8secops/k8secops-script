# GitOps Platform

A cloud-agnostic, Kubernetes-native CI system with 30+ security scanners, AI-powered risk grading (A–F), and a mandatory human approval gate before any image reaches your registry.

---

## Quick Install

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
| NVD API key | Optional | Strongly recommended. Free. Speeds OWASP DB download from 60 min → 5 min. |
| Docker Hub username | Optional | Recommended. Prevents image pull rate limits during pipelines. |
| Docker Hub access token | Optional | Required if username is provided. |

After collecting inputs the script runs unattended through all install steps.

---

## Before You Install — Get Your Keys

### 1. NVD API Key (free — strongly recommended)

The OWASP Dependency-Check scanner needs the NVD vulnerability database (~361,000 CVE records). Without an API key the download is rate-limited and takes **30–60 minutes**. With a key it takes **~5 minutes**.

**How to get a free NVD API key:**

1. Go to **[nvd.nist.gov/developers/request-an-api-key](https://nvd.nist.gov/developers/request-an-api-key)**
2. Fill in your name, organisation, and email address
3. Click **Submit**
4. Check your email — the key arrives within a few minutes
5. Copy the key (format: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)

> The NVD API key is **completely free** and has no usage charges. It is only used for downloading the CVE database, not for scanning.

---

### 2. Docker Hub Access Token (free account — recommended)

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

---

## Non-Interactive Install (CI/CD, Automation)

Set environment variables to skip all prompts:

```bash
export UI_ADMIN_PASSWORD="MySecurePassword123"
export NVD_API_KEY="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export DOCKERHUB_USERNAME="myusername"
export DOCKERHUB_TOKEN="dckr_pat_xxxxxxxxxx"

curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-install.sh | bash
```

All four variables are optional — unset variables cause the corresponding prompt to be skipped or use defaults.

---

## What the Installer Does

| Step | Action |
|------|--------|
| Pre-flight | Checks `kubectl` and `helm` are installed, verifies cluster is reachable |
| Setup | Collects UI password, NVD key, Docker Hub credentials |
| 1 | Creates namespaces (`gitops-core`, `gitops-tooling`, `gitops-db`, `tekton-pipelines`, `gitops-image-builds`) |
| 2 | Installs Tekton Pipelines v1.13.0 |
| 3 | Installs Sealed Secrets controller |
| 4 | Installs the GitOps Platform Helm chart from Docker Hub OCI |
| 5 | Applies 30+ security scanner Tekton tasks |
| 5.5 | Seeds the OWASP NVD vulnerability database (background or ~5 min with API key) |
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
│         GitOps Platform is ready!                    │
└──────────────────────────────────────────────────────┘

  ── Access ──────────────────────────────────────────────
    kubectl port-forward svc/gitops-operator -n gitops-core 8080:8080
    open http://localhost:8080

  ── Login credentials ───────────────────────────────────
    Username : admin
    Password : <the password you set>

  ── SonarQube admin (internal SAST) ─────────────────────
    URL      : http://<node-ip>:9000  (gitops-tooling namespace)
    Username : admin
    Password : <auto-generated, shown here>

  ── OWASP NVD database ──────────────────────────────────
    Status   : Seeding with API key (~5 min)
    Monitor  : kubectl logs -f job/gitops-platform-nvd-seed -n tekton-pipelines

  ── Save securely ───────────────────────────────────────
    Operator API token: <auto-generated>
```

---

## Before Running Your First Pipeline — Wait for NVD Database

After install completes, the OWASP Dependency-Check scanner needs its vulnerability database to be seeded before it can scan. This runs automatically as a background job.

### Check the seed status

```bash
kubectl get job gitops-platform-nvd-seed -n tekton-pipelines
```

| Status | Meaning |
|--------|---------|
| `0/1 Running` | Seeding in progress — wait for it to finish |
| `1/1 Completed` | Database ready — you can run pipelines |
| `0/1 Failed` | Seed failed — see troubleshooting below |

### Watch it live

```bash
kubectl logs -f job/gitops-platform-nvd-seed -n tekton-pipelines
```

**Expected duration:**
- With NVD API key: ~5 minutes
- Without NVD API key: 30–60 minutes (rate-limited)

> You can start pipelines before the seed finishes — the OWASP scan stage will be skipped with a note in the AI report. The database refreshes automatically every day at 2am via a CronJob.

### If the seed job fails

**Check the logs first:**
```bash
kubectl logs job/gitops-platform-nvd-seed -n tekton-pipelines
```

**Retry manually:**
```bash
# Delete the failed job and trigger a fresh one
kubectl delete job gitops-platform-nvd-seed -n tekton-pipelines --ignore-not-found
kubectl create job gitops-platform-nvd-seed \
  --from=cronjob/gitops-platform-nvd-updater \
  -n tekton-pipelines
```

**Common causes:**
- Network timeout during NVD download (transient — retry usually fixes it)
- Out of memory (OOMKilled) — cluster needs at least 4 GB free memory for the NVD pod
- Rate limit without API key — provide `NVD_API_KEY` for reliable seeding

If the job keeps failing after 2–3 retries, contact **k8secops@gmail.com** with the output of:
```bash
kubectl describe job gitops-platform-nvd-seed -n tekton-pipelines
kubectl logs job/gitops-platform-nvd-seed -n tekton-pipelines
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

### Security scanners (30+)

| Category | Tools |
|----------|-------|
| **Secrets** | Gitleaks, TruffleHog (live credential verification) |
| **SAST** | Semgrep, Bearer, SonarQube CE, Bandit, gosec, SpotBugs, ESLint Security, Roslyn |
| **SCA** | OSV-Scanner, OWASP Dependency-Check |
| **IaC** | Checkov (Dockerfile, Terraform, Helm, K8s manifests) |
| **Image** | Trivy (CVE + licence + misconfig), Grype, Syft SBOM, ClamAV malware, Hadolint |
| **Supply chain** | cosign image signing, CycloneDX SBOM per build |

### AI risk grading

After every scan the AI analyses all findings and produces a **risk grade A–F**, **executive summary**, and **prioritised findings list**.

| Grade | Meaning |
|-------|---------|
| A | No significant issues — safe to push |
| B | Minor issues only — proceed with awareness |
| C | Moderate issues — review recommended |
| D | Significant vulnerabilities — strong review required |
| F | Critical issues — AI recommends not proceeding |

### Human gate

**No image reaches the registry without a human decision.** The reviewer sees the full AI report, risk grade, all findings, and test results before approving or rejecting. Every decision is logged.

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
| NVD updater CronJob | `tekton-pipelines` | Refreshes OWASP vulnerability database daily at 2am |
| 30+ scanner tasks | `tekton-pipelines` | Pre-configured, zero setup required |

---

## Images

All scanner images are hosted on Docker Hub under `k8secops/k8secops`:

**[hub.docker.com/r/k8secops/k8secops](https://hub.docker.com/r/k8secops/k8secops)**

> **Docker Hub rate limits apply to anonymous pulls** (100 per 6 hours per node IP).  
> Provide your Docker Hub credentials during install to avoid pipeline failures.  
> See [Docker Hub Access Token](#2-docker-hub-access-token-free-account--recommended) above.

| Tag | Description |
|-----|-------------|
| `gitops-operator-1.0.0` | Platform operator + UI |
| `gitleaks-v8.18.4` | Secrets scanner |
| `trufflehog-3.95.5` | Verified secrets scanner |
| `semgrep-1.77.0` | SAST (2,000+ rules) |
| `trivy-0.54.1` | CVE + licence + misconfiguration scanner |
| `grype-v0.80.0` | CVE scanner (Anchore DB) |
| `syft-v1.9.0` | SBOM generator (CycloneDX) |
| `clamav-stable` | Malware scanner |
| `cosign-2.2.4` | Image signing |
| `python-3.12-slim` | Runtime for AI analysis |
| *...and more* | [See full list →](https://hub.docker.com/r/k8secops/k8secops/tags) |

---

## Support

| Topic | Contact |
|-------|---------|
| Issues and bugs | Open an issue in this repository |
| Licensing and pricing | k8secops@gmail.com |
| Security vulnerabilities | k8secops@gmail.com |

---

*GitOps Platform v1.0.0 · [hub.docker.com/r/k8secops/k8secops](https://hub.docker.com/r/k8secops/k8secops)*
