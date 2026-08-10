#!/usr/bin/env bash
# reset-admin-password.sh
#
# Resets the admin password WITHOUT knowing the current password.
# Use this when the admin password has been lost.
#
# How it works:
#   1. Generates a new PBKDF2-HMAC-SHA256 hash inside the operator pod
#      (same algorithm the platform uses — Python + hashlib)
#   2. Updates the hash directly in PostgreSQL via psql
#
# Usage:
#   bash reset-admin-password.sh
#   bash reset-admin-password.sh --password newpassword
#   bash reset-admin-password.sh --username admin --password newpassword
#
# Requirements: kubectl configured against the target cluster

set -euo pipefail

NS_CORE="gitops-db"
NS_OPERATOR="gitops-core"
DB_NAME="gitops_platform"
DB_USER="gitops"   # matches POSTGRES_USER in helm/gitops-platform/templates/db/secret.yaml -- fixed, not customer-configurable (internal DB mode only)

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
section() { echo -e "\n${CYAN}── $* ──${NC}"; }

# ── Args ─────────────────────────────────────────────────────────────────────
TARGET_USER="admin"
NEW_PASSWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --username) shift; TARGET_USER="$1" ;;
    --password) shift; NEW_PASSWORD="$1" ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
  shift
done

if [[ -z "$NEW_PASSWORD" ]]; then
  if [[ -t 0 ]]; then
    read -rsp "  New password for '${TARGET_USER}': " NEW_PASSWORD; echo
    [[ -z "$NEW_PASSWORD" ]] && { echo "Password cannot be empty."; exit 1; }
  else
    echo -e "${RED}[ERROR]${NC} Pass --password <value> or run interactively." >&2
    exit 1
  fi
fi

section "Pre-flight"

if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Cannot reach cluster." >&2; exit 1
fi
info "Cluster: $(kubectl config current-context)"

# ── Step 1: Generate new hash inside the operator pod ────────────────────────
section "Step 1 — Generating password hash"

OPERATOR_POD=$(kubectl get pod -n "${NS_OPERATOR}" \
  -l app=gitops-operator \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$OPERATOR_POD" ]]; then
  # kubectl exits 0 even when the label selector above matches nothing, so
  # this fallback needs its own explicit -z check rather than a `||` chain
  # (a `||` never fires here -- confirmed live: an empty-but-successful
  # jsonpath lookup short-circuits past it every time).
  OPERATOR_POD=$(kubectl get pod -n "${NS_OPERATOR}" \
    --no-headers -o custom-columns=':metadata.name' 2>/dev/null | grep operator | head -1)
fi

if [[ -z "$OPERATOR_POD" ]]; then
  echo -e "${RED}[ERROR]${NC} No operator pod found in ${NS_OPERATOR}." >&2
  exit 1
fi

info "Using pod: ${OPERATOR_POD}"

# Password piped via stdin, not spliced into the Python source text -- a
# password containing a quote character would otherwise break out of the
# '''...''' literal (confirmed live: a trailing "'" alone raises a
# SyntaxError, and adversarial input can go further than a crash).
NEW_HASH=$(printf '%s' "${NEW_PASSWORD}" | kubectl exec -i -n "${NS_OPERATOR}" "${OPERATOR_POD}" -- python3 -c "
import hashlib, secrets, sys
pwd = sys.stdin.read()
salt = secrets.token_hex(16)
dk = hashlib.pbkdf2_hmac('sha256', pwd.encode(), salt.encode(), 600000)
print(f'{salt}\${dk.hex()}')
")

info "Hash generated (PBKDF2-HMAC-SHA256, 600k iterations)"

# ── Step 2: Update the database ───────────────────────────────────────────────
section "Step 2 — Updating password in PostgreSQL"

DB_POD=$(kubectl get pod -n gitops-db \
  -l app=gitops-postgresql \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$DB_POD" ]]; then
  DB_POD=$(kubectl get pod -n gitops-db --no-headers \
    -o custom-columns=':metadata.name' 2>/dev/null | grep postgresql | head -1)
fi

if [[ -z "$DB_POD" ]]; then
  echo -e "${RED}[ERROR]${NC} No PostgreSQL pod found in gitops-db." >&2
  exit 1
fi

info "Using pod: ${DB_POD}"

# TARGET_USER passed as a psql variable (:'target_user' quotes it as a SQL
# literal, escaping embedded quotes) instead of spliced into the SQL text --
# unescaped interpolation here let "--username \"admin' OR '1'='1\"" match
# and overwrite every row's pwd_hash, confirmed live.
ROWS=$(kubectl exec -n gitops-db "${DB_POD}" -- \
  psql -qtA -U "${DB_USER}" -d "${DB_NAME}" \
  -v new_hash="${NEW_HASH}" -v target_user="${TARGET_USER}" -c \
  "UPDATE platform_users SET pwd_hash = :'new_hash' \
   WHERE username = :'target_user' RETURNING username;")

if [[ "$ROWS" == "$TARGET_USER" ]]; then
  info "Password updated for user '${TARGET_USER}'"
else
  echo -e "${RED}[ERROR]${NC} User '${TARGET_USER}' not found in the database." >&2
  echo "  Available users:"
  kubectl exec -n gitops-db "${DB_POD}" -- \
    psql -U "${DB_USER}" -d "${DB_NAME}" -tAc "SELECT username FROM platform_users;"
  exit 1
fi

section "Done"
echo ""
echo "  Login with:"
echo "    Username : ${TARGET_USER}"
echo "    Password : ${NEW_PASSWORD}"
echo ""
warn "Change this password again from the UI (Profile → Change password) after logging in."
echo ""
