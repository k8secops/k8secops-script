# GitOps Platform

One-command installer for the **GitOps Platform** — a cloud-agnostic, Kubernetes-native CI system with 30+ security scanners, AI-powered risk grading (A–F), and a mandatory human approval gate before any image reaches your registry.

---

## Install

```bash
curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-install.sh | bash
```

That's it. The script handles everything from a blank Kubernetes cluster.

### What the script does

| Step | Action |
|------|--------|
| 1 | Creates namespaces (`gitops-core`, `gitops-tooling`, `gitops-db`, `tekton-pipelines`) |
| 2 | Installs Tekton Pipelines v1.13.0 |
| 3 | Installs Sealed Secrets controller |
| 4 | Installs the GitOps Platform Helm chart from Docker Hub OCI |
| 5 | Applies 30+ security scanner Tekton tasks |
| 6 | Waits until every pod is Running and Ready |
| 7 | Prints access URL and login credentials |

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| `kubectl` | 1.28+ | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | 3.12+ | [helm.sh/docs/intro/install](https://helm.sh/docs/intro/install/) |

Minimum cluster resources: **8 GB RAM · 4 CPUs**
Tested on: EKS · GKE · AKS · bare metal · Kind

---

## Login credentials

After install, access the UI:

```bash
kubectl port-forward svc/gitops-operator -n gitops-core 8080:8080
```

Open **http://localhost:8080** and log in with:

| | |
|-|-|
| **Username** | `admin` |
| **Password** | `admin` |

> **Change your password after first login** via **Profile → Change password** (top-right menu).

### Want a different password from the start?

Set `UI_ADMIN_PASSWORD` before running the install command:

```bash
UI_ADMIN_PASSWORD=mysecurepassword \
  curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-install.sh | bash
```

If you do not set it, the default is `admin`. You can always change it later from the Profile menu.

### Retrieve credentials at any time

```bash
# Admin password
kubectl get secret gitops-platform-secrets -n gitops-core \
  -o jsonpath='{.data.uiAdminPassword}' | base64 -d && echo

# Admin username
kubectl get secret gitops-platform-secrets -n gitops-core \
  -o jsonpath='{.data.uiAdminUsername}' | base64 -d && echo

# Operator API token
kubectl get secret gitops-platform-secrets -n gitops-core \
  -o jsonpath='{.data.operatorApiToken}' | base64 -d && echo
```

### Reset a forgotten password

Passwords use PBKDF2-HMAC-SHA256 — they cannot be reversed. Recovery requires `kubectl` access to the cluster:

```bash
# Prompt for new password
curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/reset-admin-password.sh | bash

# Or pass it directly
curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/reset-admin-password.sh \
  | bash -s -- --password yournewpassword

# Reset a different user
curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/reset-admin-password.sh \
  | bash -s -- --username john --password yournewpassword
```

The script generates a new hash inside the operator pod and updates PostgreSQL directly. Your pipeline history and configuration are not affected.

---

## Trial period

The platform runs as a **free trial**. The trial expiry date is baked into the operator image at build time.

| Period | Experience |
|--------|-----------|
| Days 1 – 7 | Full functionality, no restrictions |
| Days 8 – expiry | Amber warning banner at the top of every page: *"Your trial expires in N days"* |
| After expiry | Every page shows a trial-expired screen. Health checks still pass so the pod stays running. |

> **Your pipeline history, AI reports, and configuration are preserved in PostgreSQL** throughout and after the trial. Nothing is deleted — the platform simply stops accepting new work until a license is obtained.

**Reinstalling or wiping the database does not reset the trial.** The expiry date is compiled into the operator binary.

### Purchase a license

Contact **k8secops@gmail.com** to purchase a license. You will receive an updated operator image with an extended expiry date. Your existing data is fully preserved — swap the image and restart the operator.

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

After every scan the AI analyses all findings and produces:

- **Risk grade A–F** — instant verdict visible to the reviewer
- **Executive summary** — plain-English brief for non-technical stakeholders
- **Prioritised findings** — ranked by severity and exploitability

| Grade | Meaning |
|-------|---------|
| A | No significant issues — safe to push |
| B | Minor issues only — proceed with awareness |
| C | Moderate issues — review recommended |
| D | Significant vulnerabilities — strong review required |
| F | Critical issues — AI recommends not proceeding |

### Human gate

**No image reaches the registry without a human decision.** The reviewer sees the full AI report, risk grade, all findings, and test results before approving or rejecting. Every decision is logged with the reviewer's identity and timestamp.

---

## Uninstall

### Default — keeps PostgreSQL data (safe to reinstall over)

```bash
curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-uninstall.sh | bash
```

Removes: Helm releases, Sealed Secrets, per-app credentials, platform secrets.
Keeps: namespaces, PostgreSQL PVCs (all pipeline history preserved), Tekton controllers.

### Full wipe — deletes everything including pipeline history

```bash
curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-uninstall.sh | bash -s -- --purge
```

Removes: all of the above plus namespaces, PostgreSQL PVCs, Tekton Pipelines, cosign keys.

---

## What gets installed

| Component | Namespace | Description |
|-----------|-----------|-------------|
| GitOps Operator + UI | `gitops-core` | FastAPI + HTMX platform served on port 8080 |
| Tekton Pipelines | `tekton-pipelines` | CI pipeline engine (v1.13.0) |
| SonarQube CE | `gitops-tooling` | In-cluster SAST and code quality analysis |
| PostgreSQL | `gitops-db` | Pipeline history, AI reports, audit trail |
| Sealed Secrets | `gitops-tooling` | Encrypted Kubernetes secrets at rest |
| 30+ scanner tasks | `tekton-pipelines` | Pre-configured, zero setup required |

---

## All images

All images are hosted publicly on Docker Hub with no authentication required:

**[hub.docker.com/r/k8secops/k8secops](https://hub.docker.com/r/k8secops/k8secops)**

Tag format: `k8secops/k8secops:<toolname>-<version>`

| Tag | Description |
|-----|-------------|
| `gitops-operator-1.0.0` | Platform operator + UI (contains trial expiry) |
| `gitops-builder-1.0.0` | Kaniko image builder (used by pipeline build task) |
| `gitleaks-v8.18.4` | Secrets scanner |
| `trufflehog-3.95.5` | Verified secrets scanner |
| `semgrep-1.77.0` | SAST (2,000+ rules) |
| `trivy-0.54.1` | CVE + licence + misconfiguration scanner |
| `grype-v0.80.0` | CVE scanner (Anchore DB) |
| `syft-v1.9.0` | SBOM generator (CycloneDX) |
| `clamav-stable` | Malware scanner |
| `cosign-2.2.4` | Image signing |
| `python-3.12-slim` | Runtime for AI analysis and pipeline steps |
| `sonarqube-lts-community` | SonarQube CE |
| `postgres-16` | PostgreSQL |
| `kubectl-1.29` | Used by pruner CronJob |
| *...and more* | [See full list →](https://hub.docker.com/r/k8secops/k8secops/tags) |

---

## Support

| Topic | Contact |
|-------|---------|
| Issues and bugs | Open an issue in this repository |
| Licensing and pricing | k8secops@gmail.com |
| Security vulnerabilities | k8secops@gmail.com |

---

*GitOps Platform v1.0.0 · All images: [hub.docker.com/r/k8secops/k8secops](https://hub.docker.com/r/k8secops/k8secops)*
