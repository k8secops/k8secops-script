#!/usr/bin/env bash
# Installs the kgate CLI (Linux/macOS) -- same UX as helm's get-helm-3 and
# kubectl's documented curl-install: detect OS/arch, download the matching
# prebuilt binary + checksums from the latest (or a pinned) GitHub Release,
# verify the checksum, install to a directory on PATH. No Go toolchain
# needed. Windows users: download the .zip from the Releases page directly
# (see cli/README.md) -- this script deliberately doesn't try to also cover
# PowerShell-native installation.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/k8secops/k8secops-script/main/install-kgate.sh | bash
#   KGATE_VERSION=v1.2.3 bash install-kgate.sh   # pin a specific version
#   KGATE_INSTALL_DIR=$HOME/.local/bin bash install-kgate.sh   # no sudo needed
set -euo pipefail

REPO="k8secops/k8secops-script"
INSTALL_DIR="${KGATE_INSTALL_DIR:-/usr/local/bin}"
BIN_NAME="kgate"

log()  { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

detect_platform() {
  local os arch
  os="$(uname -s)"
  case "$os" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *) fail "unsupported OS: $os -- Windows users, download the .zip from https://github.com/${REPO}/releases instead" ;;
  esac
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) fail "unsupported architecture: $arch" ;;
  esac
  echo "${os} ${arch}"
}

resolve_version() {
  if [ -n "${KGATE_VERSION:-}" ]; then
    echo "$KGATE_VERSION"
    return
  fi
  # GitHub's own "latest release" redirect -- avoids needing the GitHub API
  # (which is aggressively rate-limited for unauthenticated requests) just
  # to find the current version tag.
  local latest_url="https://github.com/${REPO}/releases/latest"
  local resolved
  resolved="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$latest_url")" \
    || fail "could not resolve the latest release -- check network access to github.com, or set KGATE_VERSION=cli/vX.Y.Z"
  # $resolved is now .../releases/tag/cli/vX.Y.Z -- but if zero releases
  # have been published yet, GitHub redirects /releases/latest -> /releases
  # (a 200 OK listing page, not an error), so guard explicitly rather than
  # silently using that un-stripped URL as a "version".
  case "$resolved" in
    */tag/*) echo "${resolved##*/tag/}" ;;
    *) fail "no published release found at https://github.com/${REPO}/releases -- set KGATE_VERSION=cli/vX.Y.Z to pin one, or check back after a release is published" ;;
  esac
}

main() {
  command -v curl >/dev/null 2>&1 || fail "curl is required"

  read -r OS ARCH <<< "$(detect_platform)"
  VERSION="$(resolve_version)"
  # VERSION is the full tag, e.g. "cli/v1.2.3" -- goreleaser's {{.Version}}
  # template (used in archive names) strips the monorepo tag_prefix, so the
  # archive filename only has the bare "v1.2.3" part.
  SHORT_VERSION="${VERSION#cli/}"

  ARCHIVE="kgate_${OS}_${ARCH}.tar.gz"
  BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT

  log "Downloading kgate ${SHORT_VERSION} for ${OS}/${ARCH}..."
  curl -fsSL -o "${TMP_DIR}/${ARCHIVE}" "${BASE_URL}/${ARCHIVE}" \
    || fail "download failed: ${BASE_URL}/${ARCHIVE}"
  curl -fsSL -o "${TMP_DIR}/checksums.txt" "${BASE_URL}/checksums.txt" \
    || fail "download failed: ${BASE_URL}/checksums.txt"

  log "Verifying checksum..."
  (
    cd "$TMP_DIR"
    grep " ${ARCHIVE}\$" checksums.txt > checksum_line.txt \
      || fail "no checksum entry found for ${ARCHIVE}"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum -c checksum_line.txt --status \
        || fail "checksum verification failed -- do not trust this download"
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 256 -c checksum_line.txt --status \
        || fail "checksum verification failed -- do not trust this download"
    else
      log "Warning: neither sha256sum nor shasum found -- skipping checksum verification"
    fi
  )

  log "Extracting..."
  tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "$TMP_DIR" "$BIN_NAME"

  if [ -w "$INSTALL_DIR" ]; then
    mv "${TMP_DIR}/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"
  else
    log "Installing to ${INSTALL_DIR} requires sudo..."
    sudo mv "${TMP_DIR}/${BIN_NAME}" "${INSTALL_DIR}/${BIN_NAME}"
  fi
  chmod +x "${INSTALL_DIR}/${BIN_NAME}"

  log "Installed ${BIN_NAME} ${SHORT_VERSION} to ${INSTALL_DIR}/${BIN_NAME}"
  "${INSTALL_DIR}/${BIN_NAME}" version || true
}

main "$@"
