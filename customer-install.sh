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
#   3. Installs Tekton Pipelines (idempotent — skips if already present)
#   4. Installs Sealed Secrets controller
#   5. Installs the GitOps Platform Helm chart from OCI
#   6. Applies all 30+ security scanner tasks
#   7. Waits until every pod is Running and Ready
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

info "Cluster : $(kubectl config current-context)"
info "Chart   : ${CHART_OCI}:${CHART_VERSION}"

# ── Credentials — auto-generated, printed at end ──────────────────────────────
section "Generating credentials"

EXISTING_TOKEN=$(kubectl get secret gitops-platform-secrets -n "${NS_CORE}" \
  -o jsonpath='{.data.operatorApiToken}' 2>/dev/null | base64 -d 2>/dev/null || true)
EXISTING_UI_PWD=$(kubectl get secret gitops-platform-secrets -n "${NS_CORE}" \
  -o jsonpath='{.data.uiAdminPassword}' 2>/dev/null | base64 -d 2>/dev/null || true)
# Reuse existing DB password — PostgreSQL data directory is initialised with it;
# using a new password on re-install causes "password authentication failed".
EXISTING_DB_PWD=$(kubectl get secret gitops-db-internal -n gitops-db \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)

UI_ADMIN_USERNAME="admin"
OPERATOR_API_TOKEN="${EXISTING_TOKEN:-$(gen_token)}"
# Default password is 'admin' — change it after first login via the UI.
# Override before install: UI_ADMIN_PASSWORD=mypassword curl -sfL .../customer-install.sh | bash
UI_ADMIN_PASSWORD="${UI_ADMIN_PASSWORD:-${EXISTING_UI_PWD:-admin}}"
SONARQUBE_PASSWORD="$(gen_token | head -c 16)"
DB_PASSWORD="${EXISTING_DB_PWD:-$(gen_token | head -c 24)}"

info "Credentials generated (printed at end)"

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
  -p '{"data":{"set-security-context":"true","disable-affinity-assistant":"true"}}' >/dev/null

# Restart the controller so it picks up the new feature flags immediately.
# The configmap is read at startup — patching alone is not enough.
kubectl rollout restart deployment/tekton-pipelines-controller -n "$NS_TEKTON" >/dev/null
kubectl rollout status  deployment/tekton-pipelines-controller -n "$NS_TEKTON" \
  --timeout=120s >/dev/null
info "Tekton feature flags applied and controller restarted"

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
ui:
  auth:
    username: '$(yesc "${UI_ADMIN_USERNAME}")'
    password: '$(yesc "${UI_ADMIN_PASSWORD}")'
sonarqube:
  adminPassword: '$(yesc "${SONARQUBE_PASSWORD}")'
database:
  internal:
    password: '$(yesc "${DB_PASSWORD}")'
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

# ── Step 6: Wait ──────────────────────────────────────────────────────────────
section "Step 6 — Waiting for all pods to be Running and Ready"

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
wait_ns "$NS_CORE"    300 || FAILED=true
wait_ns "$NS_TOOLING" 600 || FAILED=true
wait_ns "$NS_TEKTON"  300 || FAILED=true

# ── Done ──────────────────────────────────────────────────────────────────────
section "Done"

[[ "$FAILED" == "true" ]] \
  && warn "Some pods not Ready — check: kubectl get pods -A" \
  || info "All pods Running and Ready"

echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │          GitOps Platform is ready            │"
echo "  └─────────────────────────────────────────────┘"
echo ""
echo "  Access the UI:"
echo "    kubectl port-forward svc/gitops-operator -n ${NS_CORE} 8080:8080"
echo "    open http://localhost:8080"
echo ""
echo "  Login credentials:"
echo "    Username : ${UI_ADMIN_USERNAME}"
echo "    Password : ${UI_ADMIN_PASSWORD}"
echo ""
echo "  API token (save this securely):"
echo "    ${OPERATOR_API_TOKEN}"
echo ""
echo "  To uninstall:"
echo "    curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-uninstall.sh | bash"
echo ""
