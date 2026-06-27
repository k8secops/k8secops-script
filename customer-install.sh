#!/usr/bin/env bash
# ============================================================
# GitOps Platform — one-command installer
#
# Usage (no source repo required):
#   curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-install.sh | bash
#
# What this does:
#   1. Checks prerequisites (kubectl, helm)
#   2. Creates platform namespaces + sets Pod Security labels
#   3. Installs Tekton Pipelines (idempotent -- skips if already present)
#   4. Installs Sealed Secrets controller
#   5. Installs the GitOps Platform Helm chart from OCI
#   6. Applies all 30+ security scanner tasks
#   7. Seeds the OWASP NVD vulnerability database (background)
#   8. Waits until every pod is Running and Ready
#
# Requirements:
#   kubectl >= 1.28  (configured against the target cluster)
#   helm    >= 3.12
# ============================================================

set -euo pipefail

# ── Published locations ──────────────────────────────────────────────────────
CHART_OCI="oci://registry-1.docker.io/k8secops/gitops-platform"
CHART_VERSION="1.0.0"
TEKTON_TASKS_URL="https://raw.githubusercontent.com/k8secops/k8secops-script/main/tekton-tasks.yaml"

# ── Versions ─────────────────────────────────────────────────────────────────
TEKTON_VERSION="v1.13.0"
SEALED_SECRETS_VERSION="2.15.0"

# ── Namespace names ──────────────────────────────────────────────────────────
NS_CORE="gitops-core"
NS_TOOLING="gitops-tooling"
NS_DB="gitops-db"
NS_TEKTON="tekton-pipelines"

# ── Helpers ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${CYAN}── $* ──${NC}"; }
gen_token() {
  if command -v openssl &>/dev/null; then openssl rand -hex 32
  else head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}
yesc() { printf '%s' "${1//\'/\'\'}"; }

# ── Pre-flight ────────────────────────────────────────────────────────────────
section "Pre-flight checks"

for cmd in kubectl helm; do
  if ! command -v "$cmd" &>/dev/null; then
    error "${cmd} not found."
    [[ "$cmd" == "kubectl" ]] && error "  Install: https://kubernetes.io/docs/tasks/tools/"
    [[ "$cmd" == "helm"    ]] && error "  Install: https://helm.sh/docs/intro/install/"
    exit 1
  fi
done

if ! kubectl cluster-info &>/dev/null; then
  error "Cannot reach the cluster. Check: kubectl config current-context"
  exit 1
fi

