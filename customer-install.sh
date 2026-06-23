#!/usr/bin/env bash
# ============================================================
# GitOps Platform — one-command installer
#
# Usage (no source repo required):
#   curl -sfL https://<your-host>/customer-install.sh | bash
#   curl -sfL https://<your-host>/customer-install.sh | bash -s -- --yes
#
# What this does:
#   1. Checks prerequisites (kubectl, helm, python3)
#   2. Creates platform namespaces + sets Pod Security labels
#   3. Installs Sealed Secrets controller
#   4. Installs Tekton Pipelines
#   5. Installs the GitOps Platform Helm chart from OCI
#   6. Applies all 30+ security scanner tasks (from hosted YAML)
#   7. Waits until every pod is Running and Ready
#
# Requirements:
#   kubectl   >= 1.28  (configured against the target cluster)
#   helm      >= 3.12
#   python3            (for token generation)
#
# Environment variables (or prompted interactively):
#   OPERATOR_API_TOKEN    shared secret — auto-generated if empty
#   UI_ADMIN_USERNAME     default: admin
#   UI_ADMIN_PASSWORD     auto-generated if empty
#   SONARQUBE_PASSWORD    default: admin
# ============================================================

set -euo pipefail

# ── Published locations — update these after hosting dist/ files ────────────
CHART_OCI="oci://registry-1.docker.io/k8secops/gitops-platform"
CHART_VERSION="1.0.0"
TEKTON_TASKS_URL="https://raw.githubusercontent.com/k8secops/gitops-platform-public/main/tekton-tasks.yaml"

# ── Platform versions ────────────────────────────────────────────────────────
SEALED_SECRETS_VERSION="2.15.0"
TEKTON_VERSION="v1.13.0"

# ── Namespace names ──────────────────────────────────────────────────────────
NS_CORE="gitops-core"
NS_TOOLING="gitops-tooling"
NS_DB="gitops-db"
NS_TEKTON="tekton-pipelines"

# ── Colour helpers ───────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${CYAN}── $* ──${NC}"; }

# ── Argument parsing ─────────────────────────────────────────────────────────
AUTO_YES=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_YES=true ;;
    --help|-h)
      sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
  esac
done

ask() {
  local prompt="$1" default="$2" varname="$3" input
  if [[ -n "${!varname:-}" ]]; then return 0; fi
  if [[ "$AUTO_YES" == "true" ]]; then printf -v "$varname" '%s' "$default"; return 0; fi
  if [[ -n "$default" ]]; then read -rp "  ${prompt} [${default}]: " input; input="${input:-$default}"
  else read -rp "  ${prompt}: " input; fi
  printf -v "$varname" '%s' "$input"
}

ask_secret() {
  local prompt="$1" varname="$2" input
  if [[ -n "${!varname:-}" ]]; then return 0; fi
  if [[ "$AUTO_YES" == "true" ]]; then printf -v "$varname" '%s' ""; return 0; fi
  read -rsp "  ${prompt}: " input; echo
  printf -v "$varname" '%s' "$input"
}

