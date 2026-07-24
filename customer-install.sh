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
# Pinned to the tag matching this script's own CHART_VERSION, not a mutable
# branch -- a compromise of (or malicious merge to) k8secops-script's main
# branch would otherwise silently affect every future install the moment it
# lands, applied straight to the cluster with this installer's own
# privileges. Bump this alongside CHART_VERSION on release.
TEKTON_TASKS_URL="https://raw.githubusercontent.com/k8secops/k8secops-script/v${CHART_VERSION}/tekton-tasks.yaml"

# ── Versions ─────────────────────────────────────────────────────────────────
TEKTON_VERSION="v1.13.0"
SEALED_SECRETS_VERSION="2.15.0"

# ── Namespace names ──────────────────────────────────────────────────────────
# No shared/default build namespace anymore -- every pipeline run gets its
# own fresh, ephemeral namespace, created and destroyed per-run by the
# platform itself. Nothing to create here for that.
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
EXISTING_CRED_ENC_KEY=$(kubectl get secret gitops-platform-secrets -n "${NS_CORE}" \
  -o jsonpath='{.data.credentialEncryptionKey}' 2>/dev/null | base64 -d 2>/dev/null || true)

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

# ── Docker Hub credentials (for scanner image pulls) ──────────────────────────
# Scanner images (gitleaks, trivy, grype, semgrep, etc.) are pulled by
# Kubernetes when scheduling Tekton task pods. Without credentials, Docker Hub
# limits anonymous pulls to 100/6h per node IP — causing pipeline failures.
# Provide your Docker Hub username + token to authenticate all scanner pulls.
# Free Docker Hub account: https://hub.docker.com/settings/security
echo ""
echo "  Registry credentials — for pulling pipeline scanner images (gitleaks, trivy, grype...)"
echo "  Without credentials, Docker Hub limits anonymous pulls to 100/6h per node."
echo ""
echo "  Option A: Docker Hub (public images from hub.docker.com)"
echo "    Get a free access token at: hub.docker.com -> Account Settings -> Security"
echo ""
echo "  Option B: Private registry (Harbor, Nexus, ECR, GHCR, Artifactory...)"
echo "    Mirror scanner images to your registry first: make mirror-images REGISTRY=..."
echo ""
if [[ -z "${DOCKERHUB_USERNAME:-}" ]] && [[ -z "${PRIVATE_REGISTRY_SERVER:-}" ]]; then
  read -rp "  Docker Hub username (Enter to skip, or type 'private' for private registry): " _reg_choice
  if [[ "${_reg_choice}" == "private" ]]; then
    read -rp "  Private registry server (e.g. registry.company.com): " PRIVATE_REGISTRY_SERVER
    read -rp "  Username: " PRIVATE_REGISTRY_USERNAME
    read -rsp "  Token/password: " PRIVATE_REGISTRY_TOKEN; echo ""
  elif [[ -n "${_reg_choice}" ]]; then
    DOCKERHUB_USERNAME="${_reg_choice}"
    read -rsp "  Docker Hub access token: " DOCKERHUB_TOKEN; echo ""
  fi
fi
if [[ -n "${DOCKERHUB_USERNAME:-}" ]] && [[ -n "${DOCKERHUB_TOKEN:-}" ]]; then
  info "Docker Hub credentials set — scanner image pulls will be authenticated."
elif [[ -n "${PRIVATE_REGISTRY_SERVER:-}" ]]; then
  info "Private registry set (${PRIVATE_REGISTRY_SERVER}) — scanner images will use authenticated pulls."
else
  warn "No registry credentials — scanner image pulls will be anonymous (rate-limited to 100/6h)."
  DOCKERHUB_USERNAME=""
  DOCKERHUB_TOKEN=""
fi

echo ""
info "An NVD API key dramatically speeds up the OWASP Dependency-Check vulnerability"
info "database download (from 30-60 min to ~5 min). Get a free key at:"
info "  nvd.nist.gov/developers/request-an-api-key"
read -rp "  NVD API key (optional, press Enter to skip): " NVD_API_KEY