CLUSTER_CTX=$(kubectl config current-context)
info "Cluster : ${CLUSTER_CTX}"
info "Chart   : ${CHART_OCI}:${CHART_VERSION}"
echo ""
read -rp "  Install GitOps Platform on '${CLUSTER_CTX}'? [y/N]: " _confirm
[[ "${_confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }

# ── Setup — collect all inputs before touching the cluster ────────────────────
section "Setup"

# Reuse existing credentials on re-install
EXISTING_TOKEN=$(kubectl get secret gitops-platform-secrets -n "${NS_CORE}" \
  -o jsonpath='{.data.operatorApiToken}' 2>/dev/null | base64 -d 2>/dev/null || true)
EXISTING_UI_PWD=$(kubectl get secret gitops-platform-secrets -n "${NS_CORE}" \
  -o jsonpath='{.data.uiAdminPassword}' 2>/dev/null | base64 -d 2>/dev/null || true)
EXISTING_DB_PWD=$(kubectl get secret gitops-db-internal -n gitops-db \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)
EXISTING_SECRET_KEY=$(kubectl get secret gitops-platform-secrets -n "${NS_CORE}" \
  -o jsonpath='{.data.secretKey}' 2>/dev/null | base64 -d 2>/dev/null || true)

# ── UI admin password ──────────────────────────────────────────────────────────
if [[ -n "${EXISTING_UI_PWD:-}" ]]; then
  info "Re-install detected — reusing existing UI password."
  UI_ADMIN_PASSWORD="${EXISTING_UI_PWD}"
elif [[ -n "${UI_ADMIN_PASSWORD:-}" ]]; then
  info "UI_ADMIN_PASSWORD set via environment."
else
  echo ""
  echo "  Set the admin password for the platform UI (min 8 characters):"
  while true; do
    read -rsp "    Password: " UI_ADMIN_PASSWORD; echo ""
    if [[ ${#UI_ADMIN_PASSWORD} -lt 8 ]]; then
      warn "Password must be at least 8 characters. Try again."
      continue
    fi
    read -rsp "    Confirm : " _confirm_pwd; echo ""
    if [[ "$UI_ADMIN_PASSWORD" != "$_confirm_pwd" ]]; then
      warn "Passwords do not match. Try again."
    else
      break
    fi
  done
fi

# ── NVD API key ────────────────────────────────────────────────────────────────
echo ""
echo "  OWASP Dependency-Check requires the NVD vulnerability database."
echo "  An API key reduces the initial download from 30-60 min to ~5 min."
echo "  Get a FREE key at: https://nvd.nist.gov/developers/request-an-api-key"
echo ""
if [[ -z "${NVD_API_KEY:-}" ]]; then
  read -rsp "  NVD API key (press Enter to skip — download will be slow): " NVD_API_KEY
  echo ""
fi
if [[ -n "${NVD_API_KEY:-}" ]]; then
  info "NVD API key provided — OWASP database will seed in ~5 min."
else
  warn "No NVD API key — OWASP seeding will take 30-60 min in the background."
fi

# ── Auto-generated credentials ─────────────────────────────────────────────────
UI_ADMIN_USERNAME="admin"
OPERATOR_API_TOKEN="${EXISTING_TOKEN:-$(gen_token)}"
SONARQUBE_PASSWORD="$(gen_token | head -c 20)"
DB_PASSWORD="${EXISTING_DB_PWD:-$(gen_token | head -c 24)}"
SECRET_KEY="${EXISTING_SECRET_KEY:-$(gen_token)}"

echo ""
info "Setup complete — proceeding with installation."

# ── Step 1: Namespaces ────────────────────────────────────────────────────────
section "Step 1 — Namespaces"

for ns in "$NS_CORE" "$NS_TOOLING" "$NS_DB" "$NS_TEKTON"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  info "Namespace: $ns"
done

kubectl label namespace "$NS_TOOLING" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest \
  --overwrite >/dev/null

info "Pod Security labels applied"

# ── Step 2: Tekton Pipelines ──────────────────────────────────────────────────
# Installed here (not by the Helm hook) so the chart is installed with
# tekton.enabled=false — avoids the hook running twice on re-installs.
section "Step 2 — Tekton Pipelines ${TEKTON_VERSION}"

CURRENT_TEKTON=$(kubectl get deployment tekton-pipelines-controller \
  -n "$NS_TEKTON" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

if echo "$CURRENT_TEKTON" | grep -q "$TEKTON_VERSION"; then
  info "Tekton ${TEKTON_VERSION} already installed — skipping"
else
  info "Installing Tekton ${TEKTON_VERSION}..."
  kubectl apply -f \
    "https://github.com/tektoncd/pipeline/releases/download/${TEKTON_VERSION}/release.yaml"
  kubectl rollout status deployment/tekton-pipelines-controller \
    -n "$NS_TEKTON" --timeout=300s >/dev/null
  info "Tekton ready"
fi

# Required: allow Tekton's own side-containers to run
kubectl label namespace "$NS_TEKTON" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest \
  --overwrite >/dev/null

# Configure Tekton feature flags:
#   set-security-context=true     — lets Tekton inject security contexts into its own sidecars
#   disable-affinity-assistant    — required for pipelines that use multiple PVC-backed workspaces
#                                   (source, results, cache, image-tar). Without this Tekton
#                                   raises "more than one PersistentVolumeClaim is bound".
kubectl patch configmap feature-flags -n "$NS_TEKTON" \
  --type merge \
  -p '{"data":{"set-security-context":"true","coschedule":"disabled","running-in-environment-with-injected-sidecars":"false"}}' >/dev/null
# coschedule=disabled: Tekton v1.x replacement for disable-affinity-assistant.
# running-in-environment-with-injected-sidecars=false: prevents prepare init
# container from hanging indefinitely waiting for a service mesh sidecar.
info "Tekton feature flags applied"

# Tekton's prepare init container defaults to 32Mi — too low for credential
# init on tasks with large scripts (SpotBugs, AI aggregate). Raise to 512Mi.
kubectl patch configmap config-defaults -n "$NS_TEKTON" \
  --type merge \
  -p '{"data":{"default-container-resource-requirements":"prepare:\n  requests:\n    memory: \"128Mi\"\n    cpu: \"50m\"\n  limits:\n    memory: \"512Mi\"\n    cpu: \"200m\"\nplace-scripts:\n  requests:\n    memory: \"64Mi\"\n    cpu: \"50m\"\n  limits:\n    memory: \"256Mi\"\n    cpu: \"100m\"\nworking-dir-initializer:\n  requests:\n    memory: \"64Mi\"\n    cpu: \"50m\"\n  limits:\n    memory: \"256Mi\"\n    cpu: \"100m\"\n"}}' >/dev/null
info "Tekton init-container memory limits raised (prepare: 512Mi)"

# ── Step 3: Sealed Secrets ────────────────────────────────────────────────────
section "Step 3 — Sealed Secrets ${SEALED_SECRETS_VERSION}"

helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace "$NS_TOOLING" --create-namespace \
  --set fullnameOverride=sealed-secrets-controller \
  --version "$SEALED_SECRETS_VERSION" \
  --timeout 5m >/dev/null

info "Sealed Secrets installed"

# ── Step 4: Helm install from OCI ─────────────────────────────────────────────
# tekton.enabled=false: Tekton is already installed above — skip the hook.
section "Step 4 — Installing GitOps Platform v${CHART_VERSION} from OCI"

TMP_VALUES=$(mktemp)
trap 'rm -f "${TMP_VALUES}"' EXIT

cat > "${TMP_VALUES}" <<EOF
operator:
  apiToken: '$(yesc "${OPERATOR_API_TOKEN}")'
  secretKey: '$(yesc "${SECRET_KEY}")'
ui:
  auth:
    username: '$(yesc "${UI_ADMIN_USERNAME}")'
    password: '$(yesc "${UI_ADMIN_PASSWORD}")'
sonarqube:
  adminPassword: '$(yesc "${SONARQUBE_PASSWORD}")'
database:
  internal:
    password: '$(yesc "${DB_PASSWORD}")'
nvdUpdater:
  nvdApiKey: '$(yesc "${NVD_API_KEY:-}")'
tekton:
  enabled: false
EOF

helm upgrade --install gitops-platform "${CHART_OCI}" \
  --version "${CHART_VERSION}" \
  --namespace "${NS_CORE}" --create-namespace \
  -f "${TMP_VALUES}" \
  --timeout 10m

info "Helm chart installed"

# ── Wait for PostgreSQL before proceeding ─────────────────────────────────────
# The operator connects to PostgreSQL on startup. If PostgreSQL isn't ready it
# crashes and enters CrashLoopBackOff. Wait here so the operator finds it ready.
info "Waiting for PostgreSQL to be ready (may take 60-90s on first install)..."
kubectl rollout status statefulset/gitops-platform-postgresql \
  -n gitops-db --timeout=180s >/dev/null
info "PostgreSQL ready"

# ── Step 5: Scanner tasks ─────────────────────────────────────────────────────
section "Step 5 — Applying 30+ security scanner tasks"

kubectl apply -n "$NS_TEKTON" -f "${TEKTON_TASKS_URL}"
info "Scanner tasks applied"

# ── Step 5.5: Seed NVD vulnerability database ─────────────────────────────────
# OWASP Dependency-Check requires the NVD database. The nvd-updater CronJob
# runs daily at 2am to keep it fresh. Trigger an immediate seed here so the
# first pipeline run finds the database ready.
# Set NVD_API_KEY env var before running this script for a 5-min seed instead
# of 30-60 min:  NVD_API_KEY=<key> curl -sfL .../customer-install.sh | bash
# Free API key: https://nvd.nist.gov/developers/request-an-api-key
section "Step 5.5 -- Seeding OWASP NVD vulnerability database"
NVD_UPDATER_CRONJOB="gitops-platform-nvd-updater"
NVD_SEED_JOB="gitops-platform-nvd-seed"
NVD_SEED_JOB="${NVD_SEED_JOB}"  # ensure variable is set for Done section
if kubectl get cronjob "${NVD_UPDATER_CRONJOB}" -n "$NS_TEKTON" &>/dev/null; then
  kubectl delete job "${NVD_SEED_JOB}" -n "$NS_TEKTON" --ignore-not-found &>/dev/null || true
  kubectl create job "${NVD_SEED_JOB}" \
    --from=cronjob/"${NVD_UPDATER_CRONJOB}" \
    -n "$NS_TEKTON" &>/dev/null
  if [[ -n "${NVD_API_KEY:-}" ]]; then
    info "NVD seed started with API key (expect ~5 min)."
    info "Monitor: kubectl logs -f job/${NVD_SEED_JOB} -n ${NS_TEKTON}"
  else
    info "NVD seed running without API key (30-60 min). Set NVD_API_KEY for faster seeding."
    info "Monitor: kubectl logs -f job/${NVD_SEED_JOB} -n ${NS_TEKTON}"
  fi
else
  warn "NVD updater CronJob not found -- OWASP scans will skip until database is seeded."
fi

# ── Step 6: Wait ──────────────────────────────────────────────────────────────
section "Step 6 -- Waiting for all pods to be Running and Ready"

wait_ns() {
  local ns="$1" timeout="${2:-300}" elapsed=0 total ready lines
  while true; do
    lines=$(kubectl get pods -n "$ns" \
      --field-selector=status.phase!=Succeeded --no-headers 2>/dev/null || true)
    total=$(echo "$lines" | grep -c . 2>/dev/null || echo 0)
    ready=$(echo "$lines" | awk \
      '{split($2,a,"/"); if(a[1]==a[2] && a[1]!=0 && $3=="Running") c++} END{print c+0}')
    info "  ${ns}: ${ready}/${total} Ready"
    [[ "$total" -gt 0 && "$ready" -eq "$total" ]] && return 0
    (( elapsed >= timeout )) && { warn "${ns}: timeout after ${timeout}s"; return 1; }
    sleep 5; (( elapsed += 5 ))
  done
}

FAILED=false
# Wait in dependency order: DB first, then services that depend on it
[[ -n "${NS_DB:-}" ]] && { wait_ns "${NS_DB:-gitops-db}" 300 || FAILED=true; }
wait_ns "$NS_TEKTON"  300 || FAILED=true
wait_ns "$NS_TOOLING" 600 || FAILED=true
wait_ns "$NS_CORE"    300 || FAILED=true

# ── Done ──────────────────────────────────────────────────────────────────────
section "Done"

[[ "$FAILED" == "true" ]] \
  && warn "Some pods not Ready — check: kubectl get pods -A" \
  || info "All pods Running and Ready"

echo ""
echo ""
echo "  ┌──────────────────────────────────────────────────────┐"
echo "  │         GitOps Platform is ready!                    │"
echo "  └──────────────────────────────────────────────────────┘"
echo ""
echo "  ── Access ──────────────────────────────────────────────"
echo "    kubectl port-forward svc/gitops-operator -n ${NS_CORE} 8080:8080"
echo "    open http://localhost:8080"
echo ""
echo "  ── Login credentials ───────────────────────────────────"
echo "    Username         : ${UI_ADMIN_USERNAME}"
echo "    Password         : ${UI_ADMIN_PASSWORD}"
echo ""
echo "  ── SonarQube admin (internal SAST) ─────────────────────"
echo "    URL              : http://<node-ip>:9000  (gitops-tooling namespace)"
echo "    Username         : admin"
echo "    Password         : ${SONARQUBE_PASSWORD}"
echo ""
echo "  ── OWASP NVD database ──────────────────────────────────"
if [[ -n "${NVD_API_KEY:-}" ]]; then
echo "    Status           : Seeding with API key (~5 min)"
echo "    Monitor          : kubectl logs -f job/${NVD_SEED_JOB} -n ${NS_TEKTON}"
else
echo "    Status           : Seeding without API key (30-60 min background)"
echo "    Monitor          : kubectl logs -f job/${NVD_SEED_JOB} -n ${NS_TEKTON}"
fi
echo ""
echo "  ── Save securely ───────────────────────────────────────"
echo "    Operator API token: ${OPERATOR_API_TOKEN}"
echo ""
echo "  ── To uninstall ────────────────────────────────────────"
echo "    curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-uninstall.sh | bash"
echo ""