gen_token() {
  if command -v openssl &>/dev/null; then openssl rand -hex 32
  else head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

yesc() { printf '%s' "${1//\'/\'\'}"; }

# ── Pre-flight ───────────────────────────────────────────────────────────────
section "Pre-flight checks"

for cmd in kubectl helm; do
  if ! command -v "$cmd" &>/dev/null; then
    error "${cmd} not found."
    [[ "$cmd" == "kubectl" ]] && error "Install: https://kubernetes.io/docs/tasks/tools/"
    [[ "$cmd" == "helm"    ]] && error "Install: https://helm.sh/docs/intro/install/"
    exit 1
  fi
done

if ! kubectl cluster-info &>/dev/null; then
  error "Cannot reach the cluster. Check your kubeconfig:"
  error "  kubectl config current-context"
  exit 1
fi

CONTEXT=$(kubectl config current-context)
info "Cluster: ${CONTEXT}"
info "Chart  : ${CHART_OCI}:${CHART_VERSION}"

echo ""
# When piped through bash (curl | bash) stdin is not a TTY — skip the prompt
# and proceed automatically. Only ask when running interactively.
if [[ "$AUTO_YES" != "true" ]] && [[ -t 0 ]]; then
  read -rp "  Proceed? [y/N]: " _yn
  [[ "${_yn,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

# ── Credentials ──────────────────────────────────────────────────────────────
section "Credentials"

EXISTING_TOKEN=$(kubectl get secret gitops-platform-secrets -n "${NS_CORE}" \
  -o jsonpath='{.data.operatorApiToken}' 2>/dev/null | base64 -d 2>/dev/null || true)

if [[ -n "$EXISTING_TOKEN" && "$AUTO_YES" == "true" ]]; then
  OPERATOR_API_TOKEN="$EXISTING_TOKEN"
  info "Reusing existing OPERATOR_API_TOKEN"
else
  [[ -z "${OPERATOR_API_TOKEN:-}" ]] && OPERATOR_API_TOKEN="$(gen_token)"
fi

ask "UI admin username" "admin" UI_ADMIN_USERNAME

EXISTING_UI_PASSWORD=$(kubectl get secret gitops-platform-secrets -n "${NS_CORE}" \
  -o jsonpath='{.data.uiAdminPassword}' 2>/dev/null | base64 -d 2>/dev/null || true)
if [[ -z "${UI_ADMIN_PASSWORD:-}" ]]; then
  UI_ADMIN_PASSWORD="${EXISTING_UI_PASSWORD:-$(gen_token | head -c 16)}"
fi

ask_secret "SonarQube admin password (default 'admin' if blank)" SONARQUBE_PASSWORD
SONARQUBE_PASSWORD="${SONARQUBE_PASSWORD:-admin}"

# ── Step 1: Namespaces ───────────────────────────────────────────────────────
section "Step 1 — Namespaces"

for ns in "$NS_CORE" "$NS_TOOLING" "$NS_DB" "$NS_TEKTON"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  info "Namespace: $ns"
done

# gitops-tooling needs privileged PSA for SonarQube
kubectl label namespace "$NS_TOOLING" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest \
  --overwrite >/dev/null

info "Pod Security labels applied"

# ── Step 2: Tekton Pipelines ─────────────────────────────────────────────────
section "Step 2 — Tekton Pipelines ${TEKTON_VERSION}"

CURRENT_TEKTON=$(kubectl get deployment tekton-pipelines-controller \
  -n "$NS_TEKTON" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

if echo "$CURRENT_TEKTON" | grep -q "$TEKTON_VERSION"; then
  info "Tekton ${TEKTON_VERSION} already installed"
else
  info "Installing Tekton ${TEKTON_VERSION}..."
  kubectl apply -f "https://github.com/tektoncd/pipeline/releases/download/${TEKTON_VERSION}/release.yaml"
  kubectl rollout status deployment/tekton-pipelines-controller -n "$NS_TEKTON" --timeout=300s
  info "Tekton ready"
fi

kubectl label namespace "$NS_TEKTON" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest \
  --overwrite >/dev/null
kubectl patch configmap feature-flags -n "$NS_TEKTON" \
  --type merge -p '{"data":{"set-security-context":"true"}}' >/dev/null 2>&1 || true

# ── Step 3: Sealed Secrets ───────────────────────────────────────────────────
section "Step 3 — Sealed Secrets ${SEALED_SECRETS_VERSION}"

helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace "$NS_TOOLING" --create-namespace \
  --set fullnameOverride=sealed-secrets-controller \
  --version "$SEALED_SECRETS_VERSION" \
  --timeout 5m >/dev/null

info "Sealed Secrets installed"

# ── Step 4: Helm install from OCI ────────────────────────────────────────────
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
EOF

helm upgrade --install gitops-platform "${CHART_OCI}" \
  --version "${CHART_VERSION}" \
  --namespace "${NS_CORE}" --create-namespace \
  -f "${TMP_VALUES}" \
  --timeout 10m

info "Helm chart installed"

# ── Step 5: Apply Tekton security scanner tasks ───────────────────────────────
section "Step 5 — Applying 30+ security scanner tasks"

info "Downloading from: ${TEKTON_TASKS_URL}"
kubectl apply -n "$NS_TEKTON" -f "${TEKTON_TASKS_URL}"
info "Scanner tasks applied"

# ── Step 6: Wait for all pods ─────────────────────────────────────────────────
section "Step 6 — Waiting for all pods to be Running and Ready"

wait_ns() {
  local ns="$1" timeout="${2:-300}" elapsed=0 total ready lines
  while true; do
    lines=$(kubectl get pods -n "$ns" --field-selector=status.phase!=Succeeded --no-headers 2>/dev/null || true)
    total=$(echo "$lines" | grep -c . || echo 0)
    ready=$(echo "$lines" | awk '{split($2,a,"/"); if(a[1]==a[2] && a[1]!=0 && $3=="Running") c++} END{print c+0}')
    info "${ns}: ${ready}/${total} Ready"
    [[ "$total" -gt 0 && "$ready" -eq "$total" ]] && return 0
    (( elapsed >= timeout )) && { warn "${ns}: timeout after ${timeout}s"; return 1; }
    sleep 5; (( elapsed += 5 ))
  done
}

FAILED=false
wait_ns "$NS_CORE"     300 || FAILED=true
wait_ns "$NS_TOOLING"  600 || FAILED=true
wait_ns "$NS_TEKTON"   300 || FAILED=true

# ── Done ─────────────────────────────────────────────────────────────────────
section "Done"

if [[ "$FAILED" == "true" ]]; then
  warn "Some pods not Ready yet — check: kubectl get pods -A"
else
  info "All pods Running and Ready"
fi

echo ""
echo "  Access the platform:"
echo "    kubectl port-forward svc/gitops-operator -n ${NS_CORE} 8080:8080"
echo "    open http://localhost:8080"
echo ""
echo "  Login:"
echo "    Username : ${UI_ADMIN_USERNAME}"
echo "    Password : ${UI_ADMIN_PASSWORD}"
echo ""
echo "  Operator API token (save this):"
echo "    ${OPERATOR_API_TOKEN}"
echo ""