# ── Auto-generated credentials ─────────────────────────────────────────────────
UI_ADMIN_USERNAME="admin"
OPERATOR_API_TOKEN="${EXISTING_TOKEN:-$(gen_token)}"
SONARQUBE_PASSWORD="$(gen_token | head -c 20)"
DB_PASSWORD="${EXISTING_DB_PWD:-$(gen_token | head -c 24)}"
SECRET_KEY="${EXISTING_SECRET_KEY:-$(gen_token)}"
# Generated independently of OPERATOR_API_TOKEN so the two can be rotated
# separately -- without its own key, credential-at-rest encryption falls back
# to deriving one from OPERATOR_API_TOKEN, meaning any future `make
# rotate-token`/token rotation would make every already-stored app credential
# (git/registry/AI tokens) permanently undecryptable.
CREDENTIAL_ENCRYPTION_KEY="${EXISTING_CRED_ENC_KEY:-$(gen_token)}"

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

# gitops-core runs only platform code we own (operator/controller/
# webhook-api) -- every one of their pod templates already runs
# non-root/no-priv-escalation/all-capabilities-dropped/seccomp, so
# enforcing restricted costs nothing and closes the gap where this
# namespace was otherwise relying on whatever PSA level the cluster
# happens to default to.
kubectl label namespace "$NS_CORE" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  --overwrite >/dev/null

# gitops-db can NOT be restricted -- the postgres:16 image's own
# entrypoint starts its init container as root by design (runAsUser:0,
# runAsNonRoot:false) and re-execs as postgres via gosu; restricted
# would block it from ever starting. baseline is still real hardening
# over the cluster's undeclared default and matches tekton-pipelines'
# posture below (see helm/gitops-platform/templates/db/statefulset.yaml
# for the full rationale).
kubectl label namespace "$NS_DB" \
  pod-security.kubernetes.io/enforce=baseline \
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

# tekton-pipelines hosts only the Tekton controller/webhook Deployments --
# every actual TaskRun/PipelineRun pod runs in its own ephemeral per-run
# namespace (provisioned/labeled independently), so this namespace itself
# needs no elevated PSA level. baseline (not privileged) is sufficient and
# matches cluster-setup/01-namespaces.yaml's posture for the same namespace.
kubectl label namespace "$NS_TEKTON" \
  pod-security.kubernetes.io/enforce=baseline \
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

# rbacHardening installs a ValidatingAdmissionPolicy closing a defense-in-
# depth gap around the operator/webhook-api ClusterRole (see values.yaml's
# own comment on that key for the full rationale). The VAP API is beta on
# 1.28/1.29 (often off by default on managed clusters) and GA from 1.30+ --
# enabling it unconditionally would break installs on clusters where it's
# unavailable, so detect support and enable it only when the API server
# actually offers the resource.
if kubectl api-resources --api-group=admissionregistration.k8s.io -o name 2>/dev/null \
    | grep -qi '^validatingadmissionpolicies\.'; then
  RBAC_HARDENING=true
  info "ValidatingAdmissionPolicy supported — enabling rbacHardening"
else
  RBAC_HARDENING=false
  warn "ValidatingAdmissionPolicy not available on this cluster (needs K8s 1.28+ with the beta feature enabled, GA from 1.30+) — rbacHardening left off. Consider upgrading or enabling the feature gate, then: helm upgrade gitops-platform ... --reuse-values --set rbacHardening.enabled=true"
fi

TMP_VALUES=$(mktemp)
trap 'rm -f "${TMP_VALUES}"' EXIT

cat > "${TMP_VALUES}" <<EOF
operator:
  apiToken: '$(yesc "${OPERATOR_API_TOKEN}")'
  secretKey: '$(yesc "${SECRET_KEY}")'
  credentialEncryptionKey: '$(yesc "${CREDENTIAL_ENCRYPTION_KEY}")'
