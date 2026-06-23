# GitOps Platform — Install Script

One-command installer for the **GitOps Platform** — a cloud-agnostic, Kubernetes-native CI system with 30+ security scanners, AI-powered risk analysis, and a mandatory human approval gate before any image reaches your registry.

---

## Quick install

```bash
curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-install.sh | bash
```

That's it. The script sets up a complete CI platform on any Kubernetes cluster.

---

## What gets installed

| Component | Description |
|-----------|-------------|
| **GitOps Operator** | FastAPI + HTMX platform UI served on port 8080 |
| **Tekton Pipelines** | CI pipeline engine (v1.13.0) |
| **SonarQube CE** | In-cluster SAST and code quality analysis |
| **PostgreSQL** | Pipeline run history, AI reports, audit trail |
| **Sealed Secrets** | Encrypted Kubernetes secrets at rest |
| **30+ scanner tasks** | Secrets, SAST, SCA, image scanning, supply chain |

### Pipeline stages

```
Clone → Secrets → SAST → Dep scan → Compile → Tests → Build → Image scan → AI → Review → Push
```

Every build is scanned by 30+ tools, analysed by AI (risk grade A–F), and requires a human reviewer to approve before the image is pushed and signed.

---

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| `kubectl` | 1.28+ | [docs](https://kubernetes.io/docs/tasks/tools/) |
| `helm` | 3.12+ | [docs](https://helm.sh/docs/intro/install/) |
| `python3` | 3.10+ | [python.org](https://www.python.org/downloads/) |

A Kubernetes cluster with at least **8 GB RAM** and **4 CPUs** is recommended (SonarQube is the heaviest component at ~2 GB).

Tested on: EKS, GKE, AKS, bare metal, Kind.

---

## What the script does

1. **Checks prerequisites** — `kubectl`, `helm`, `python3`, cluster connectivity
2. **Creates namespaces** — `gitops-core`, `gitops-tooling`, `gitops-db`, `tekton-pipelines`
3. **Installs Tekton Pipelines** — skips if already present
4. **Installs Sealed Secrets** — separate Helm release into `gitops-tooling`
5. **Installs the platform** — Helm chart from Docker Hub OCI registry
6. **Applies 30+ scanner tasks** — all Tekton tasks pre-configured to pull from `k8secops/k8secops`
7. **Waits for all pods** — confirms every component is Running and Ready before exiting
8. **Prints access details** — URL, login credentials, API token

---

## Options

### Non-interactive (CI/CD friendly)

```bash
curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-install.sh | bash -s -- --yes
```

### Pre-set credentials via environment variables

```bash
export OPERATOR_API_TOKEN="your-strong-token"
export UI_ADMIN_USERNAME="admin"
export UI_ADMIN_PASSWORD="your-password"
export SONARQUBE_PASSWORD="your-sonar-password"

curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-install.sh | bash
```

If not set, the script generates secure random values and prints them on completion.

---

## After install

```bash
# Access the UI
kubectl port-forward svc/gitops-operator -n gitops-core 8080:8080
# Open http://localhost:8080
```

Login with the credentials printed at the end of the install script.

### First steps

1. **Onboard an application** — click **+ Onboard app** and follow the 5-step wizard
2. **Configure a webhook** — the wizard shows the exact URL to register in GitHub / GitLab / Bitbucket
3. **Push a commit** — the pipeline triggers automatically
4. **Review the AI report** — approve or reject at the human gate

---

## Private registry support

If you want all images pulled from your own registry instead of `k8secops/k8secops`:

```bash
# Copy all images from k8secops to your registry
# (requires the full platform repo)
bash scripts/publish-images.sh --from k8secops   # copies k8secops → your registry
```

Then set `imageRepo: "your-registry.example.com/gitops"` in your Helm values and re-apply the platform.

---

## Uninstall

```bash
# Remove platform (keeps namespaces and PostgreSQL data by default)
helm uninstall gitops-platform -n gitops-core
helm uninstall sealed-secrets   -n gitops-tooling

# Full wipe including data
helm uninstall gitops-platform -n gitops-core
kubectl delete namespace gitops-core gitops-tooling gitops-db tekton-pipelines
```

---

## Images

All images used by the platform are hosted publicly at:

**[hub.docker.com/r/k8secops/k8secops](https://hub.docker.com/r/k8secops/k8secops)**

Tag format: `k8secops/k8secops:<toolname>-<version>`

| Tag | Description |
|-----|-------------|
| `gitops-operator-1.0.0` | Platform operator + UI |
| `gitops-builder-1.0.0` | Kaniko image builder (used by CI pipelines) |
| `gitleaks-v8.18.4` | Secrets scanner |
| `trivy-0.54.1` | CVE + licence + misconfiguration scanner |
| `semgrep-1.77.0` | SAST (2000+ rules) |
| `grype-v0.80.0` | CVE scanner (Anchore DB) |
| `syft-v1.9.0` | SBOM generator (CycloneDX) |
| *...and 30+ more* | [See full list →](https://hub.docker.com/r/k8secops/k8secops/tags) |

---

## Support

- **Issues**: open an issue in this repository
- **Security vulnerabilities**: email security@k8secops.io

---

*GitOps Platform v1.0.0 · [Docker Hub](https://hub.docker.com/r/k8secops/k8secops) · [Security overview](https://k8secops.io/security)*
