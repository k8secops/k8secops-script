#!/usr/bin/env bash
# ============================================================
# GitOps Platform — uninstaller
#
# Usage:
#   curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-uninstall.sh | bash
#   curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-uninstall.sh | bash -s -- --purge
#
# Default (no flags):
#   Removes the Helm release, Sealed Secrets, and per-app credentials.
#   Keeps namespaces and PostgreSQL data so you can reinstall cleanly.
#
# --purge:
#   Also removes namespaces, PostgreSQL PVCs (all history lost),
#   Tekton Pipelines, and cosign signing key.
#
# Requirements: kubectl, helm
# ============================================================

set -euo pipefail

TEKTON_VERSION="v1.13.0"
HELM_RELEASE="gitops-platform"
NS_CORE="gitops-core"
NS_TOOLING="gitops-tooling"
NS_DB="gitops-db"
NS_TEKTON="tekton-pipelines"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
section() { echo -e "\n${CYAN}── $* ──${NC}"; }

PURGE=false
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=true ;;
    --help|-h)
      sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
  esac
done

# ── Pre-flight ───────────────────────────────────────────────────────────────
section "Pre-flight checks"

for cmd in kubectl helm; do
  if ! command -v "$cmd" &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} ${cmd} not found." >&2; exit 1
  fi
done

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Cannot reach the cluster. Check your kubeconfig." >&2; exit 1
fi

info "Cluster : $(kubectl config current-context)"
[[ "$PURGE" == "true" ]] && warn "--purge: will also remove namespaces, PVCs, Tekton, cosign-keys."

# ── Step 1: Capture app names (before CRD is removed) ────────────────────────
section "Step 1 — Capturing onboarded application names"

APP_NAMES=""
if kubectl get crd gitopspipelines.gitops-platform.io &>/dev/null 2>&1; then
  APP_NAMES=$(kubectl get gitopspipelines -n "${NS_CORE}" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
fi
[[ -n "$APP_NAMES" ]] && info "Apps: ${APP_NAMES}" || info "No onboarded apps found."

# ── Step 2: Helm uninstall ────────────────────────────────────────────────────
section "Step 2 — Uninstalling Helm release '${HELM_RELEASE}'"

if helm status "${HELM_RELEASE}" --namespace "${NS_CORE}" &>/dev/null 2>&1; then
  helm uninstall "${HELM_RELEASE}" --namespace "${NS_CORE}"
  info "Helm release removed."
else
  info "Release not found — skipping."
fi

# ── Step 3: Sealed Secrets ────────────────────────────────────────────────────
section "Step 3 — Uninstalling Sealed Secrets"

if helm status sealed-secrets --namespace "${NS_TOOLING}" &>/dev/null 2>&1; then
  helm uninstall sealed-secrets --namespace "${NS_TOOLING}"
  info "Sealed Secrets removed."
else
  info "Sealed Secrets not found — skipping."
fi

# ── Step 4: Per-app credentials ───────────────────────────────────────────────
section "Step 4 — Removing per-app credentials"

if [[ -n "$APP_NAMES" ]]; then
  for app in $APP_NAMES; do
    info "  ${app}:"
    kubectl delete secret "${app}-git-token"      -n "${NS_CORE}"   --ignore-not-found 2>/dev/null || true
    kubectl delete secret "${app}-registry"       -n "${NS_TEKTON}" --ignore-not-found 2>/dev/null || true
    kubectl delete secret "${app}-ai-credentials" -n "${NS_TEKTON}" --ignore-not-found 2>/dev/null || true
  done
else
  info "No per-app secrets to remove."
fi

# ── Step 5: Platform secrets ──────────────────────────────────────────────────
section "Step 5 — Removing platform secrets"

kubectl delete secret gitops-platform-secrets -n "${NS_CORE}"   --ignore-not-found 2>/dev/null || true
kubectl delete secret gitops-operator-token   -n "${NS_TEKTON}" --ignore-not-found 2>/dev/null || true
kubectl delete secret gitops-db-internal      -n "${NS_DB}"     --ignore-not-found 2>/dev/null || true
info "Platform secrets removed."

# ── Step 6 (--purge only): Remove everything ──────────────────────────────────
if [[ "$PURGE" == "true" ]]; then
  section "Step 6 — Purge: PVCs, Tekton, cosign-keys, namespaces"

  # PostgreSQL backup PVC
  kubectl delete pvc gitops-platform-db-backup -n "${NS_DB}" --ignore-not-found 2>/dev/null || true
  info "Backup PVC deleted."

  # PostgreSQL StatefulSet PVCs (all pipeline history)
  kubectl delete pvc -n "${NS_DB}" --all --ignore-not-found 2>/dev/null || true
  info "PostgreSQL data PVCs deleted (all pipeline history gone)."

  # cosign signing key
  kubectl delete secret cosign-keys -n "${NS_TEKTON}" --ignore-not-found 2>/dev/null || true
  info "cosign-keys deleted."

  # Tekton PipelineRuns, TaskRuns, workspace PVCs
  kubectl delete pipelineruns,taskruns --all -n "${NS_TEKTON}" --ignore-not-found 2>/dev/null || true
  kubectl delete pvc --all -n "${NS_TEKTON}" --ignore-not-found 2>/dev/null || true

  # Tekton Pipelines controllers + CRDs
  info "Removing Tekton Pipelines ${TEKTON_VERSION}..."
  kubectl delete -f "https://github.com/tektoncd/pipeline/releases/download/${TEKTON_VERSION}/release.yaml" \
    --ignore-not-found 2>/dev/null || true
  info "Tekton removed."

  # Namespaces (removes everything left in them)
  kubectl delete namespace "${NS_CORE}" "${NS_TOOLING}" "${NS_DB}" "${NS_TEKTON}" \
    --ignore-not-found 2>/dev/null || true
  info "Platform namespaces deleted."
fi

# ── Done ─────────────────────────────────────────────────────────────────────
section "Done"
info "GitOps Platform uninstalled from '$(kubectl config current-context)'."
echo ""

if [[ "$PURGE" == "false" ]]; then
  echo "  Kept (safe to reinstall over):"
  echo "    Namespaces  : ${NS_CORE}, ${NS_TOOLING}, ${NS_DB}, ${NS_TEKTON}"
  echo "    PVCs        : PostgreSQL data in ${NS_DB} (pipeline history preserved)"
  echo "    Tekton      : controllers + CRDs"
  echo ""
  echo "  To also remove those:  re-run with --purge"
  echo "    curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-uninstall.sh | bash -s -- --purge"
fi

echo ""
echo "  To reinstall:"
echo "    curl -sfL https://raw.githubusercontent.com/k8secops/k8secops-script/main/customer-install.sh | bash"
echo ""