ui:
  auth:
    username: '$(yesc "${UI_ADMIN_USERNAME}")'
    password: '$(yesc "${UI_ADMIN_PASSWORD}")'
sonarqube:
  adminPassword: '$(yesc "${SONARQUBE_PASSWORD}")'
vulnDbCacheServer:
  nvdApiKey: '$(yesc "${NVD_API_KEY:-}")'
database:
  internal:
    password: '$(yesc "${DB_PASSWORD}")'
global:
  pipelineDockerHub:
    username: '$(yesc "${DOCKERHUB_USERNAME:-}")'
    token: '$(yesc "${DOCKERHUB_TOKEN:-}")'
  pipelineImagePullSecret:
    server: '$(yesc "${PRIVATE_REGISTRY_SERVER:-}")'
    username: '$(yesc "${PRIVATE_REGISTRY_USERNAME:-}")'
    token: '$(yesc "${PRIVATE_REGISTRY_TOKEN:-}")'
tekton:
  enabled: false
rbacHardening:
  enabled: ${RBAC_HARDENING}
EOF

# Pre-flight: remove any orphaned Helm-managed SAs left by a previous partial
# uninstall. Without this, a fresh 'helm install' fails with "already exists"
# because the SA exists but is no longer tracked by any Helm release.
if ! helm status gitops-platform -n "${NS_CORE}" &>/dev/null 2>&1; then
  kubectl delete sa gitops-pipeline-sa -n "${NS_TEKTON}" --ignore-not-found 2>/dev/null || true
fi

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

# ── Reconcile PostgreSQL password ────────────────────────────────────────────
# When the PostgreSQL PVC is reused from a previous install the data directory
# already has an old password. POSTGRES_PASSWORD is only honoured on first init.
# Extract the password Helm put in the secret and force-set it via local socket
# (which uses trust auth inside the pod) so the operator can connect.
DB_URL=$(kubectl get secret gitops-db-credentials -n "${NS_CORE}" \
  -o jsonpath='{.data.database-url}' 2>/dev/null | base64 -d)
# Bash-native parse (no subprocess) -- DB_URL never becomes a separate
# process's command-line argument this way, so the password can't briefly
# appear in `ps`/`/proc/*/cmdline` output to any other process on the host.
DB_PASS=""
if [[ "${DB_URL}" =~ ^[a-zA-Z]+://[^:@/]+:([^@]+)@ ]]; then
  DB_PASS="${BASH_REMATCH[1]}"
fi
if [[ -n "${DB_PASS}" ]]; then
  # SQL passed via stdin (heredoc), not a `-c` argument -- same reasoning:
  # psql's own argv must never contain the password.
  if kubectl exec -i -n "${NS_DB}" statefulset/gitops-platform-postgresql -- \
      psql -U gitops -d gitops_platform >/dev/null 2>&1 <<SQL
ALTER USER gitops WITH PASSWORD '${DB_PASS}';
SQL
  then
    info "PostgreSQL password reconciled"
  else
    warn "Password reconcile skipped (harmless on fresh DB)"
  fi
fi
info "PostgreSQL ready"

# ── Step 5: Scanner tasks ─────────────────────────────────────────────────────
section "Step 5 — Applying 30+ security scanner tasks"

# Every pipeline run now gets its own fresh, ephemeral namespace (created and
# destroyed per-run by the platform itself, see NS_CORE's operator). Task
# objects a Pipeline resolves via taskRef must physically exist in the same
# namespace (Tekton has no cross-namespace taskRef); rather than pre-creating
# them in every possible run namespace, the platform copies them from one
# canonical source namespace (NS_CORE) into each fresh run namespace at
# trigger time. This bundle (pre-rendered with namespace: gitops-core by
# package-release.py) is applied to NS_CORE so that copy source exists.
kubectl apply -n "$NS_CORE" -f "${TEKTON_TASKS_URL}"
info "Scanner tasks applied"

# ── Step 5.5: Seed the vulnerability-DB cache ─────────────────────────────────
# vulnDbCacheServer (gitops-tooling) refreshes on its own schedule (daily for
# OWASP, every 6h for Grype) -- this just kicks that off immediately instead
# of leaving a fresh install's cache cold until the first scheduled run.
section "Step 5.5 — Seeding the vulnerability-DB cache"
OWASP_REFRESH_CRONJOB="gitops-platform-owasp-db-refresh"
GRYPE_REFRESH_CRONJOB="gitops-platform-grype-db-refresh"

if kubectl get cronjob "${OWASP_REFRESH_CRONJOB}" -n "$NS_TOOLING" &>/dev/null; then
  kubectl delete job gitops-platform-owasp-seed -n "$NS_TOOLING" --ignore-not-found &>/dev/null || true
  kubectl create job gitops-platform-owasp-seed \
    --from=cronjob/"${OWASP_REFRESH_CRONJOB}" -n "$NS_TOOLING" &>/dev/null
  if [[ -n "${NVD_API_KEY:-}" ]]; then
    info "NVD API key provided — waiting up to 10 min for OWASP database seed..."
    NVD_TIMEOUT=600 NVD_ELAPSED=0
    while (( NVD_ELAPSED < NVD_TIMEOUT )); do
      STATUS=$(kubectl get job gitops-platform-owasp-seed -n "$NS_TOOLING" \
        -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")
      FAILED=$(kubectl get job gitops-platform-owasp-seed -n "$NS_TOOLING" \
        -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
      [[ "$STATUS" == "True" ]] && { info "OWASP NVD database seeded successfully."; break; }
      [[ "$FAILED" == "True" ]] && { warn "OWASP seed job failed (non-fatal, best-effort cache)."; break; }
      sleep 15; NVD_ELAPSED=$((NVD_ELAPSED + 15))
      info "  OWASP seeding... ${NVD_ELAPSED}s elapsed"
    done
    (( NVD_ELAPSED >= NVD_TIMEOUT )) && warn "OWASP seed still running after 10 min — continuing install."
  else
    info "No NVD API key — seed running in background (30-60 min without key)."
    info "owasp-dc scans cold-start (best-effort cache, non-fatal) until seeding completes."
  fi
fi

if kubectl get cronjob "${GRYPE_REFRESH_CRONJOB}" -n "$NS_TOOLING" &>/dev/null; then
  kubectl delete job gitops-platform-grype-seed -n "$NS_TOOLING" --ignore-not-found &>/dev/null || true
  kubectl create job gitops-platform-grype-seed \
    --from=cronjob/"${GRYPE_REFRESH_CRONJOB}" -n "$NS_TOOLING" &>/dev/null
  info "Grype DB seed job started in background (fast — a few minutes)."
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
echo "    kubectl port-forward svc/gitops-platform-sonarqube -n gitops-tooling 9000:9000"
echo "    open http://localhost:9000  (ClusterIP-only -- not reachable via node IP)"
echo "    Username         : admin"
echo "    Password         : ${SONARQUBE_PASSWORD}"
echo ""
echo "  ── OWASP NVD database ──────────────────────────────────"
echo "    Note             : the vulnerability-DB cache (OWASP + Grype) refreshes"
echo "                        itself on a schedule (daily / every 6h) in the"
echo "                        gitops-tooling namespace; each pipeline run fetches"
echo "                        from it automatically. If seeding hasn't finished"
echo "                        yet, owasp-dc/grype scans just cold-start instead."
echo ""
echo "  ── Save securely ───────────────────────────────────────"
echo "    Operator API token: ${OPERATOR_API_TOKEN}"
echo ""
echo "  ── To uninstall ────────────────────────────────────────"
echo "    curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-uninstall.sh | bash"
echo ""
